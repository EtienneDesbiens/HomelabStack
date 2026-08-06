#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for lib/Prereqs.psm1: the Docker Desktop bootstrap
    decision logic. Every external touchpoint (process launch, download,
    elevation, Windows features, docker CLI) is mocked -- these tests never
    run a real installer, never touch real Windows features, and never
    need real elevation.

    NOTE: closures use a hashtable "box" rather than $script: variables --
    see the note at the top of Deploy.Tests.ps1 for why.

    NOTE: pure ASCII only -- see the note at the top of lib/Gate.psm1.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'lib\Prereqs.psm1') -Force

Describe 'Test-DockerAvailable' {

    It 'is false when the docker command does not exist' {
        $result = Test-DockerAvailable -CommandChecker { param($n) $false } -DockerInfoChecker { $true }
        $result | Should Be $false
    }

    It 'is false when the command exists but the daemon does not respond' {
        $result = Test-DockerAvailable -CommandChecker { param($n) $true } -DockerInfoChecker { $false }
        $result | Should Be $false
    }

    It 'is true only when both the command exists and the daemon responds' {
        $result = Test-DockerAvailable -CommandChecker { param($n) $true } -DockerInfoChecker { $true }
        $result | Should Be $true
    }
}

Describe 'Test-WslReady' {

    It 'is false when wsl.exe does not exist at all' {
        $result = Test-WslReady -CommandChecker { param($n) $false } -WslRunner { throw 'should not be called' }
        $result | Should Be $false
    }

    It 'is false when wsl.exe exists but --status exits non-zero' {
        $result = Test-WslReady -CommandChecker { param($n) $true } -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 1; Output = @() } }
        $result | Should Be $false
    }

    It 'is true only when wsl.exe exists and --status exits zero' {
        $result = Test-WslReady -CommandChecker { param($n) $true } -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } }
        $result | Should Be $true
    }
}

Describe 'Install-WslPlatform' {

    It 'runs wsl --install --no-distro' {
        $box = @{ args = $null }
        Install-WslPlatform -WslRunner { param($ArgumentList) $box.args = $ArgumentList; [pscustomobject]@{ ExitCode = 0; Output = @() } }.GetNewClosure() | Out-Null
        ($box.args -join ' ') | Should Be '--install --no-distro'
    }
}

Describe 'Install-DockerDesktop' {

    It 'short-circuits when Docker is already available -- no download, no install' {
        $box = @{ downloaded = $false; installed = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $true } -DockerInfoChecker { $true } `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.installed = $true; [pscustomobject]@{ExitCode=0} }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'already-available'
        $box.downloaded | Should Be $false
        $box.installed | Should Be $false
    }

    It 'reports needs-elevation and does not attempt install when not elevated' {
        $box = @{ downloaded = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $false } -DockerInfoChecker { $false } `
            -ElevationChecker { $false } `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure()
        $result.Status | Should Be 'needs-elevation'
        $box.downloaded | Should Be $false
    }

    It 'installs the WSL2 platform and reports reboot-required if it is still not ready afterward, without downloading anything' {
        $box = @{ downloaded = $false; wslInstallRan = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -ne 'docker' } `
            -DockerInfoChecker { $false } `
            -ElevationChecker { $true } `
            -WslRunner {
                param($ArgumentList)
                if ($ArgumentList -contains '--install') { $box.wslInstallRan = $true }
                return [pscustomobject]@{ ExitCode = 1; Output = @() }   # never becomes ready
            }.GetNewClosure() `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'reboot-required'
        $box.wslInstallRan | Should Be $true
        $box.downloaded | Should Be $false
    }

    It 'continues installing Docker in the same run when WSL2 becomes ready without a reboot' {
        # CommandChecker is unconditionally true here (both 'docker' and
        # 'wsl.exe' "exist") -- only DockerInfoChecker's call count
        # distinguishes "before install" from "after install, polled".
        # An earlier version of this test used a CommandChecker that
        # permanently returned $false for 'docker', which meant the
        # post-install polling loop could *never* succeed -- it ran for
        # the full real 180s default timeout and hung the test run.
        # -StartupTimeoutSeconds is set explicitly below as a second
        # safety net against that class of bug.
        $box = @{ downloaded = $false; statusCallCount = 0; dockerCheckCount = 0 }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $true } `
            -DockerInfoChecker {
                $box.dockerCheckCount++
                return ($box.dockerCheckCount -ge 2)   # not available at the initial check, available once polled post-install
            }.GetNewClosure() `
            -ElevationChecker { $true } `
            -WslRunner {
                param($ArgumentList)
                if ($ArgumentList -contains '--status') { $box.statusCallCount++ }
                # not ready on the first --status check, ready on the re-check after --install
                $exitCode = if ($box.statusCallCount -ge 2) { 0 } else { 1 }
                return [pscustomobject]@{ ExitCode = $exitCode; Output = @() }
            }.GetNewClosure() `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 0 } } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.downloaded | Should Be $true
    }

    It 'downloads and silently installs when elevated and WSL2 is already ready, then confirms it started' {
        $box = @{ downloadedUrl = $null; installArgs = $null; checkCount = 0 }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $true } `
            -DockerInfoChecker {
                $box.checkCount++
                return ($box.checkCount -ge 2)   # not running yet on first poll, running on second
            }.GetNewClosure() `
            -ElevationChecker { $true } `
            -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } } `
            -Downloader { param($Url, $Destination) $box.downloadedUrl = $Url }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.installArgs = $ArgumentList; [pscustomobject]@{ ExitCode = 0 } }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.downloadedUrl | Should Match 'desktop.docker.com'
        ($box.installArgs -join ' ') | Should Match '--quiet'
        ($box.installArgs -join ' ') | Should Match '--accept-license'
    }

    It 'reports failed when the installer exits non-zero' {
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -ne 'docker' } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } `
            -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 1 } } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'failed'
    }

    It 'reports failed if Docker never responds within the startup timeout' {
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -ne 'docker' } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } `
            -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 0 } } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 0
        $result.Status | Should Be 'failed'
    }
}
