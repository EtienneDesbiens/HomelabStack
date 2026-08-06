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

Describe 'Test-TailscaleInstalled' {
    # Every test here mocks -PathTester explicitly -- same reasoning as
    # Test-DockerInstalled's tests: without it, the default PathTester
    # does a real Test-Path against Program Files, and the result would
    # silently depend on whether Tailscale happens to be installed on
    # whatever machine runs this suite.

    It 'is true when the tailscale command resolves' {
        $result = Test-TailscaleInstalled -CommandChecker { param($n) $n -eq 'tailscale' } -PathTester { param($p) $false }
        $result | Should Be $true
    }

    It 'is true when the command does not resolve but the exe is present' {
        $result = Test-TailscaleInstalled -CommandChecker { param($n) $false } -PathTester { param($p) $true }
        $result | Should Be $true
    }

    It 'is false when neither the command nor the exe are present' {
        $result = Test-TailscaleInstalled -CommandChecker { param($n) $false } -PathTester { param($p) $false }
        $result | Should Be $false
    }
}

Describe 'Install-TailscaleClient' {

    It 'short-circuits when already installed -- no download, no install' {
        $box = @{ downloaded = $false }
        $result = Install-TailscaleClient `
            -CommandChecker { param($n) $true } -PathTester { param($p) $true } `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure()
        $result.Status | Should Be 'already-installed'
        $box.downloaded | Should Be $false
    }

    It 'reports needs-elevation and does not attempt install when not elevated' {
        $box = @{ downloaded = $false }
        $result = Install-TailscaleClient `
            -CommandChecker { param($n) $false } -PathTester { param($p) $false } `
            -ElevationChecker { $false } `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure()
        $result.Status | Should Be 'needs-elevation'
        $box.downloaded | Should Be $false
    }

    It 'downloads and silently installs when elevated and not yet installed' {
        $box = @{ downloadedUrl = $null; installArgs = $null; installed = $false }
        $result = Install-TailscaleClient `
            -CommandChecker { param($n) if ($n -eq 'tailscale') { return $box.installed }; return $false } `
            -PathTester { param($p) $false } `
            -ElevationChecker { $true } `
            -Downloader { param($Url, $Destination) $box.downloadedUrl = $Url }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.installArgs = $ArgumentList; $box.installed = $true; [pscustomobject]@{ ExitCode = 0 } }.GetNewClosure()
        $result.Status | Should Be 'installed'
        $box.downloadedUrl | Should Match 'tailscale'
        ($box.installArgs -join ' ') | Should Match '/quiet'
    }

    It 'reports failed when the installer exits non-zero' {
        $result = Install-TailscaleClient `
            -CommandChecker { param($n) $false } -PathTester { param($p) $false } `
            -ElevationChecker { $true } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 1 } }
        $result.Status | Should Be 'failed'
    }

    It 'reports failed if the client still is not detected right after a successful installer exit' {
        $result = Install-TailscaleClient `
            -CommandChecker { param($n) $false } -PathTester { param($p) $false } `
            -ElevationChecker { $true } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 0 } }
        $result.Status | Should Be 'failed'
    }
}

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

Describe 'Test-DockerInstalled' {
    # Every test here mocks -PathTester explicitly, even where the
    # CommandChecker already decides the outcome -- otherwise the default
    # PathTester does a *real* Test-Path against Program Files, and the
    # result would silently depend on whether Docker happens to be
    # installed on whatever machine runs this suite.

    It 'is true when the docker command resolves, even if the daemon is not running' {
        $result = Test-DockerInstalled -CommandChecker { param($n) $n -eq 'docker' } -PathTester { param($p) $false }
        $result | Should Be $true
    }

    It 'is true when the command does not resolve but the Desktop app exe is present' {
        $result = Test-DockerInstalled -CommandChecker { param($n) $false } -PathTester { param($p) $true }
        $result | Should Be $true
    }

    It 'is false when neither the command nor the app exe are present' {
        $result = Test-DockerInstalled -CommandChecker { param($n) $false } -PathTester { param($p) $false }
        $result | Should Be $false
    }
}

Describe 'Start-DockerDesktopAndWait' {

    It 'launches the app when its exe is present, then polls until available' {
        $box = @{ launched = $false; checkCount = 0 }
        $result = Start-DockerDesktopAndWait `
            -CommandChecker { param($n) $true } `
            -DockerInfoChecker { $box.checkCount++; return ($box.checkCount -ge 2) }.GetNewClosure() `
            -PathTester { param($p) $true } `
            -AppLauncher { param($p) $box.launched = $true }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.launched | Should Be $true
    }

    It 'does not try to launch anything when the exe is not present' {
        $box = @{ launched = $false }
        $result = Start-DockerDesktopAndWait `
            -CommandChecker { param($n) $true } -DockerInfoChecker { $true } `
            -PathTester { param($p) $false } `
            -AppLauncher { param($p) $box.launched = $true }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.launched | Should Be $false
    }

    It 'reports failed if Docker never responds within the timeout' {
        $result = Start-DockerDesktopAndWait `
            -CommandChecker { param($n) $false } -DockerInfoChecker { $false } `
            -PathTester { param($p) $false } -AppLauncher { param($p) } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 0
        $result.Status | Should Be 'failed'
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

    It 'starts Docker Desktop without elevation or reinstalling when it is installed but not running' {
        # This is the exact real-world case that motivated this test:
        # Desktop doesn't always auto-launch after install or a reboot,
        # and an earlier version of this code treated "not available" as
        # "not installed" and tried to reinstall from scratch, needlessly
        # forcing a UAC prompt in install.ps1's wrapper along the way.
        $box = @{ downloaded = $false; installArgs = $null; launched = $false; checkCount = 0 }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -eq 'docker' } `
            -DockerInfoChecker { $box.checkCount++; return ($box.checkCount -ge 2) }.GetNewClosure() `
            -ElevationChecker { $false } `
            -PathTester { param($p) $true } `
            -AppLauncher { param($p) $box.launched = $true }.GetNewClosure() `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.installArgs = $ArgumentList; [pscustomobject]@{ ExitCode = 0 } }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.launched | Should Be $true
        $box.downloaded | Should Be $false
        $box.installArgs | Should Be $null
    }

    It 'reports needs-elevation and does not attempt install when not elevated and not installed' {
        $box = @{ downloaded = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $false } -DockerInfoChecker { $false } `
            -ElevationChecker { $false } -PathTester { param($p) $false } `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'needs-elevation'
        $box.downloaded | Should Be $false
    }

    It 'installs the WSL2 platform and reports reboot-required if it is still not ready afterward, without downloading anything' {
        $box = @{ downloaded = $false; wslInstallRan = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -eq 'wsl.exe' } `
            -DockerInfoChecker { $false } `
            -ElevationChecker { $true } -PathTester { param($p) $false } `
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
        # CommandChecker tracks a "has the installer run yet" flag for
        # 'docker' specifically, rather than being unconditionally true --
        # an earlier version of this test used an unconditional CommandChecker,
        # which (after the Test-DockerInstalled short-circuit was added)
        # made Install-DockerDesktop divert into the "already installed,
        # just start it" branch instead of exercising the WSL+install path
        # this test means to cover.
        $box = @{ downloaded = $false; statusCallCount = 0; dockerInstalled = $false }
        $result = Install-DockerDesktop `
            -CommandChecker {
                param($n)
                if ($n -eq 'wsl.exe') { return $true }
                if ($n -eq 'docker') { return $box.dockerInstalled }
                return $false
            }.GetNewClosure() `
            -DockerInfoChecker { $true } `
            -ElevationChecker { $true } -PathTester { param($p) $false } `
            -WslRunner {
                param($ArgumentList)
                if ($ArgumentList -contains '--status') { $box.statusCallCount++ }
                # not ready on the first --status check, ready on the re-check after --install
                $exitCode = if ($box.statusCallCount -ge 2) { 0 } else { 1 }
                return [pscustomobject]@{ ExitCode = $exitCode; Output = @() }
            }.GetNewClosure() `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.dockerInstalled = $true; [pscustomobject]@{ ExitCode = 0 } }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.downloaded | Should Be $true
    }

    It 'downloads and silently installs when elevated and WSL2 is already ready, then confirms it started' {
        $box = @{ downloadedUrl = $null; installArgs = $null; dockerInstalled = $false }
        $result = Install-DockerDesktop `
            -CommandChecker {
                param($n)
                if ($n -eq 'wsl.exe') { return $true }
                if ($n -eq 'docker') { return $box.dockerInstalled }
                return $false
            }.GetNewClosure() `
            -DockerInfoChecker { $true } `
            -ElevationChecker { $true } -PathTester { param($p) $false } `
            -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } } `
            -Downloader { param($Url, $Destination) $box.downloadedUrl = $Url }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.installArgs = $ArgumentList; $box.dockerInstalled = $true; [pscustomobject]@{ ExitCode = 0 } }.GetNewClosure() `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'installed'
        $box.downloadedUrl | Should Match 'desktop.docker.com'
        ($box.installArgs -join ' ') | Should Match '--quiet'
        ($box.installArgs -join ' ') | Should Match '--accept-license'
    }

    It 'reports failed when the installer exits non-zero' {
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -eq 'wsl.exe' } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } -PathTester { param($p) $false } `
            -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 1 } } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 5
        $result.Status | Should Be 'failed'
    }

    It 'reports failed if Docker never responds within the startup timeout' {
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $n -eq 'wsl.exe' } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } -PathTester { param($p) $false } `
            -WslRunner { param($ArgumentList) [pscustomobject]@{ ExitCode = 0; Output = @() } } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 0 } } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 0
        $result.Status | Should Be 'failed'
    }
}
