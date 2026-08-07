#Requires -Version 5.1
<#
.SYNOPSIS
    Central table of named manual gates and the pause-and-prompt logic that
    drives them.

    See docs/superpowers/specs/2026-08-06-installer-wizard-design.md
    ("Manual-gate mechanics") for the design this module implements.

    NOTE: pure ASCII only in this file. Windows PowerShell 5.1 misparses
    non-ASCII characters (em-dashes, smart quotes) in a .psm1 saved without
    a BOM -- learned the hard way while building Manifest.psm1.
#>

Set-StrictMode -Version Latest

# Kind = 'Input'         : script needs a value it cannot obtain itself (token/credential).
#                          Once used successfully, permanently satisfied -- never re-validated.
# Kind = 'Acknowledgment' : a real-world action the script cannot perform but can sometimes
#                          verify after the fact. Reverifiable=$true means a VerifyScriptBlock
#                          (supplied by the caller at Invoke-Gate time) re-checks it on every run;
#                          Reverifiable=$false means it is trusted once acknowledged.
$script:GateDefinitions = @{
    'plex-claim'            = @{
        Name         = 'plex-claim'
        Kind         = 'Input'
        EnvVar       = 'PLEX_CLAIM'
        Sensitive    = $false
        Prompt       = 'Plex claim token'
        Instructions = 'Get a claim token from https://www.plex.tv/claim (valid about 4 minutes) and paste it below.'
    }
    'backup-dest'           = @{
        Name         = 'backup-dest'
        Kind         = 'Input'
        EnvVar       = 'BACKUP_DEST_CONFIG'
        Sensitive    = $true
        Prompt       = 'Backup destination connection details'
        Instructions = 'The backup tool needs a destination to copy to (e.g. cloud object storage or a separate physical drive). Enter its connection details as that tool expects them.'
    }
    'tailscale-login'       = @{
        Name         = 'tailscale-login'
        Kind         = 'Acknowledgment'
        Reverifiable = $true
        Instructions = 'Starting Tailscale login -- a browser window should open for you to finish it. If nothing opens within a few seconds, run "tailscale up" yourself in a terminal to get the login link.'
    }
    'router-dns'            = @{
        Name         = 'router-dns'
        Kind         = 'Acknowledgment'
        Reverifiable = $false
        Instructions = "Point your router (or per-device DNS) at AdGuard Home's address."
    }
    'indexer-keys'          = @{
        Name         = 'indexer-keys'
        Kind         = 'Acknowledgment'
        Reverifiable = $true
        Instructions = 'Open Prowlarr and add your indexer accounts.'
    }
    'immich-mobile-backup'  = @{
        Name         = 'immich-mobile-backup'
        Kind         = 'Acknowledgment'
        Reverifiable = $false
        Instructions = 'Install the Immich mobile app, log in, and confirm a test photo backs up automatically.'
    }
    'vaultwarden-client'    = @{
        Name         = 'vaultwarden-client'
        Kind         = 'Acknowledgment'
        Reverifiable = $false
        Instructions = "Install a Bitwarden-compatible client, point it at this Vaultwarden's URL, and import your existing vault."
    }
    'nextcloud-photos-off'  = @{
        Name         = 'nextcloud-photos-off'
        Kind         = 'Acknowledgment'
        Reverifiable = $false
        Instructions = "Disable Nextcloud's built-in Photos/Memories app so photos aren't stored twice -- Immich is the sole photo path."
    }
    'overseerr-setup'       = @{
        Name         = 'overseerr-setup'
        Kind         = 'Acknowledgment'
        Reverifiable = $true
        Instructions = 'Open Overseerr and complete its first-run setup: sign in with your Plex account and confirm the Sonarr/Radarr connections it detects.'
    }
    'audiobookrequest-setup' = @{
        Name         = 'audiobookrequest-setup'
        Kind         = 'Acknowledgment'
        Reverifiable = $false
        Instructions = 'Open AudiobookRequest and complete its first-run admin setup, then confirm it can reach Readarr.'
    }
    'uptime-monitors-configured' = @{
        Name         = 'uptime-monitors-configured'
        Kind         = 'Acknowledgment'
        Reverifiable = $false
        Instructions = "Add a monitor per service in Uptime Kuma (via Caddy's hostnames), set up a notification channel, and confirm a manual downtime test triggers it."
    }
}

function Get-GateDefinition {
    <#
    .SYNOPSIS
        Looks up one gate definition by name. Throws on an unknown name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $script:GateDefinitions.ContainsKey($Name)) {
        throw "Unknown gate '$Name'. Add it to the gate table in Gate.psm1."
    }
    [pscustomobject]$script:GateDefinitions[$Name]
}

function Get-AllGateNames {
    [CmdletBinding()]
    param()
    return , @($script:GateDefinitions.Keys | Sort-Object)
}

function Test-GateReferencesExist {
    <#
    .SYNOPSIS
        Validates that every gate name a manifest declares in manualGates
        actually exists in this module's table. Called once at startup
        after manifests are loaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$GateNames
    )
    $unknown = @($GateNames | Where-Object { -not $script:GateDefinitions.ContainsKey($_) } | Sort-Object -Unique)
    if ($unknown.Count -gt 0) {
        throw "Manifests reference unknown gate(s): $($unknown -join ', '). Known gates: $((Get-AllGateNames) -join ', ')."
    }
}

function Test-GateSatisfied {
    <#
    .SYNOPSIS
        Reads whether a gate is already recorded as satisfied in the
        persisted gate state (config.json's manualGates section, passed in
        as a plain hashtable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$GateState,
        [Parameter(Mandatory)][string]$Name
    )
    return $GateState.ContainsKey($Name) -and [bool]$GateState[$Name]['satisfied']
}

function Set-GateSatisfied {
    <#
    .SYNOPSIS
        Records a gate as satisfied (or explicitly not) in the gate state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$GateState,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Satisfied = $true
    )
    $GateState[$Name] = @{ satisfied = $Satisfied; satisfiedAt = (Get-Date).ToString('o') }
}

function Invoke-Gate {
    <#
    .SYNOPSIS
        Runs one gate invocation: prompts/pauses as needed, applies the
        Input vs Acknowledgment re-trigger rules, and returns whether it
        ended up satisfied plus any collected value.

    .PARAMETER AddedBecauseOf
        Name of the service that pulled this dependency in, if any -- used
        to make the prompt say "(added as a dependency of Sonarr)" instead
        of leaving the reason a mystery.

    .PARAMETER VerifyScriptBlock
        For reverifiable acknowledgment gates, a caller-supplied 0-arg
        scriptblock returning $true/$false (e.g. checks `tailscale status`
        or queries Prowlarr's indexer list). Gate.psm1 has no knowledge of
        Docker/HTTP/Tailscale itself -- that logic lives in Validate.psm1
        or install.ps1 and is handed in here to avoid a circular module
        dependency.

    .PARAMETER Instructions
        Overrides the gate's own central Instructions text for this call.
        For the same reason Gate.psm1 takes VerifyScriptBlock rather than
        knowing about HTTP itself: the caller (install.ps1/install-gui.ps1)
        knows the specific service's actual URL from its manifest, and can
        fold that into a concrete instruction ("Open Prowlarr at
        http://localhost:9696 and add your indexer accounts.") instead of
        this module needing to know anything about manifests or Docker.
        Defaults to the gate's own Instructions text when not given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$GateState,
        [string]$AddedBecauseOf,
        [string]$Instructions,
        [scriptblock]$VerifyScriptBlock,
        [scriptblock]$ReadInput = { param($prompt) Read-Host -Prompt $prompt },
        [scriptblock]$ReadSecureInput = { param($prompt) Read-Host -Prompt $prompt -AsSecureString },
        [scriptblock]$WriteOutput = { param($text) Write-Host $text },
        [int]$MaxVerifyAttempts = 3
    )

    $def = Get-GateDefinition -Name $Name
    if (-not $Instructions) { $Instructions = $def.Instructions }
    $context = if ($AddedBecauseOf) { " (added as a dependency of $AddedBecauseOf)" } else { '' }

    if ($def.Kind -eq 'Input') {
        if (Test-GateSatisfied -GateState $GateState -Name $Name) {
            return [pscustomobject]@{ Satisfied = $true; Value = $null; Reason = 'already-satisfied' }
        }
        & $WriteOutput "`n[$($def.Name)]$context $Instructions"
        $value = if ($def.Sensitive) {
            $secure = & $ReadSecureInput $def.Prompt
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } else {
            & $ReadInput $def.Prompt
        }
        Set-GateSatisfied -GateState $GateState -Name $Name
        return [pscustomobject]@{ Satisfied = $true; Value = $value; Reason = 'input-collected' }
    }

    # Acknowledgment gate.
    $alreadySatisfied = Test-GateSatisfied -GateState $GateState -Name $Name
    if ($alreadySatisfied -and -not $def.Reverifiable) {
        return [pscustomobject]@{ Satisfied = $true; Value = $null; Reason = 'trusted-acknowledgment' }
    }
    if ($alreadySatisfied -and $def.Reverifiable -and $VerifyScriptBlock) {
        if (& $VerifyScriptBlock) {
            return [pscustomobject]@{ Satisfied = $true; Value = $null; Reason = 'reverified' }
        }
        & $WriteOutput "`n[$($def.Name)] Previously acknowledged, but the live check now fails -- this needs attention again."
    }

    & $WriteOutput "`n[$($def.Name)]$context $Instructions"
    $attempt = 0
    while ($true) {
        $attempt++
        & $ReadInput 'Press Enter once done' | Out-Null
        if (-not $VerifyScriptBlock) {
            Set-GateSatisfied -GateState $GateState -Name $Name
            return [pscustomobject]@{ Satisfied = $true; Value = $null; Reason = 'acknowledged-unverifiable' }
        }
        if (& $VerifyScriptBlock) {
            Set-GateSatisfied -GateState $GateState -Name $Name
            return [pscustomobject]@{ Satisfied = $true; Value = $null; Reason = 'acknowledged-and-verified' }
        }
        if ($attempt -ge $MaxVerifyAttempts) {
            & $WriteOutput "Still failing verification after $attempt attempt(s). Marking as outstanding -- you can re-run the wizard once it's fixed."
            Set-GateSatisfied -GateState $GateState -Name $Name -Satisfied $false
            return [pscustomobject]@{ Satisfied = $false; Value = $null; Reason = 'verification-failed' }
        }
        & $WriteOutput 'Verification failed. Double check the step above, then press Enter to retry.'
    }
}

Export-ModuleMember -Function Get-GateDefinition, Get-AllGateNames, Test-GateReferencesExist, Test-GateSatisfied, Set-GateSatisfied, Invoke-Gate
