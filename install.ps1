#Requires -Version 5.1
<#
.SYNOPSIS
    Homelab installer wizard. Pick which services to install, deploy
    exactly those (plus dependencies), and validate anything already
    installed is actually configured correctly. Safe to re-run any time.

.PARAMETER WhatIf
    Dry-run mode: runs the full flow (manifest loading, dependency
    resolution, pre-flight checks, ordering, per-service state checks) but
    never calls real Docker -- Deploy.psm1 logs what it would have run
    instead. Manual gates still prompt, since they don't touch Docker.

.PARAMETER ConfigPath
    Where to read/write config.json. Defaults to config.json next to this
    script.

.PARAMETER Select
    Non-interactive: pass service ids directly instead of using the
    checkbox UI (e.g. -Select sonarr,radarr). Mainly for scripted dry-runs
    and testing; a real interactive session omits this.

.PARAMETER SkipDockerInstall
    Skip the Docker Desktop bootstrap entirely, even if Docker isn't
    available. For environments where you're deliberately managing Docker
    yourself, or where the auto-install path (Windows-only, needs
    elevation) doesn't apply.

.PARAMETER SkipTailscaleInstall
    Skip the Tailscale client bootstrap entirely, even if it isn't
    installed. For environments where you're deliberately managing
    Tailscale yourself (or using a different remote-access mesh -- see the
    "Roles and interchangeable options" section of the agnostic
    implementation plan).

    See docs/superpowers/specs/2026-08-06-installer-wizard-design.md for
    the design this script implements.
#>
[CmdletBinding()]
param(
    [switch]$WhatIf,
    [string]$ConfigPath,
    [string[]]$Select,
    [switch]$SkipDockerInstall,
    [switch]$SkipTailscaleInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config.json' }

Import-Module (Join-Path $repoRoot 'lib\Prereqs.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Manifest.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Gate.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Deploy.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Validate.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Report.psm1') -Force

# ---------------------------------------------------------------------------
# Prereq bootstrap (Wizard flow step 0, added on top of the original design
# so this repo is a "clone it and run it" experience with nothing to
# install first). Docker and Tailscale are checked together so there's at
# most one elevation/UAC prompt total, not one per tool. Skipped entirely
# under -WhatIf, or per-tool via -SkipDockerInstall/-SkipTailscaleInstall --
# it's real system state (Windows features, elevated installer runs), not
# something a dry run should ever touch.
# ---------------------------------------------------------------------------

if ($WhatIf) {
    if (-not $SkipDockerInstall -and -not (Test-DockerAvailable)) {
        if (Test-DockerInstalled) {
            Write-Host "`n[docker] would start Docker Desktop (installed but not currently running; real start is skipped under -WhatIf)."
        } else {
            Write-Host "`n[docker] would install Docker Desktop (not currently available; real install is skipped under -WhatIf)."
        }
    }
    if (-not $SkipTailscaleInstall -and -not (Test-TailscaleInstalled)) {
        Write-Host "`n[tailscale] would install the Tailscale client (not currently installed; real install is skipped under -WhatIf)."
    }
} else {
    $needsDockerWork = -not $SkipDockerInstall -and -not (Test-DockerAvailable)
    $needsTailscaleWork = -not $SkipTailscaleInstall -and -not (Test-TailscaleInstalled)

    if ($needsDockerWork -or $needsTailscaleWork) {
        # Docker installed-but-not-running needs no elevation -- only a
        # genuine from-scratch install of either tool does. Checking this
        # up front avoids a needless UAC prompt just to start an app
        # that's already there.
        $dockerNeedsFreshInstall = $needsDockerWork -and -not (Test-DockerInstalled)
        $tailscaleNeedsFreshInstall = $needsTailscaleWork

        if (($dockerNeedsFreshInstall -or $tailscaleNeedsFreshInstall) -and -not (Test-IsElevated)) {
            Write-Host "Relaunching elevated to install what's missing -- approve the Administrator prompt that's about to appear."
            # Elements are individually quoted -- Start-Process's -ArgumentList
            # joins the array with spaces but does not auto-quote elements
            # itself, so an install path containing spaces would otherwise
            # split into multiple arguments. Skip switches are carried
            # through explicitly -- Start-Process launches a brand new
            # process that only sees arguments actually passed to it.
            $relaunchArgs = [System.Collections.Generic.List[string]]::new()
            $relaunchArgs.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-ConfigPath', "`"$ConfigPath`""))
            if ($Select) { $relaunchArgs.AddRange([string[]]@('-Select', "`"$($Select -join ',')`"")) }
            if ($SkipDockerInstall) { $relaunchArgs.Add('-SkipDockerInstall') }
            if ($SkipTailscaleInstall) { $relaunchArgs.Add('-SkipTailscaleInstall') }
            # -WorkingDirectory matters: an elevated relaunch doesn't
            # reliably inherit this process's CWD (it commonly starts in
            # the user's home directory instead), which broke every
            # compose-relative path if anything downstream ever assumed
            # CWD == repo root. Import-ServiceManifests's -RepoRoot now
            # makes compose paths absolute regardless, but setting this
            # explicitly too is cheap insurance against the same class of
            # bug elsewhere.
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Verb RunAs -Wait -PassThru -WorkingDirectory $repoRoot
            exit $proc.ExitCode
        }

        if ($needsDockerWork) {
            if (Test-DockerInstalled) {
                Write-Host "Docker is installed but not running -- starting Docker Desktop (this can take a minute on first launch)..."
            } else {
                Write-Host "`nDocker not found -- installing Docker Desktop. This can take several minutes on a slow connection."
            }
            Write-Host "If a sign-in or setup dialog pops up in the Docker Desktop window, dismiss/skip it -- no Docker Hub account is needed for local use, and this script is waiting on the engine, not on that dialog."
            $dockerInstall = Install-DockerDesktop
            Write-Host "  $($dockerInstall.Detail)"

            if ($dockerInstall.Status -eq 'reboot-required') {
                Write-Host "`nReboot this machine, then run install.ps1 again -- it picks up right where it left off (config.json and everything already deployed is untouched)."
                exit 0
            }
            if ($dockerInstall.Status -in @('failed', 'needs-elevation')) {
                Write-Host "`nCouldn't finish getting Docker running automatically. Open Docker Desktop manually (or install it from https://www.docker.com/products/docker-desktop/ ), then re-run install.ps1 (or pass -SkipDockerInstall if you're managing it yourself)."
                exit 1
            }
        }

        if ($needsTailscaleWork) {
            Write-Host "`nTailscale not found -- installing the Tailscale client. You'll still log in yourself once it's installed (that step needs your own account, further down)."
            $tailscaleInstall = Install-TailscaleClient
            Write-Host "  $($tailscaleInstall.Detail)"
            if ($tailscaleInstall.Status -in @('failed', 'needs-elevation')) {
                Write-Host "`nCouldn't install Tailscale automatically. Install it manually from https://tailscale.com/download/windows , then re-run install.ps1 (or pass -SkipTailscaleInstall if you're managing it yourself)."
                exit 1
            }
        }
    }
}

# ---------------------------------------------------------------------------
# config.json load / first-run prompt (Wizard flow step 1)
# ---------------------------------------------------------------------------

function Get-InstallConfig {
    param([string]$Path)

    if (Test-Path -Path $Path -PathType Leaf) {
        $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $gateState = @{}
        if ($raw.PSObject.Properties.Match('manualGates').Count -gt 0) {
            foreach ($prop in $raw.manualGates.PSObject.Properties) {
                $gateState[$prop.Name] = @{ satisfied = [bool]$prop.Value.satisfied; satisfiedAt = [string]$prop.Value.satisfiedAt }
            }
        }
        return @{
            fastRoot      = [string]$raw.fastRoot
            bulkRoot      = [string]$raw.bulkRoot
            tailnetDomain = if ($raw.PSObject.Properties.Match('tailnetDomain').Count -gt 0) { [string]$raw.tailnetDomain } else { '' }
            selections    = if ($raw.PSObject.Properties.Match('selections').Count -gt 0) { @($raw.selections | ForEach-Object { [string]$_ }) } else { @() }
            manualGates   = $gateState
        }
    }

    Write-Host "No config.json found -- first-run setup."
    $fastRoot = Read-Host 'Fast tier root path (SSD: configs/appdata/databases), e.g. C:\homelab'
    $bulkRoot = Read-Host 'Bulk tier root path (redundant volume: media/downloads/files), e.g. D:\'
    $tailnetDomain = Read-Host 'Tailscale tailnet domain / MagicDNS suffix, e.g. my-tailnet.ts.net (blank is OK, set it later)'
    return @{
        fastRoot      = $fastRoot
        bulkRoot      = $bulkRoot
        tailnetDomain = $tailnetDomain
        selections    = @()
        manualGates   = @{}
    }
}

function Save-InstallConfig {
    param([hashtable]$Config, [string]$Path)
    $gateObj = [ordered]@{}
    foreach ($k in ($Config.manualGates.Keys | Sort-Object)) { $gateObj[$k] = $Config.manualGates[$k] }
    $out = [ordered]@{
        fastRoot      = $Config.fastRoot
        bulkRoot      = $Config.bulkRoot
        tailnetDomain = $Config.tailnetDomain
        selections    = @($Config.selections)
        manualGates   = $gateObj
    }
    ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Checkbox-style selection UI (Wizard flow step 3). Foundation services are
# always-on and never shown as a checkbox.
# ---------------------------------------------------------------------------

function Show-ServiceCheckboxes {
    param([System.Collections.IDictionary]$Manifests, [string[]]$PreSelected = @())

    $selectable = @($Manifests.Values | Where-Object { $_.group -ne 'foundation' } | Sort-Object group, name)
    $checked = [System.Collections.Generic.HashSet[string]]::new([string[]]$PreSelected)

    $foundationNames = (@($Manifests.Values | Where-Object { $_.group -eq 'foundation' } | Sort-Object name) | ForEach-Object { $_.name }) -join ', '
    Write-Host "`nFoundation services (always installed): $foundationNames"

    while ($true) {
        Write-Host "`nServices -- enter a number to toggle, 'a' for all, 'n' for none, 'd' when done:"
        for ($i = 0; $i -lt $selectable.Count; $i++) {
            $svc = $selectable[$i]
            $mark = if ($checked.Contains($svc.id)) { 'x' } else { ' ' }
            Write-Host ('{0,3}. [{1}] {2,-12} {3}' -f ($i + 1), $mark, $svc.group, $svc.name)
        }
        $response = Read-Host 'Selection'
        if ($response -eq 'd') { break }
        elseif ($response -eq 'a') { foreach ($svc in $selectable) { [void]$checked.Add($svc.id) } }
        elseif ($response -eq 'n') { $checked.Clear() }
        else {
            $idx = 0
            if ([int]::TryParse($response, [ref]$idx) -and $idx -ge 1 -and $idx -le $selectable.Count) {
                $id = $selectable[$idx - 1].id
                if ($checked.Contains($id)) { [void]$checked.Remove($id) } else { [void]$checked.Add($id) }
            } else {
                Write-Host "Not understood: '$response'"
            }
        }
    }

    return , @($checked)
}

# ---------------------------------------------------------------------------
# Live re-check wiring for reverifiable acknowledgment gates. Only gates
# marked Reverifiable in Gate.psm1's table need an entry here; the rest are
# handled by Invoke-Gate with no verifier at all.
# ---------------------------------------------------------------------------

function Get-GateVerifier {
    param([string]$GateName, $Manifest, [hashtable]$TierPaths)

    switch ($GateName) {
        'tailscale-login' {
            return {
                try { & tailscale status *> $null; return ($LASTEXITCODE -eq 0) }
                catch { return $false }
            }
        }
        'indexer-keys' {
            return {
                $keyResult = Resolve-ApiKey -Manifest $Manifest -TierPaths $TierPaths
                if ($keyResult.Status -ne 'pass') { return $false }
                $baseUrl = $Manifest.validate.httpCheck.direct.url -replace '/[^/]*$', ''
                $check = Invoke-ConfigCheck -Check ([pscustomobject]@{ type = 'prowlarrIndexerCount' }) -ApiKey $keyResult.Key -HttpBaseUrl $baseUrl
                return ($check.Status -eq 'pass')
            }.GetNewClosure()
        }
        'overseerr-setup' {
            return {
                $keyResult = Resolve-ApiKey -Manifest $Manifest -TierPaths $TierPaths
                if ($keyResult.Status -ne 'pass') { return $false }
                $baseUrl = $Manifest.validate.httpCheck.direct.url -replace '/[^/]*$', ''
                $check = Invoke-ConfigCheck -Check ([pscustomobject]@{ type = 'overseerrPlexLink' }) -ApiKey $keyResult.Key -HttpBaseUrl $baseUrl
                return ($check.Status -eq 'pass')
            }.GetNewClosure()
        }
        default { return $null }
    }
}

function Invoke-ServiceGate {
    <#
    .SYNOPSIS
        Runs one manual gate and records its result. Reads $config and
        $ConfigPath from the enclosing script scope (this is inline
        procedural script, not a tested module -- matches the rest of
        install.ps1's style). -EnvOverrides is a hashtable and mutated in
        place (hashtables are reference types), since its caller needs the
        collected value for the Deploy-Service call that follows.
    #>
    param($GateRef, $Manifest, [string]$AddedBecauseOf, [hashtable]$EnvOverrides, [System.Collections.Generic.List[object]]$GateResults)

    $gateDef = Get-GateDefinition -Name $GateRef.name

    # Fold the service's own URL into the instructions for Acknowledgment
    # gates ("open X and do Y") so the message is actionable on its own --
    # not just naming the app. Input-kind gates (plex-claim, backup-dest)
    # are left alone: their "URL" is external (plex.tv) or not a single
    # app at all (a backup destination).
    $effectiveInstructions = $gateDef.Instructions
    if ($gateDef.Kind -eq 'Acknowledgment') {
        $urls = Get-ServiceUrls -Manifest $Manifest -CaddyDeployed $caddyDeployed -TailnetDomain $tierPaths.TailnetDomain
        if ($urls.Direct) {
            $urlText = if ($urls.Proxied) { "$($urls.Direct) (or $($urls.Proxied))" } else { $urls.Direct }
            $effectiveInstructions = "$($gateDef.Instructions) $urlText"
        }
    }

    if ($WhatIf) {
        # Dry-run: never blocks on real input and never mutates persisted
        # gate state -- just reports what would be asked, per the design
        # doc's "reviewed and regression-tested ... without requiring
        # Docker or real services". Handled here (not by the caller) so
        # every call site -- immediate or deferred-until-after-deploy --
        # gets correct dry-run behavior for free, and the preview's log
        # order actually matches what a real run would do.
        $alreadySatisfied = Test-GateSatisfied -GateState $config.manualGates -Name $GateRef.name
        Write-Host "  [$($GateRef.name)] would $(if ($alreadySatisfied) { 're-check' } else { 'prompt' }): $effectiveInstructions"
        $GateResults.Add([pscustomobject]@{
                GateName = $GateRef.name; ServiceName = $Manifest.name
                Instructions = $effectiveInstructions; Satisfied = $true
            })
        return $true
    }

    $verifier = Get-GateVerifier -GateName $GateRef.name -Manifest $Manifest -TierPaths $tierPaths

    # tailscale-login is the one gate the program can actually perform
    # itself rather than just describe: run `tailscale up` in the
    # background before prompting, so the user only has to complete the
    # browser login, not type the command too. Checked against the
    # verifier first (not just "is it marked satisfied in config") so
    # this also covers "was logged in before, isn't anymore".
    if ($GateRef.name -eq 'tailscale-login' -and $verifier -and -not (& $verifier)) {
        Write-Host '  Starting Tailscale login...'
        Start-TailscaleLogin
    }

    $gateResult = Invoke-Gate -Name $GateRef.name -GateState $config.manualGates -AddedBecauseOf $AddedBecauseOf -Instructions $effectiveInstructions -VerifyScriptBlock $verifier
    $GateResults.Add([pscustomobject]@{
            GateName     = $GateRef.name
            ServiceName  = $Manifest.name
            Instructions = $effectiveInstructions
            Satisfied    = $gateResult.Satisfied
        })
    $hasEnvVar = $GateRef.PSObject.Properties.Match('envVar').Count -gt 0 -and $GateRef.envVar
    if ($gateResult.Satisfied -and $hasEnvVar -and $gateResult.Value) {
        $EnvOverrides[$GateRef.envVar] = $gateResult.Value
    }
    Save-InstallConfig -Config $config -Path $ConfigPath
    return $gateResult.Satisfied
}

# ---------------------------------------------------------------------------
# One-time host bootstrap: create appdata directories so Docker never has
# to improvise a bind-mount target, and seed a starter Caddyfile if one
# doesn't exist yet (never overwrites hand edits on a re-run). Skipped
# entirely under -WhatIf -- it's real filesystem I/O, not a Docker call.
# ---------------------------------------------------------------------------

function Initialize-HostPaths {
    param([System.Collections.IDictionary]$Manifests, [string[]]$SelectedIds, [hashtable]$TierPaths)

    foreach ($id in $SelectedIds) {
        $m = $Manifests[$id]
        if ($m.deployType -ne 'compose') { continue }
        $appdataDir = Join-Path $TierPaths.Fast "appdata\$id"
        if (-not (Test-Path -Path $appdataDir)) {
            New-Item -ItemType Directory -Path $appdataDir -Force | Out-Null
        }
    }

    if ($SelectedIds -contains 'caddy') {
        $caddyfilePath = Join-Path $TierPaths.Fast 'appdata\caddy\Caddyfile'
        if (-not (Test-Path -Path $caddyfilePath)) {
            $template = Join-Path $repoRoot 'compose\foundation\caddy\Caddyfile.template'
            Copy-Item -Path $template -Destination $caddyfilePath -Force
            Write-Host "Seeded a starter Caddyfile at $caddyfilePath (edit it any time; re-runs never overwrite it)."
        }
    }
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

$config = Get-InstallConfig -Path $ConfigPath
$tierPaths = @{ Fast = $config.fastRoot; Bulk = $config.bulkRoot; TailnetDomain = $config.tailnetDomain }

# Step 2: load manifests, validate every manualGates reference up front.
$manifests = Import-ServiceManifests -Root (Join-Path $repoRoot 'services') -RepoRoot $repoRoot
$allGateRefs = @()
foreach ($id in $manifests.Keys) {
    foreach ($g in @($manifests[$id].manualGates)) { $allGateRefs += $g.name }
}
if ($allGateRefs.Count -gt 0) { Test-GateReferencesExist -GateNames $allGateRefs }

$foundationIds = @($manifests.Values | Where-Object { $_.group -eq 'foundation' } | ForEach-Object { $_.id })

# Step 3: selection.
$userSelectedIds = if ($Select) { @($Select) } else { Show-ServiceCheckboxes -Manifests $manifests -PreSelected $config.selections }

# Step 4: dependency resolution.
$initialSelection = @(@($userSelectedIds) + $foundationIds | Select-Object -Unique)
$resolved = Resolve-ServiceSelection -Manifests $manifests -SelectedIds $initialSelection

# Filter "Added X" messaging down to dependencies that actually still need
# work -- one already installed and valid elsewhere shouldn't read as new
# work about to happen (Wizard flow step 5, "deselected-but-installed").
$autoAddedIds = @($resolved.AddedVia.Keys)
$stillNeeded = [System.Collections.Generic.List[string]]::new()
foreach ($depId in $autoAddedIds) {
    $depManifest = $manifests[$depId]
    if ($depManifest.deployType -eq 'compose') {
        $state = Test-ServiceState -Manifest $depManifest -TierPaths $tierPaths -CaddyDeployed $false -TailnetDomain $config.tailnetDomain
        if ($state.Status -ne 'already-valid') { $stillNeeded.Add($depId) }
    } else {
        $stillNeeded.Add($depId)
    }
}
if ($stillNeeded.Count -gt 0) {
    foreach ($group in (@($resolved.AddedVia.GetEnumerator() | Where-Object { $stillNeeded -contains $_.Key }) | Group-Object Value)) {
        $depNames = (@($group.Group) | ForEach-Object { $manifests[$_.Key].name }) -join ', '
        $viaName = $manifests[$group.Name].name
        Write-Host "Added $depNames -- required by $viaName"
    }
}

# Step 5: pre-flight port-collision check. Nothing is deployed until this passes.
$collisions = Get-PortCollisions -Manifests $manifests -SelectedIds $resolved.SelectedIds
if ($collisions.Count -gt 0) {
    Write-Host "`nPort collisions detected -- fix these before anything is deployed:"
    foreach ($c in $collisions) {
        $names = (@($c.ServiceIds) | ForEach-Object { $manifests[$_].name }) -join ', '
        Write-Host "  Port $($c.Port): $names"
    }
    exit 1
}

# Step 6: install order.
$order = Get-InstallOrder -Manifests $manifests -SelectedIds $resolved.SelectedIds

$config.selections = @($resolved.SelectedIds)
Save-InstallConfig -Config $config -Path $ConfigPath

if (-not $WhatIf) {
    Initialize-HostPaths -Manifests $manifests -SelectedIds $resolved.SelectedIds -TierPaths $tierPaths
}

# Step 7: per-service deploy loop.
$caddyDeployed = $false
$results = [System.Collections.Generic.List[object]]::new()
$gateResults = [System.Collections.Generic.List[object]]::new()

foreach ($id in $order) {
    $manifest = $manifests[$id]
    Write-Host "`n=== $($manifest.name) ==="

    if ($manifest.deployType -eq 'compose') {
        # Runs even under -WhatIf: dry-run still checks real current state
        # (per the design doc) so the planned action list is accurate about
        # what would be skipped vs. deployed -- only the deploy itself
        # becomes a no-op below, via Deploy-Service's own -WhatIf switch.
        $preState = Test-ServiceState -Manifest $manifest -TierPaths $tierPaths -CaddyDeployed $caddyDeployed -TailnetDomain $config.tailnetDomain
        if ($preState.Status -eq 'already-valid') {
            Write-Host "Already valid -- skipping deploy. ($($preState.Detail))"
            $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'already-valid'; Detail = $preState.Detail })
            if ($id -eq 'caddy') { $caddyDeployed = $true }
            continue
        }
    }

    $addedBecauseOf = if ($resolved.AddedVia.ContainsKey($id)) { $manifests[$resolved.AddedVia[$id]].name } else { $null }
    $envOverrides = @{}
    $allGatesSatisfied = $true
    $deferredGates = [System.Collections.Generic.List[object]]::new()

    foreach ($gateRef in @($manifest.manualGates)) {
        $gateDef = Get-GateDefinition -Name $gateRef.name

        if ($gateDef.Kind -eq 'Acknowledgment' -and $manifest.deployType -eq 'compose') {
            # Needs this service's own container already running (e.g.
            # "open Overseerr and finish its setup") -- defer until after
            # Deploy-Service below instead of asking before the container
            # even exists. Input-kind gates (plex-claim, backup-dest) stay
            # here: their collected value feeds this same deploy's
            # environment, so they have to run first. Manual-deployType
            # services (Tailscale) have no deploy step to defer to, so
            # their gates -- Acknowledgment or not -- are handled below too.
            $deferredGates.Add($gateRef)
            continue
        }

        if (-not (Invoke-ServiceGate -GateRef $gateRef -Manifest $manifest -AddedBecauseOf $addedBecauseOf -EnvOverrides $envOverrides -GateResults $gateResults)) {
            $allGatesSatisfied = $false
        }
    }

    if ($manifest.deployType -eq 'manual') {
        foreach ($gateRef in $deferredGates) {
            if (-not (Invoke-ServiceGate -GateRef $gateRef -Manifest $manifest -AddedBecauseOf $addedBecauseOf -EnvOverrides $envOverrides -GateResults $gateResults)) {
                $allGatesSatisfied = $false
            }
        }
        $status = if ($allGatesSatisfied) { 'installed' } else { 'needs-attention' }
        $detail = if ($allGatesSatisfied) { 'manual setup confirmed' } else { 'manual setup still outstanding' }
        $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = $status; Detail = $detail })
        continue
    }

    $deployResult = Deploy-Service -Manifest $manifest -TierPaths $tierPaths -EnvOverrides $envOverrides -WhatIf:$WhatIf
    Write-Host "  $($deployResult.Action)"

    if ($WhatIf) {
        # Still preview the deferred (post-deploy) gates here, in the same
        # relative position a real run would reach them, so the dry-run
        # log order actually matches what a real run would do.
        foreach ($gateRef in $deferredGates) {
            Invoke-ServiceGate -GateRef $gateRef -Manifest $manifest -AddedBecauseOf $addedBecauseOf -EnvOverrides $envOverrides -GateResults $gateResults | Out-Null
        }
        $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'would-deploy'; Detail = $deployResult.Action })
        continue
    }

    if ($deployResult.ExitCode -ne 0) {
        $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'needs-attention'; Detail = "deploy failed: $($deployResult.Output -join ' ')" })
        continue
    }

    if ($manifest.deployType -eq 'dockerNetwork') {
        $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'installed'; Detail = $deployResult.Action })
        continue
    }

    # The container is confirmed up now -- safe to run the gates that
    # needed it running (e.g. "open Overseerr and finish its setup").
    foreach ($gateRef in $deferredGates) {
        if (-not (Invoke-ServiceGate -GateRef $gateRef -Manifest $manifest -AddedBecauseOf $addedBecauseOf -EnvOverrides $envOverrides -GateResults $gateResults)) {
            $allGatesSatisfied = $false
        }
    }

    $postState = Test-ServiceState -Manifest $manifest -TierPaths $tierPaths -CaddyDeployed $caddyDeployed -TailnetDomain $config.tailnetDomain
    $finalStatus = if ($postState.Status -eq 'already-valid') { 'installed' } else { 'needs-attention' }
    $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = $finalStatus; Detail = $postState.Detail })

    if ($id -eq 'caddy' -and $finalStatus -eq 'installed') { $caddyDeployed = $true }
}

# Step 8: report.
Write-Host "`n"
Write-Host (Format-InstallReport -Results $results -GateResults $gateResults)
