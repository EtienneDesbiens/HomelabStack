#Requires -Version 5.1
<#
.SYNOPSIS
    docker compose up wrapper, shared-network prep, and a small injectable
    command runner so tests and -WhatIf mode never have to touch real Docker.

    See docs/superpowers/specs/2026-08-06-installer-wizard-design.md
    ("Wizard flow" step 7, "Testing approach") for the design this module
    implements.

    NOTE: pure ASCII only in this file -- see the note at the top of
    Gate.psm1 for why.
#>

Set-StrictMode -Version Latest

# The default runner shells out to the real docker CLI, capturing combined
# stdout+stderr and the exit code. Tests and dry-run mode substitute this
# via Set-DockerRunner so nothing here ever needs a real Docker daemon.
$script:DockerRunner = {
    param(
        [string[]]$Arguments,
        [hashtable]$EnvVars = @{}
    )
    $original = @{}
    foreach ($key in $EnvVars.Keys) {
        $original[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
        [System.Environment]::SetEnvironmentVariable($key, [string]$EnvVars[$key], 'Process')
    }
    try {
        $output = & docker @Arguments 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }); Arguments = $Arguments }
    } finally {
        foreach ($key in $EnvVars.Keys) {
            [System.Environment]::SetEnvironmentVariable($key, $original[$key], 'Process')
        }
    }
}

function Get-DockerRunner {
    [CmdletBinding()]
    param()
    $script:DockerRunner
}

function Set-DockerRunner {
    <#
    .SYNOPSIS
        Overrides the scriptblock used to invoke docker. Takes -Arguments
        (string[]) and -EnvVars (hashtable) and must return an object with
        ExitCode and Output properties. Used by Pester to mock docker
        without a daemon.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Runner
    )
    $script:DockerRunner = $Runner
}

function Get-ManifestNetworkName {
    param($Manifest)
    if (@($Manifest.PSObject.Properties.Name) -contains 'network') { return $Manifest.network }
    return 'proxy-net'
}

function Deploy-Service {
    <#
    .SYNOPSIS
        Deploys one service per its manifest's deployType:
          - 'compose'       : docker compose -f <file> up -d, with FAST_ROOT/
                               BULK_ROOT and any gate-supplied values as env.
          - 'dockerNetwork' : idempotent `docker network create` for the
                               shared network foundation services join.
          - 'manual'        : no Docker action at all (e.g. a host-level
                               app like Tailscale) -- the manifest's
                               manualGates carry the real work.

    .PARAMETER WhatIf
        Skips the docker runner entirely and returns a logged description
        of what would have run -- this is the dry-run mode from the design
        doc's "Testing approach" section.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][hashtable]$TierPaths,
        [hashtable]$EnvOverrides = @{},
        [scriptblock]$DockerRunner,
        [switch]$WhatIf
    )

    if (-not $DockerRunner) { $DockerRunner = Get-DockerRunner }
    $deployType = $Manifest.deployType

    switch ($deployType) {
        'manual' {
            return [pscustomobject]@{
                Id = $Manifest.id; DeployType = $deployType; Action = 'none (manual/host-level service)'
                ExitCode = 0; Output = @(); WhatIf = [bool]$WhatIf
            }
        }

        'dockerNetwork' {
            $networkName = Get-ManifestNetworkName -Manifest $Manifest
            if ($WhatIf) {
                return [pscustomobject]@{
                    Id = $Manifest.id; DeployType = $deployType
                    Action = "would ensure docker network '$networkName' exists"
                    ExitCode = 0; Output = @(); WhatIf = $true
                }
            }
            $check = & $DockerRunner -Arguments @('network', 'ls', '--filter', "name=^$networkName`$", '--format', '{{.Name}}') -EnvVars @{}
            if ($check.ExitCode -ne 0) {
                return [pscustomobject]@{
                    Id = $Manifest.id; DeployType = $deployType; Action = 'docker network ls'
                    ExitCode = $check.ExitCode; Output = $check.Output; WhatIf = $false
                }
            }
            if (@($check.Output) -contains $networkName) {
                return [pscustomobject]@{
                    Id = $Manifest.id; DeployType = $deployType; Action = "network '$networkName' already exists"
                    ExitCode = 0; Output = $check.Output; WhatIf = $false
                }
            }
            $create = & $DockerRunner -Arguments @('network', 'create', $networkName) -EnvVars @{}
            return [pscustomobject]@{
                Id = $Manifest.id; DeployType = $deployType; Action = "docker network create $networkName"
                ExitCode = $create.ExitCode; Output = $create.Output; WhatIf = $false
            }
        }

        default {
            # 'compose'
            $envVars = @{
                FAST_ROOT      = $TierPaths.Fast
                BULK_ROOT      = $TierPaths.Bulk
                TAILNET_DOMAIN = if ($TierPaths.ContainsKey('TailnetDomain')) { $TierPaths.TailnetDomain } else { '' }
            }
            foreach ($key in $EnvOverrides.Keys) { $envVars[$key] = $EnvOverrides[$key] }

            $composeArgs = @('compose', '-f', $Manifest.compose, 'up', '-d')

            if ($WhatIf) {
                return [pscustomobject]@{
                    Id = $Manifest.id; DeployType = $deployType
                    Action = "would run: docker $($composeArgs -join ' ') (env: $($envVars.Keys -join ', '))"
                    ExitCode = 0; Output = @(); WhatIf = $true
                }
            }

            $result = & $DockerRunner -Arguments $composeArgs -EnvVars $envVars
            return [pscustomobject]@{
                Id = $Manifest.id; DeployType = $deployType; Action = "docker $($composeArgs -join ' ')"
                ExitCode = $result.ExitCode; Output = $result.Output; WhatIf = $false
            }
        }
    }
}

Export-ModuleMember -Function Get-DockerRunner, Set-DockerRunner, Deploy-Service
