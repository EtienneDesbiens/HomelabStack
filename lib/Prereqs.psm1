#Requires -Version 5.1
<#
.SYNOPSIS
    Checks for and, if missing, installs Docker Desktop -- so install.ps1
    can be a true "clone this repo and run it" experience with no separate
    Docker install required first.

    This is the one module in the stack that makes real system changes
    outside of Docker itself (Windows optional features, an elevated
    installer run). Every external touchpoint still goes through an
    injectable scriptblock, same pattern as Deploy.psm1/Validate.psm1, so
    the decision logic (already-available / needs-elevation / reboot-
    required / installed / failed) is unit-testable without ever running a
    real installer or touching Windows features.

    NOTE: pure ASCII only -- see the note at the top of Gate.psm1.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Injectable I/O
# ---------------------------------------------------------------------------

$script:ProcessRunner = {
    param([string]$FilePath, [string[]]$ArgumentList = @())
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -Wait -WindowStyle Hidden
    [pscustomobject]@{ ExitCode = $p.ExitCode }
}
function Get-PrereqProcessRunner { $script:ProcessRunner }
function Set-PrereqProcessRunner {
    param([Parameter(Mandatory)][scriptblock]$Runner)
    $script:ProcessRunner = $Runner
}

$script:Downloader = {
    param([string]$Url, [string]$Destination)
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}
function Get-Downloader { $script:Downloader }
function Set-Downloader {
    param([Parameter(Mandatory)][scriptblock]$Downloader)
    $script:Downloader = $Downloader
}

$script:CommandChecker = { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function Get-CommandChecker { $script:CommandChecker }
function Set-CommandChecker {
    param([Parameter(Mandatory)][scriptblock]$Checker)
    $script:CommandChecker = $Checker
}

$script:DockerInfoChecker = {
    try { & docker info *> $null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}
function Get-DockerInfoChecker { $script:DockerInfoChecker }
function Set-DockerInfoChecker {
    param([Parameter(Mandatory)][scriptblock]$Checker)
    $script:DockerInfoChecker = $Checker
}

$script:PathTester = { param([string]$Path) Test-Path -Path $Path }
function Get-PathTester { $script:PathTester }
function Set-PathTester {
    param([Parameter(Mandatory)][scriptblock]$Tester)
    $script:PathTester = $Tester
}

$script:AppLauncher = { param([string]$Path) Start-Process -FilePath $Path | Out-Null }
function Get-AppLauncher { $script:AppLauncher }
function Set-AppLauncher {
    param([Parameter(Mandatory)][scriptblock]$Launcher)
    $script:AppLauncher = $Launcher
}

$script:ElevationChecker = {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-ElevationChecker { $script:ElevationChecker }
function Set-ElevationChecker {
    param([Parameter(Mandatory)][scriptblock]$Checker)
    $script:ElevationChecker = $Checker
}

$script:WslRunner = {
    param([string[]]$ArgumentList)
    try {
        $output = & wsl.exe @ArgumentList 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
    } catch {
        [pscustomobject]@{ ExitCode = -1; Output = @($_.Exception.Message) }
    }
}
function Get-WslRunner { $script:WslRunner }
function Set-WslRunner {
    param([Parameter(Mandatory)][scriptblock]$Runner)
    $script:WslRunner = $Runner
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

function Test-IsElevated {
    [CmdletBinding()]
    param([scriptblock]$ElevationChecker)
    if (-not $ElevationChecker) { $ElevationChecker = Get-ElevationChecker }
    return [bool](& $ElevationChecker)
}

function Test-DockerAvailable {
    <#
    .SYNOPSIS
        True only if the docker CLI exists AND the daemon actually
        responds -- Docker Desktop can be installed but not yet started.
    #>
    [CmdletBinding()]
    param([scriptblock]$CommandChecker, [scriptblock]$DockerInfoChecker)
    if (-not $CommandChecker) { $CommandChecker = Get-CommandChecker }
    if (-not (& $CommandChecker 'docker')) { return $false }
    if (-not $DockerInfoChecker) { $DockerInfoChecker = Get-DockerInfoChecker }
    return [bool](& $DockerInfoChecker)
}

function Get-DockerDesktopExePath {
    Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
}

function Test-DockerInstalled {
    <#
    .SYNOPSIS
        True if Docker appears to be installed at all -- the CLI resolves
        on PATH, or the Desktop app is present on disk -- regardless of
        whether the daemon is currently running.

        Distinguishes "not installed, run the full installer" from
        "installed but not started" (Desktop doesn't always auto-launch
        after install or after a reboot). Without this distinction,
        Install-DockerDesktop would re-run the entire download+install
        flow -- and demand an elevation/UAC prompt -- just because the app
        happened to not be running yet, which is a common, harmless state.
    #>
    [CmdletBinding()]
    param([scriptblock]$CommandChecker, [scriptblock]$PathTester)
    if (-not $CommandChecker) { $CommandChecker = Get-CommandChecker }
    if (& $CommandChecker 'docker') { return $true }
    if (-not $PathTester) { $PathTester = Get-PathTester }
    return [bool](& $PathTester (Get-DockerDesktopExePath))
}

function Start-DockerDesktopAndWait {
    <#
    .SYNOPSIS
        Launches Docker Desktop (if its exe is present) and polls until
        the daemon responds or the timeout elapses. No elevation needed --
        starting an already-installed app doesn't require it.
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$CommandChecker,
        [scriptblock]$DockerInfoChecker,
        [scriptblock]$PathTester,
        [scriptblock]$AppLauncher,
        [int]$StartupTimeoutSeconds = 180,
        [int]$PollIntervalSeconds = 5
    )
    if (-not $CommandChecker) { $CommandChecker = Get-CommandChecker }
    if (-not $DockerInfoChecker) { $DockerInfoChecker = Get-DockerInfoChecker }
    if (-not $PathTester) { $PathTester = Get-PathTester }
    if (-not $AppLauncher) { $AppLauncher = Get-AppLauncher }

    $dockerDesktopExe = Get-DockerDesktopExePath
    if (& $PathTester $dockerDesktopExe) {
        & $AppLauncher $dockerDesktopExe
    }

    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerAvailable -CommandChecker $CommandChecker -DockerInfoChecker $DockerInfoChecker) {
            return [pscustomobject]@{ Status = 'installed'; Detail = 'Docker Desktop is running.' }
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    return [pscustomobject]@{ Status = 'failed'; Detail = "Docker Desktop didn't respond within $StartupTimeoutSeconds seconds. It may still be starting (first launch can be slow) -- give it a minute and re-run install.ps1, or open Docker Desktop manually and check for errors there." }
}

function Test-WslReady {
    <#
    .SYNOPSIS
        True only if wsl.exe itself reports a working WSL2 platform -- the
        same thing Docker Desktop checks on launch.

        Earlier version of this function checked whether the two
        underlying Windows optional features (Microsoft-Windows-Subsystem-
        Linux, VirtualMachinePlatform) were toggled "Enabled" via DISM.
        That turned out to be necessary but not sufficient: Docker Desktop
        still reported "WSL not installed" with only the features on --
        the actual WSL2 kernel/platform component (what `wsl --install`
        provides) also has to be present. Asking wsl.exe directly avoids
        this class of bug by construction, since it's the same source of
        truth Docker Desktop itself uses.
    #>
    [CmdletBinding()]
    param([scriptblock]$WslRunner, [scriptblock]$CommandChecker)
    if (-not $CommandChecker) { $CommandChecker = Get-CommandChecker }
    if (-not (& $CommandChecker 'wsl.exe')) { return $false }
    if (-not $WslRunner) { $WslRunner = Get-WslRunner }
    $result = & $WslRunner -ArgumentList @('--status')
    return ($result.ExitCode -eq 0)
}

function Install-WslPlatform {
    <#
    .SYNOPSIS
        Runs `wsl --install --no-distro` -- the officially supported,
        idempotent one-shot command that enables the needed Windows
        features AND installs the actual WSL2 kernel/platform component,
        without pulling in a full Linux distro (Docker Desktop doesn't
        need one on WSL2 -- it manages its own internal WSL2 utility VMs).
        Safe to call even if some or all of this is already done.
    #>
    [CmdletBinding()]
    param([scriptblock]$WslRunner)
    if (-not $WslRunner) { $WslRunner = Get-WslRunner }
    return & $WslRunner -ArgumentList @('--install', '--no-distro')
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

function Install-DockerDesktop {
    <#
    .SYNOPSIS
        Gets Docker running by whichever path is actually needed:
        already running -> no-op; installed but not started -> just
        launch it (no elevation needed for that); not installed at all ->
        elevate, provision WSL2, download and silently install, then
        launch it. Never call this under -WhatIf -- the caller should
        skip it and just log what would happen, same as every other
        real-system-change path in this codebase.

    .OUTPUTS
        A status object with .Status in:
          already-available | needs-elevation | reboot-required |
          installed | failed
        and a human-readable .Detail.
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$ProcessRunner,
        [scriptblock]$Downloader,
        [scriptblock]$CommandChecker,
        [scriptblock]$DockerInfoChecker,
        [scriptblock]$ElevationChecker,
        [scriptblock]$WslRunner,
        [scriptblock]$PathTester,
        [scriptblock]$AppLauncher,
        [string]$InstallerUrl = 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe',
        [string]$DownloadPath,
        [int]$StartupTimeoutSeconds = 180,
        [int]$PollIntervalSeconds = 5
    )

    if (-not $ProcessRunner) { $ProcessRunner = Get-PrereqProcessRunner }
    if (-not $Downloader) { $Downloader = Get-Downloader }
    if (-not $CommandChecker) { $CommandChecker = Get-CommandChecker }
    if (-not $DockerInfoChecker) { $DockerInfoChecker = Get-DockerInfoChecker }
    if (-not $DownloadPath) { $DownloadPath = Join-Path $env:TEMP 'DockerDesktopInstaller.exe' }

    if (Test-DockerAvailable -CommandChecker $CommandChecker -DockerInfoChecker $DockerInfoChecker) {
        return [pscustomobject]@{ Status = 'already-available'; Detail = 'Docker is already installed and running.' }
    }

    if (Test-DockerInstalled -CommandChecker $CommandChecker -PathTester $PathTester) {
        return Start-DockerDesktopAndWait -CommandChecker $CommandChecker -DockerInfoChecker $DockerInfoChecker `
            -PathTester $PathTester -AppLauncher $AppLauncher `
            -StartupTimeoutSeconds $StartupTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
    }

    if (-not (Test-IsElevated -ElevationChecker $ElevationChecker)) {
        return [pscustomobject]@{ Status = 'needs-elevation'; Detail = 'Administrator privileges are required to install Docker Desktop.' }
    }

    if (-not (Test-WslReady -WslRunner $WslRunner -CommandChecker $CommandChecker)) {
        Install-WslPlatform -WslRunner $WslRunner | Out-Null
        # Re-check rather than assuming a reboot is needed -- on some
        # machines (virtualization already on in firmware, etc.) WSL2
        # becomes usable immediately and there's no reason to force a
        # reboot the user doesn't actually need.
        if (-not (Test-WslReady -WslRunner $WslRunner -CommandChecker $CommandChecker)) {
            return [pscustomobject]@{ Status = 'reboot-required'; Detail = 'Installed the WSL2 platform -- a reboot is required before Docker Desktop can finish installing. Reboot, then re-run install.ps1; it resumes automatically.' }
        }
    }

    & $Downloader -Url $InstallerUrl -Destination $DownloadPath

    $installResult = & $ProcessRunner -FilePath $DownloadPath -ArgumentList @('install', '--quiet', '--accept-license', '--backend=wsl-2')
    if ($installResult.ExitCode -ne 0) {
        return [pscustomobject]@{ Status = 'failed'; Detail = "Docker Desktop installer exited with code $($installResult.ExitCode)." }
    }

    # The installer just added its CLI directory to the *system* PATH, but
    # this already-running process (especially the elevated relaunch from
    # install.ps1) captured its own $env:PATH at launch and won't see that
    # change on its own. Without this, the polling loop below would never
    # find `docker` and would always time out, even on a fully successful
    # install. Refresh from the registry, and belt-and-suspenders-add
    # Docker Desktop's known CLI directory directly.
    $machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
    $dockerCliDir = Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin'
    if ((Test-Path -Path $dockerCliDir) -and ($env:Path -notlike "*$dockerCliDir*")) {
        $env:Path = "$dockerCliDir;$env:Path"
    }

    return Start-DockerDesktopAndWait -CommandChecker $CommandChecker -DockerInfoChecker $DockerInfoChecker `
        -PathTester $PathTester -AppLauncher $AppLauncher `
        -StartupTimeoutSeconds $StartupTimeoutSeconds -PollIntervalSeconds $PollIntervalSeconds
}

Export-ModuleMember -Function `
    Test-IsElevated, Test-DockerAvailable, Test-DockerInstalled, Start-DockerDesktopAndWait, `
    Test-WslReady, Install-WslPlatform, Install-DockerDesktop, `
    Get-PrereqProcessRunner, Set-PrereqProcessRunner, `
    Get-Downloader, Set-Downloader, `
    Get-CommandChecker, Set-CommandChecker, `
    Get-DockerInfoChecker, Set-DockerInfoChecker, `
    Get-ElevationChecker, Set-ElevationChecker, `
    Get-WslRunner, Set-WslRunner, `
    Get-PathTester, Set-PathTester, `
    Get-AppLauncher, Set-AppLauncher
