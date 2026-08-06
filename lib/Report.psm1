#Requires -Version 5.1
<#
.SYNOPSIS
    Renders the end-of-run summary table and the deduplicated list of
    outstanding manual steps.

    See docs/superpowers/specs/2026-08-06-installer-wizard-design.md
    ("Wizard flow" step 8) for the design this module implements.

    NOTE: pure ASCII only in this file -- see the note at the top of
    Gate.psm1 for why.
#>

Set-StrictMode -Version Latest

function Format-TableRow {
    param([string[]]$Values, [int[]]$Widths)
    $cells = for ($i = 0; $i -lt $Values.Count; $i++) { $Values[$i].PadRight($Widths[$i]) }
    return ($cells -join '  ')
}

function Format-StatusTable {
    <#
    .SYNOPSIS
        Plain-text, column-aligned table: service | status | detail.
        -Results entries need Name, Status, Detail properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results
    )

    $headers = @('Service', 'Status', 'Detail')
    $rows = @($Results | ForEach-Object { , @([string]$_.Name, [string]$_.Status, [string]$_.Detail) })

    $widths = for ($i = 0; $i -lt $headers.Count; $i++) {
        $colValues = @($headers[$i]) + @($rows | ForEach-Object { $_[$i] })
        ($colValues | Measure-Object -Property Length -Maximum).Maximum
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Format-TableRow -Values $headers -Widths $widths))
    $lines.Add((($widths | ForEach-Object { '-' * $_ }) -join '  '))
    foreach ($row in $rows) { $lines.Add((Format-TableRow -Values $row -Widths $widths)) }
    return ($lines -join "`n")
}

function Get-PendingManualSteps {
    <#
    .SYNOPSIS
        Deduplicates unsatisfied manual gates by gate name and formats each
        as "Service(s): instructions -- not automatable", per the design
        doc's example ("Prowlarr: add indexer accounts -- not automatable").
        -GateResults entries need GateName, ServiceName, Instructions,
        Satisfied properties.
    #>
    [CmdletBinding()]
    param(
        [object[]]$GateResults = @()
    )

    $unsatisfied = @($GateResults | Where-Object { -not $_.Satisfied })
    if ($unsatisfied.Count -eq 0) { return , @() }

    $deduped = foreach ($group in ($unsatisfied | Group-Object GateName)) {
        $first = $group.Group[0]
        $services = ($group.Group | ForEach-Object { $_.ServiceName } | Sort-Object -Unique) -join ', '
        "${services}: $($first.Instructions) -- not automatable"
    }
    return , @($deduped)
}

function Format-InstallReport {
    <#
    .SYNOPSIS
        Combines the status table, a one-line summary count, and the
        outstanding-manual-steps list into the final report text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [object[]]$GateResults = @()
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add((Format-StatusTable -Results $Results))
    $lines.Add('')

    $counts = @($Results | Group-Object Status | Sort-Object Name)
    $summary = ($counts | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    $lines.Add("Summary: $summary")

    $pending = Get-PendingManualSteps -GateResults $GateResults
    if ($pending.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Outstanding manual steps:')
        foreach ($p in $pending) { $lines.Add("  - $p") }
    }

    return ($lines -join "`n")
}

Export-ModuleMember -Function Format-StatusTable, Get-PendingManualSteps, Format-InstallReport
