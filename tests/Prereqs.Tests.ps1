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

Describe 'Test-WslReady / Enable-WslFeatures' {

    It 'is ready when both features are enabled' {
        $result = Test-WslReady -WslFeatureChecker { param($f) $true }
        $result | Should Be $true
    }

    It 'is not ready when either feature is missing' {
        $result = Test-WslReady -WslFeatureChecker { param($f) $f -ne 'VirtualMachinePlatform' }
        $result | Should Be $false
    }

    It 'enables only the features that are missing and reports a change occurred' {
        $box = @{ enabled = [System.Collections.Generic.List[string]]::new() }
        $checker = { param($f) $f -eq 'Microsoft-Windows-Subsystem-Linux' }   # only WSL feature already on
        $enabler = { param($f) $box.enabled.Add($f) }.GetNewClosure()
        $changed = Enable-WslFeatures -WslFeatureChecker $checker -WslFeatureEnabler $enabler
        $changed | Should Be $true
        $box.enabled.Count | Should Be 1
        $box.enabled[0] | Should Be 'VirtualMachinePlatform'
    }

    It 'reports no change when both features were already enabled' {
        $changed = Enable-WslFeatures -WslFeatureChecker { param($f) $true } -WslFeatureEnabler { param($f) throw 'should not be called' }
        $changed | Should Be $false
    }
}

Describe 'Install-DockerDesktop' {

    It 'short-circuits when Docker is already available -- no download, no install' {
        $box = @{ downloaded = $false; installed = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $true } -DockerInfoChecker { $true } `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure() `
            -ProcessRunner { param($FilePath, $ArgumentList) $box.installed = $true; [pscustomobject]@{ExitCode=0} }.GetNewClosure()
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

    It 'enables WSL2 features and reports reboot-required, without downloading anything' {
        $box = @{ downloaded = $false; featureEnabled = $false }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $false } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } `
            -WslFeatureChecker { param($f) $false } `
            -WslFeatureEnabler { param($f) $box.featureEnabled = $true }.GetNewClosure() `
            -Downloader { param($Url, $Destination) $box.downloaded = $true }.GetNewClosure()
        $result.Status | Should Be 'reboot-required'
        $box.featureEnabled | Should Be $true
        $box.downloaded | Should Be $false
    }

    It 'downloads and silently installs when elevated and WSL2 is ready, then confirms it started' {
        $box = @{ downloadedUrl = $null; installArgs = $null; checkCount = 0 }
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $true } `
            -DockerInfoChecker {
                $box.checkCount++
                return ($box.checkCount -ge 2)   # not running yet on first poll, running on second
            }.GetNewClosure() `
            -ElevationChecker { $true } `
            -WslFeatureChecker { param($f) $true } `
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
            -CommandChecker { param($n) $false } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } `
            -WslFeatureChecker { param($f) $true } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 1 } }
        $result.Status | Should Be 'failed'
    }

    It 'reports failed if Docker never responds within the startup timeout' {
        $result = Install-DockerDesktop `
            -CommandChecker { param($n) $false } -DockerInfoChecker { $false } `
            -ElevationChecker { $true } `
            -WslFeatureChecker { param($f) $true } `
            -Downloader { param($Url, $Destination) } `
            -ProcessRunner { param($FilePath, $ArgumentList) [pscustomobject]@{ ExitCode = 0 } } `
            -PollIntervalSeconds 0 -StartupTimeoutSeconds 0
        $result.Status | Should Be 'failed'
    }
}
