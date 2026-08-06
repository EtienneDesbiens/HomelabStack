#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for lib/Deploy.psm1: -WhatIf dry-run mode and the
    injectable docker runner, per the design doc's "Testing approach"
    section. No Docker daemon required -- the runner is always mocked here.

    NOTE: closures below capture a hashtable "box" (a reference type)
    rather than a $script: variable -- mixing $script: writes inside a
    mock scriptblock with plain reads in the It block resolves to two
    different variables under Pester 3's scoping and silently never sees
    the write. A boxed hashtable sidesteps that entirely.

    NOTE: pure ASCII only -- see the note at the top of lib/Gate.psm1.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'lib\Deploy.psm1') -Force

$tiers = @{ Fast = 'C:\homelab'; Bulk = 'D:\' }

Describe 'Deploy-Service -WhatIf' {

    It 'does not invoke the docker runner for a compose service' {
        $box = @{ ranReal = $false }
        Set-DockerRunner -Runner { param($Arguments, $EnvVars) $box.ranReal = $true; [pscustomobject]@{ ExitCode = 0; Output = @() } }.GetNewClosure()
        $manifest = [pscustomobject]@{ id = 'sonarr'; deployType = 'compose'; compose = 'compose/media/sonarr.yml' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers -WhatIf
        $box.ranReal | Should Be $false
        $result.WhatIf | Should Be $true
        $result.Action | Should Match 'would run'
    }

    It 'does not invoke the docker runner for a dockerNetwork service' {
        $box = @{ ranReal = $false }
        Set-DockerRunner -Runner { param($Arguments, $EnvVars) $box.ranReal = $true; [pscustomobject]@{ ExitCode = 0; Output = @() } }.GetNewClosure()
        $manifest = [pscustomobject]@{ id = 'docker-network'; deployType = 'dockerNetwork'; network = 'proxy-net' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers -WhatIf
        $box.ranReal | Should Be $false
        $result.WhatIf | Should Be $true
    }
}

Describe 'Deploy-Service compose deploys' {

    It 'passes FAST_ROOT, BULK_ROOT and gate-supplied env vars to the runner' {
        $box = @{ captured = $null }
        Set-DockerRunner -Runner {
            param($Arguments, $EnvVars)
            $box.captured = $EnvVars
            [pscustomobject]@{ ExitCode = 0; Output = @('done') }
        }.GetNewClosure()
        $manifest = [pscustomobject]@{ id = 'plex'; deployType = 'compose'; compose = 'compose/media/plex.yml' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers -EnvOverrides @{ PLEX_CLAIM = 'claim-abc' }
        $result.ExitCode | Should Be 0
        $box.captured['FAST_ROOT'] | Should Be 'C:\homelab'
        $box.captured['BULK_ROOT'] | Should Be 'D:\'
        $box.captured['PLEX_CLAIM'] | Should Be 'claim-abc'
    }

    It 'surfaces a non-zero exit code from the runner' {
        Set-DockerRunner -Runner { param($Arguments, $EnvVars) [pscustomobject]@{ ExitCode = 1; Output = @('boom') } }
        $manifest = [pscustomobject]@{ id = 'plex'; deployType = 'compose'; compose = 'compose/media/plex.yml' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers
        $result.ExitCode | Should Be 1
    }
}

Describe 'Deploy-Service dockerNetwork idempotency' {

    It 'creates the network when it does not exist yet' {
        $box = @{ created = $false }
        Set-DockerRunner -Runner {
            param($Arguments, $EnvVars)
            if ($Arguments[0] -eq 'network' -and $Arguments[1] -eq 'ls') { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
            if ($Arguments[0] -eq 'network' -and $Arguments[1] -eq 'create') { $box.created = $true; return [pscustomobject]@{ ExitCode = 0; Output = @('proxy-net') } }
        }.GetNewClosure()
        $manifest = [pscustomobject]@{ id = 'docker-network'; deployType = 'dockerNetwork'; network = 'proxy-net' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers
        $box.created | Should Be $true
        $result.ExitCode | Should Be 0
    }

    It 'skips creation when the network already exists' {
        $box = @{ created = $false }
        Set-DockerRunner -Runner {
            param($Arguments, $EnvVars)
            if ($Arguments[0] -eq 'network' -and $Arguments[1] -eq 'ls') { return [pscustomobject]@{ ExitCode = 0; Output = @('proxy-net') } }
            if ($Arguments[0] -eq 'network' -and $Arguments[1] -eq 'create') { $box.created = $true; return [pscustomobject]@{ ExitCode = 0; Output = @() } }
        }.GetNewClosure()
        $manifest = [pscustomobject]@{ id = 'docker-network'; deployType = 'dockerNetwork'; network = 'proxy-net' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers
        $box.created | Should Be $false
        $result.Action | Should Match 'already exists'
    }
}

Describe 'Deploy-Service manual services' {

    It 'takes no Docker action at all' {
        $box = @{ ranReal = $false }
        Set-DockerRunner -Runner { param($Arguments, $EnvVars) $box.ranReal = $true; [pscustomobject]@{ ExitCode = 0; Output = @() } }.GetNewClosure()
        $manifest = [pscustomobject]@{ id = 'tailscale'; deployType = 'manual' }
        $result = Deploy-Service -Manifest $manifest -TierPaths $tiers
        $box.ranReal | Should Be $false
        $result.ExitCode | Should Be 0
    }
}
