#Requires -Version 5.1
<#
.SYNOPSIS
    WinForms GUI wrapper around the console installer wizard (install.ps1).
    Same engine (lib/*.psm1), different presentation layer -- this script
    never modifies Manifest.psm1, Gate.psm1, Deploy.psm1, Validate.psm1,
    Report.psm1, or Prereqs.psm1, and never modifies install.ps1. Their 65
    Pester tests are the correctness net for the engine; this file only
    adds a window on top of it.

    Architecture (see the design review that shaped this):
      - The main (UI) thread builds one persistent window (log + live
        per-service status list + Cancel/Close button) and runs
        [System.Windows.Forms.Application]::Run().
      - All real work (prereq checks/installs, manifest loading, the
        deploy loop, gate prompts) happens in a background Runspace, so
        the window never freezes during a multi-minute Docker install or
        a docker compose call.
      - The background worker streams log lines through a
        ConcurrentQueue that a UI-thread Timer drains a few times a
        second (decouples the producer from the UI thread for the
        high-frequency case).
      - Anything that needs to block the worker and show a dialog (setup
        fields, the service picker, gate prompts, fatal errors) uses
        $syncHash.Window.Invoke(...), which is synchronous: it runs the
        delegate on the UI thread and blocks the calling (background)
        thread until it returns. All dialog-building functions are
        defined *inside* the worker script below (not in this top-level
        script) specifically so that a scriptblock literal written at an
        .Invoke() call site resolves those function names correctly
        regardless of which thread ends up executing it -- a PowerShell
        scriptblock resolves functions/variables against the session
        state it was *parsed* in, not the thread that later invokes it.
      - install.ps1's private functions (Get-InstallConfig,
        Save-InstallConfig, Show-ServiceCheckboxes's selection logic,
        Get-GateVerifier, Initialize-HostPaths, the prereq/elevation
        block) are not importable -- they live in a script, not a module
        -- so they are intentionally duplicated here with their I/O
        swapped for GUI equivalents, not "reused".

    NOTE: pure ASCII only -- see the note at the top of lib/Gate.psm1.
    This applies to every string literal here, including window/dialog
    text, not just code.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipDockerInstall,
    [switch]$SkipTailscaleInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Windows PowerShell 5.1's powershell.exe defaults its main runspace to STA
# already, so WinForms normally works with no extra ceremony. This is
# cheap insurance in case something launches this script in an MTA host.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = [System.Collections.Generic.List[string]]::new()
    $relaunch.AddRange([string[]]@('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""))
    if ($ConfigPath) { $relaunch.AddRange([string[]]@('-ConfigPath', "`"$ConfigPath`"")) }
    if ($SkipDockerInstall) { $relaunch.Add('-SkipDockerInstall') }
    if ($SkipTailscaleInstall) { $relaunch.Add('-SkipTailscaleInstall') }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch | Out-Null
    exit
}

$repoRoot = $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 'config.json' }

# ---------------------------------------------------------------------------
# Shared state between the UI thread and the background worker.
# ---------------------------------------------------------------------------

$syncHash = [hashtable]::Synchronized(@{
        RepoRoot            = $repoRoot
        ConfigPath           = $ConfigPath
        ScriptPath           = $PSCommandPath
        SkipDockerInstall    = [bool]$SkipDockerInstall
        SkipTailscaleInstall = [bool]$SkipTailscaleInstall
        LogQueue             = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        StatusQueue          = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        CancelRequested      = $false
        IsRunning            = $true
        Done                 = $false
        Window               = $null
    })

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HomelabStack Installer'
$form.Width = 900
$form.Height = 650
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(700, 450)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Both'
$logBox.WordWrap = $false
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Dock = 'Fill'

$statusList = New-Object System.Windows.Forms.ListView
$statusList.View = 'Details'
$statusList.FullRowSelect = $true
$statusList.GridLines = $true
$statusList.Dock = 'Fill'
$statusList.Columns.Add('Service', 220) | Out-Null
$statusList.Columns.Add('Status', 140) | Out-Null
$statusList.Columns.Add('Detail', 480) | Out-Null

$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Dock = 'Fill'
$splitContainer.Orientation = 'Horizontal'

$actionButton = New-Object System.Windows.Forms.Button
$actionButton.Text = 'Cancel'
$actionButton.Dock = 'Bottom'
$actionButton.Height = 36
$actionButton.Add_Click({
        if ($syncHash.IsRunning) {
            $syncHash.CancelRequested = $true
            $actionButton.Enabled = $false
            $actionButton.Text = 'Cancelling...'
        } else {
            $form.Close()
        }
    })

$form.Controls.Add($splitContainer)
$form.Controls.Add($actionButton)
$form.Add_Shown({
        $splitContainer.Panel1.Controls.Add($logBox)
        $splitContainer.Panel2.Controls.Add($statusList)
        $splitContainer.SplitterDistance = [int]($form.ClientSize.Height * 0.55)
    })
$form.Add_FormClosing({
        param($formSender, $e)
        if ($syncHash.IsRunning) {
            [System.Windows.Forms.MessageBox]::Show(
                'An install is in progress. Click Cancel first (it finishes the current step, then stops), or wait for it to complete.',
                'HomelabStack Installer', 'OK', 'Warning') | Out-Null
            $e.Cancel = $true
        }
    })

$syncHash.Window = $form

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 200
$logTimer.Add_Tick({
        $line = ''
        while ($syncHash.LogQueue.TryDequeue([ref]$line)) {
            $logBox.AppendText("$line`r`n")
        }
        $statusUpdate = $null
        while ($syncHash.StatusQueue.TryDequeue([ref]$statusUpdate)) {
            $existing = $null
            foreach ($item in $statusList.Items) {
                if ($item.Tag -eq $statusUpdate.Id) { $existing = $item; break }
            }
            if ($existing) {
                $existing.SubItems[1].Text = $statusUpdate.Status
                $existing.SubItems[2].Text = $statusUpdate.Detail
            } else {
                $newItem = New-Object System.Windows.Forms.ListViewItem($statusUpdate.Name)
                $newItem.Tag = $statusUpdate.Id
                $newItem.SubItems.Add($statusUpdate.Status) | Out-Null
                $newItem.SubItems.Add($statusUpdate.Detail) | Out-Null
                $statusList.Items.Add($newItem) | Out-Null
            }
        }
        if ($syncHash.Done -and $syncHash.IsRunning) {
            $syncHash.IsRunning = $false
            $actionButton.Text = 'Close'
            $actionButton.Enabled = $true
        }
    })
$logTimer.Start()

# ---------------------------------------------------------------------------
# Background worker. Everything from here down runs in a separate
# Runspace, not on the UI thread. See the file header for why dialog
# helper functions are defined here rather than in the top-level script.
# ---------------------------------------------------------------------------

$workerScript = {
    param($syncHash)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    Import-Module (Join-Path $syncHash.RepoRoot 'lib\Prereqs.psm1') -Force
    Import-Module (Join-Path $syncHash.RepoRoot 'lib\Manifest.psm1') -Force
    Import-Module (Join-Path $syncHash.RepoRoot 'lib\Gate.psm1') -Force
    Import-Module (Join-Path $syncHash.RepoRoot 'lib\Deploy.psm1') -Force
    Import-Module (Join-Path $syncHash.RepoRoot 'lib\Validate.psm1') -Force
    Import-Module (Join-Path $syncHash.RepoRoot 'lib\Report.psm1') -Force

    function Write-GuiLog {
        param([string]$Text)
        $syncHash.LogQueue.Enqueue($Text)
        $syncHash.LastGateMessage = $Text
    }

    function Update-GuiStatus {
        param([string]$Id, [string]$Name, [string]$Status, [string]$Detail)
        $syncHash.StatusQueue.Enqueue([pscustomobject]@{ Id = $Id; Name = $Name; Status = $Status; Detail = $Detail })
    }

    function Show-GuiError {
        param([string]$Message)
        $syncHash.Window.Invoke([Action]{
                [System.Windows.Forms.MessageBox]::Show($Message, 'HomelabStack Installer', 'OK', 'Error') | Out-Null
            }) | Out-Null
    }

    function ConvertTo-SecureStringFromPlainText {
        param([string]$PlainText)
        $secure = New-Object System.Security.SecureString
        foreach ($ch in $PlainText.ToCharArray()) { $secure.AppendChar($ch) }
        $secure.MakeReadOnly()
        return $secure
    }

    function New-SmallDialog {
        param([string]$Title, [int]$Height = 220)
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = $Title
        $dlg.Width = 520
        $dlg.Height = $Height
        $dlg.StartPosition = 'CenterScreen'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        return $dlg
    }

    function Show-GatePromptDialog {
        <#
        Handles both Invoke-Gate call shapes: a real Input-kind gate
        (Prompt is the field label, a value is expected back) and the
        Acknowledgment-kind "Press Enter once done" call (no real input
        needed -- Gate.psm1 discards the return value via | Out-Null).
        #>
        param([string]$Prompt, [bool]$Sensitive)

        $isAckOnly = ($Prompt -eq 'Press Enter once done')
        $message = if ($syncHash.LastGateMessage) { $syncHash.LastGateMessage } else { $Prompt }

        return $syncHash.Window.Invoke([Func[object]]{
                $dlg = New-SmallDialog -Title 'Action needed' -Height $(if ($isAckOnly) { 200 } else { 240 })

                $label = New-Object System.Windows.Forms.Label
                $label.Text = $message
                $label.SetBounds(12, 12, 480, 90)
                $label.AutoSize = $false

                $dlg.Controls.Add($label)
                $y = 108

                $textBox = $null
                if (-not $isAckOnly) {
                    $textBox = New-Object System.Windows.Forms.TextBox
                    $textBox.SetBounds(12, $y, 480, 24)
                    if ($Sensitive) { $textBox.UseSystemPasswordChar = $true }
                    $dlg.Controls.Add($textBox)
                    $y += 34
                }

                $okButton = New-Object System.Windows.Forms.Button
                $okButton.Text = 'OK'
                $okButton.SetBounds(400, $y, 90, 30)
                $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $dlg.Controls.Add($okButton)
                $dlg.AcceptButton = $okButton

                $dlg.ShowDialog() | Out-Null
                if ($textBox) { return $textBox.Text } else { return '' }
            })
    }

    function Get-GuiInstallConfig {
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

        Write-GuiLog 'No config.json found -- first-run setup.'
        $setup = $syncHash.Window.Invoke([Func[object]]{
                $dlg = New-SmallDialog -Title 'First-run setup' -Height 260

                $lbl1 = New-Object System.Windows.Forms.Label
                $lbl1.Text = 'Fast tier root (SSD: configs/appdata/databases), e.g. C:\homelab'
                $lbl1.SetBounds(12, 10, 480, 18)
                $tb1 = New-Object System.Windows.Forms.TextBox
                $tb1.SetBounds(12, 30, 480, 24)

                $lbl2 = New-Object System.Windows.Forms.Label
                $lbl2.Text = 'Bulk tier root (redundant volume: media/downloads/files), e.g. D:\'
                $lbl2.SetBounds(12, 62, 480, 18)
                $tb2 = New-Object System.Windows.Forms.TextBox
                $tb2.SetBounds(12, 82, 480, 24)

                $lbl3 = New-Object System.Windows.Forms.Label
                $lbl3.Text = 'Tailscale tailnet domain / MagicDNS suffix (blank is OK, set it later)'
                $lbl3.SetBounds(12, 114, 480, 18)
                $tb3 = New-Object System.Windows.Forms.TextBox
                $tb3.SetBounds(12, 134, 480, 24)

                $okButton = New-Object System.Windows.Forms.Button
                $okButton.Text = 'Continue'
                $okButton.SetBounds(380, 172, 112, 30)
                $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK

                $dlg.Controls.AddRange(@($lbl1, $tb1, $lbl2, $tb2, $lbl3, $tb3, $okButton))
                $dlg.AcceptButton = $okButton
                $dlg.ShowDialog() | Out-Null
                return [pscustomobject]@{ Fast = $tb1.Text; Bulk = $tb2.Text; Tailnet = $tb3.Text }
            })

        return @{
            fastRoot      = $setup.Fast
            bulkRoot      = $setup.Bulk
            tailnetDomain = $setup.Tailnet
            selections    = @()
            manualGates   = @{}
        }
    }

    function Save-GuiInstallConfig {
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

    function Show-GuiPicker {
        param([System.Collections.IDictionary]$Manifests, [string[]]$PreSelected)

        $selectable = @($Manifests.Values | Where-Object { $_.group -ne 'foundation' } | Sort-Object group, name)
        $foundationNames = (@($Manifests.Values | Where-Object { $_.group -eq 'foundation' } | Sort-Object name) | ForEach-Object { $_.name }) -join ', '

        return $syncHash.Window.Invoke([Func[object]]{
                $dlg = New-SmallDialog -Title 'Select services to install' -Height 560
                $dlg.Width = 560

                $info = New-Object System.Windows.Forms.Label
                $info.Text = "Foundation services (always installed): $foundationNames"
                $info.SetBounds(12, 10, 520, 40)
                $dlg.Controls.Add($info)

                $checklist = New-Object System.Windows.Forms.CheckedListBox
                $checklist.SetBounds(12, 56, 520, 360)
                $checklist.CheckOnClick = $true
                foreach ($svc in $selectable) {
                    $label = "[$($svc.group)] $($svc.name)"
                    $idx = $checklist.Items.Add($label)
                    if ($PreSelected -contains $svc.id) { $checklist.SetItemChecked($idx, $true) }
                }
                $dlg.Controls.Add($checklist)

                $whatIfBox = New-Object System.Windows.Forms.CheckBox
                $whatIfBox.Text = 'Dry run (preview only -- no changes made)'
                $whatIfBox.SetBounds(12, 424, 400, 24)
                $dlg.Controls.Add($whatIfBox)

                $installButton = New-Object System.Windows.Forms.Button
                $installButton.Text = 'Install'
                $installButton.SetBounds(420, 460, 112, 34)
                $installButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $dlg.Controls.Add($installButton)
                $dlg.AcceptButton = $installButton

                $dlg.ShowDialog() | Out-Null

                $chosen = [System.Collections.Generic.List[string]]::new()
                for ($i = 0; $i -lt $checklist.Items.Count; $i++) {
                    if ($checklist.GetItemChecked($i)) { $chosen.Add($selectable[$i].id) }
                }
                return [pscustomobject]@{ SelectedIds = @($chosen); WhatIf = $whatIfBox.Checked }
            })
    }

    function Get-GuiGateVerifier {
        <#
        Duplicated from install.ps1's Get-GateVerifier -- only the
        reverifiable gates (tailscale-login, indexer-keys, overseerr-setup)
        need a live re-check; the rest have no verifier at all, same as
        the console version.
        #>
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

    function Initialize-GuiHostPaths {
        param([System.Collections.IDictionary]$Manifests, [string[]]$SelectedIds, [hashtable]$TierPaths)
        foreach ($id in $SelectedIds) {
            $m = $Manifests[$id]
            if ($m.deployType -ne 'compose') { continue }
            $appdataDir = Join-Path $TierPaths.Fast "appdata\$id"
            if (-not (Test-Path -Path $appdataDir)) { New-Item -ItemType Directory -Path $appdataDir -Force | Out-Null }
        }
        if ($SelectedIds -contains 'caddy') {
            $caddyfilePath = Join-Path $TierPaths.Fast 'appdata\caddy\Caddyfile'
            if (-not (Test-Path -Path $caddyfilePath)) {
                $template = Join-Path $syncHash.RepoRoot 'compose\foundation\caddy\Caddyfile.template'
                Copy-Item -Path $template -Destination $caddyfilePath -Force
                Write-GuiLog "Seeded a starter Caddyfile at $caddyfilePath (edit it any time; re-runs never overwrite it)."
            }
        }
    }

    # -----------------------------------------------------------------------
    # Main flow -- mirrors install.ps1's structure with GUI-backed I/O.
    # -----------------------------------------------------------------------

    try {
        # --- Step 0: prereqs. Always done for real regardless of the
        # dry-run choice made later at the picker -- that choice only
        # covers the service deploy plan, not whether Docker/Tailscale
        # get installed, since a meaningful preview still needs Docker
        # present for its real state checks (per the design's dry-run
        # intent: only the deploy action itself is a no-op).
        $needsDockerWork = -not $syncHash.SkipDockerInstall -and -not (Test-DockerAvailable)
        $needsTailscaleWork = -not $syncHash.SkipTailscaleInstall -and -not (Test-TailscaleInstalled)

        if ($needsDockerWork -or $needsTailscaleWork) {
            $dockerNeedsFreshInstall = $needsDockerWork -and -not (Test-DockerInstalled)
            $tailscaleNeedsFreshInstall = $needsTailscaleWork

            if (($dockerNeedsFreshInstall -or $tailscaleNeedsFreshInstall) -and -not (Test-IsElevated)) {
                Write-GuiLog 'Relaunching elevated to install what is missing -- approve the Administrator prompt that is about to appear.'
                $relaunchArgs = [System.Collections.Generic.List[string]]::new()
                $relaunchArgs.AddRange([string[]]@('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$($syncHash.ScriptPath)`"", '-ConfigPath', "`"$($syncHash.ConfigPath)`""))
                if ($syncHash.SkipDockerInstall) { $relaunchArgs.Add('-SkipDockerInstall') }
                if ($syncHash.SkipTailscaleInstall) { $relaunchArgs.Add('-SkipTailscaleInstall') }
                $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Verb RunAs -Wait -PassThru
                Write-GuiLog "Elevated instance finished (exit code $($proc.ExitCode)). Closing this window."
                $syncHash.Done = $true
                $syncHash.Window.Invoke([Action]{ $syncHash.Window.Close() }) | Out-Null
                return
            }

            if ($needsDockerWork) {
                if (Test-DockerInstalled) {
                    Write-GuiLog 'Docker is installed but not running -- starting Docker Desktop (this can take a minute on first launch).'
                } else {
                    Write-GuiLog 'Docker not found -- installing Docker Desktop. This can take several minutes on a slow connection.'
                }
                Write-GuiLog 'If a sign-in or setup dialog pops up in the Docker Desktop window, dismiss/skip it -- no Docker Hub account is needed for local use.'
                $dockerInstall = Install-DockerDesktop
                Write-GuiLog "  $($dockerInstall.Detail)"
                if ($dockerInstall.Status -eq 'reboot-required') {
                    Show-GuiError "$($dockerInstall.Detail)`n`nReboot this machine, then start this program again -- it picks up right where it left off."
                    $syncHash.Done = $true
                    return
                }
                if ($dockerInstall.Status -in @('failed', 'needs-elevation')) {
                    Show-GuiError "Could not finish getting Docker running automatically.`n`n$($dockerInstall.Detail)`n`nInstall Docker Desktop manually from https://www.docker.com/products/docker-desktop/ and try again."
                    $syncHash.Done = $true
                    return
                }
            }

            if ($needsTailscaleWork) {
                Write-GuiLog 'Tailscale not found -- installing the Tailscale client. You will still log in yourself once it is installed.'
                $tailscaleInstall = Install-TailscaleClient
                Write-GuiLog "  $($tailscaleInstall.Detail)"
                if ($tailscaleInstall.Status -in @('failed', 'needs-elevation')) {
                    Show-GuiError "Could not install Tailscale automatically.`n`n$($tailscaleInstall.Detail)`n`nInstall it manually from https://tailscale.com/download/windows and try again."
                    $syncHash.Done = $true
                    return
                }
            }
        }

        # --- Step 1: config.
        $config = Get-GuiInstallConfig -Path $syncHash.ConfigPath
        $tierPaths = @{ Fast = $config.fastRoot; Bulk = $config.bulkRoot; TailnetDomain = $config.tailnetDomain }

        # --- Step 2: manifests.
        $manifests = Import-ServiceManifests -Root (Join-Path $syncHash.RepoRoot 'services')
        $allGateRefs = @()
        foreach ($id in $manifests.Keys) { foreach ($g in @($manifests[$id].manualGates)) { $allGateRefs += $g.name } }
        if ($allGateRefs.Count -gt 0) { Test-GateReferencesExist -GateNames $allGateRefs }
        $foundationIds = @($manifests.Values | Where-Object { $_.group -eq 'foundation' } | ForEach-Object { $_.id })

        # --- Step 3/picker.
        $picked = Show-GuiPicker -Manifests $manifests -PreSelected $config.selections
        $whatIf = [bool]$picked.WhatIf
        Write-GuiLog "$(if ($whatIf) { 'Dry run' } else { 'Install' }) starting for: $($picked.SelectedIds -join ', ')"

        # --- Step 4: dependency resolution.
        $initialSelection = @(@($picked.SelectedIds) + $foundationIds | Select-Object -Unique)
        $resolved = Resolve-ServiceSelection -Manifests $manifests -SelectedIds $initialSelection

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
                Write-GuiLog "Added $depNames -- required by $viaName"
            }
        }

        # --- Step 5: pre-flight port collisions.
        $collisions = Get-PortCollisions -Manifests $manifests -SelectedIds $resolved.SelectedIds
        if ($collisions.Count -gt 0) {
            $lines = foreach ($c in $collisions) {
                $names = (@($c.ServiceIds) | ForEach-Object { $manifests[$_].name }) -join ', '
                "Port $($c.Port): $names"
            }
            Show-GuiError "Port collisions detected -- fix these before anything is deployed:`n`n$($lines -join "`n")"
            $syncHash.Done = $true
            return
        }

        # --- Step 6: order.
        $order = Get-InstallOrder -Manifests $manifests -SelectedIds $resolved.SelectedIds

        $config.selections = @($resolved.SelectedIds)
        Save-GuiInstallConfig -Config $config -Path $syncHash.ConfigPath

        if (-not $whatIf) {
            Initialize-GuiHostPaths -Manifests $manifests -SelectedIds $resolved.SelectedIds -TierPaths $tierPaths
        }

        foreach ($id in $order) {
            $m = $manifests[$id]
            Update-GuiStatus -Id $id -Name $m.name -Status 'pending' -Detail ''
        }

        # --- Step 7: deploy loop.
        $caddyDeployed = $false
        $results = [System.Collections.Generic.List[object]]::new()
        $gateResults = [System.Collections.Generic.List[object]]::new()

        foreach ($id in $order) {
            if ($syncHash.CancelRequested) {
                Update-GuiStatus -Id $id -Name $manifests[$id].name -Status 'cancelled' -Detail 'Skipped -- install was cancelled.'
                continue
            }

            $manifest = $manifests[$id]
            Update-GuiStatus -Id $id -Name $manifest.name -Status 'running' -Detail ''
            Write-GuiLog "=== $($manifest.name) ==="

            if ($manifest.deployType -eq 'compose') {
                $preState = Test-ServiceState -Manifest $manifest -TierPaths $tierPaths -CaddyDeployed $caddyDeployed -TailnetDomain $config.tailnetDomain
                if ($preState.Status -eq 'already-valid') {
                    Write-GuiLog "Already valid -- skipping deploy. ($($preState.Detail))"
                    Update-GuiStatus -Id $id -Name $manifest.name -Status 'already-valid' -Detail $preState.Detail
                    $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'already-valid'; Detail = $preState.Detail })
                    if ($id -eq 'caddy') { $caddyDeployed = $true }
                    continue
                }
            }

            $addedBecauseOf = if ($resolved.AddedVia.ContainsKey($id)) { $manifests[$resolved.AddedVia[$id]].name } else { $null }
            $envOverrides = @{}
            $allGatesSatisfied = $true

            foreach ($gateRef in @($manifest.manualGates)) {
                $gateDef = Get-GateDefinition -Name $gateRef.name

                if ($whatIf) {
                    $alreadySatisfied = Test-GateSatisfied -GateState $config.manualGates -Name $gateRef.name
                    Write-GuiLog "  [$($gateRef.name)] would $(if ($alreadySatisfied) { 're-check' } else { 'prompt' }): $($gateDef.Instructions)"
                    $gateResults.Add([pscustomobject]@{ GateName = $gateRef.name; ServiceName = $manifest.name; Instructions = $gateDef.Instructions; Satisfied = $true })
                    continue
                }

                $verifier = Get-GuiGateVerifier -GateName $gateRef.name -Manifest $manifest -TierPaths $tierPaths

                # Same reasoning as install.ps1: tailscale-login is the one
                # gate the program can actually perform, not just describe.
                if ($gateRef.name -eq 'tailscale-login' -and $verifier -and -not (& $verifier)) {
                    Write-GuiLog '  Starting Tailscale login...'
                    Start-TailscaleLogin
                }

                $readInput = { param($prompt) Show-GatePromptDialog -Prompt $prompt -Sensitive $false }.GetNewClosure()
                $readSecure = { param($prompt) ConvertTo-SecureStringFromPlainText (Show-GatePromptDialog -Prompt $prompt -Sensitive $true) }.GetNewClosure()
                $writeOut = { param($text) Write-GuiLog $text }.GetNewClosure()

                $gateResult = Invoke-Gate -Name $gateRef.name -GateState $config.manualGates -AddedBecauseOf $addedBecauseOf `
                    -VerifyScriptBlock $verifier -ReadInput $readInput -ReadSecureInput $readSecure -WriteOutput $writeOut
                $gateResults.Add([pscustomobject]@{ GateName = $gateRef.name; ServiceName = $manifest.name; Instructions = $gateDef.Instructions; Satisfied = $gateResult.Satisfied })

                $hasEnvVar = $gateRef.PSObject.Properties.Match('envVar').Count -gt 0 -and $gateRef.envVar
                if ($gateResult.Satisfied -and $hasEnvVar -and $gateResult.Value) { $envOverrides[$gateRef.envVar] = $gateResult.Value }
                if (-not $gateResult.Satisfied) { $allGatesSatisfied = $false }
                Save-GuiInstallConfig -Config $config -Path $syncHash.ConfigPath
            }

            if ($manifest.deployType -eq 'manual') {
                $status = if ($allGatesSatisfied) { 'installed' } else { 'needs-attention' }
                $detail = if ($allGatesSatisfied) { 'manual setup confirmed' } else { 'manual setup still outstanding' }
                Update-GuiStatus -Id $id -Name $manifest.name -Status $status -Detail $detail
                $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = $status; Detail = $detail })
                continue
            }

            $deployResult = Deploy-Service -Manifest $manifest -TierPaths $tierPaths -EnvOverrides $envOverrides -WhatIf:$whatIf
            Write-GuiLog "  $($deployResult.Action)"

            if ($whatIf) {
                Update-GuiStatus -Id $id -Name $manifest.name -Status 'would-deploy' -Detail $deployResult.Action
                $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'would-deploy'; Detail = $deployResult.Action })
                continue
            }

            if ($deployResult.ExitCode -ne 0) {
                $detail = "deploy failed: $($deployResult.Output -join ' ')"
                Update-GuiStatus -Id $id -Name $manifest.name -Status 'needs-attention' -Detail $detail
                $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'needs-attention'; Detail = $detail })
                continue
            }

            if ($manifest.deployType -eq 'dockerNetwork') {
                Update-GuiStatus -Id $id -Name $manifest.name -Status 'installed' -Detail $deployResult.Action
                $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = 'installed'; Detail = $deployResult.Action })
                continue
            }

            $postState = Test-ServiceState -Manifest $manifest -TierPaths $tierPaths -CaddyDeployed $caddyDeployed -TailnetDomain $config.tailnetDomain
            $finalStatus = if ($postState.Status -eq 'already-valid') { 'installed' } else { 'needs-attention' }
            Update-GuiStatus -Id $id -Name $manifest.name -Status $finalStatus -Detail $postState.Detail
            $results.Add([pscustomobject]@{ Id = $id; Name = $manifest.name; Status = $finalStatus; Detail = $postState.Detail })

            if ($id -eq 'caddy' -and $finalStatus -eq 'installed') { $caddyDeployed = $true }
        }

        Write-GuiLog ''
        Write-GuiLog (Format-InstallReport -Results $results -GateResults $gateResults)
    } catch {
        Write-GuiLog "FATAL: $($_.Exception.Message)"
        Show-GuiError "Something went wrong:`n`n$($_.Exception.Message)"
    } finally {
        $syncHash.Done = $true
    }
}

$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = 'MTA'
$runspace.ThreadOptions = 'ReuseThread'
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('syncHash', $syncHash)

$ps = [powershell]::Create()
$ps.Runspace = $runspace
$ps.AddScript($workerScript.ToString()).AddArgument($syncHash) | Out-Null
$asyncHandle = $ps.BeginInvoke()

[System.Windows.Forms.Application]::Run($form)

$logTimer.Stop()
if ($ps.InvocationStateInfo.State -eq 'Running') { $ps.Stop() }
$ps.Dispose()
$runspace.Close()
