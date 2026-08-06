#Requires -Version 5.1
<#
.SYNOPSIS
    Loads and validates service manifests, and computes dependency-aware
    selection and install ordering.

    See docs/superpowers/specs/2026-08-06-installer-wizard-design.md
    ("Manifest schema" and "Wizard flow" sections) for the design this
    module implements.
#>

Set-StrictMode -Version Latest

function Test-ManifestSchema {
    <#
    .SYNOPSIS
        Validates one parsed manifest object against the required schema.
        Throws on any violation - manifest errors are configuration bugs,
        not something the wizard should silently work around.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )

    foreach ($field in @('id', 'name', 'group')) {
        $hasField = [bool](Get-Member -InputObject $Manifest -Name $field -MemberType NoteProperty)
        if (-not $hasField -or [string]::IsNullOrWhiteSpace($Manifest.$field)) {
            throw "Manifest '$Path' is missing required field '$field'."
        }
    }

    if ($Manifest.id -notmatch '^[a-z][a-z0-9-]*$') {
        throw "Manifest '$Path' has invalid id '$($Manifest.id)' - must be lowercase, start with a letter, and contain only letters, digits and hyphens."
    }

    $deployType = 'compose'
    if (Get-Member -InputObject $Manifest -Name deployType -MemberType NoteProperty) {
        $deployType = $Manifest.deployType
        if ($deployType -notin @('compose', 'dockerNetwork', 'manual')) {
            throw "Manifest '$Path' has unknown deployType '$deployType' (expected compose, dockerNetwork, or manual)."
        }
    }

    if ($deployType -eq 'compose' -and -not (Get-Member -InputObject $Manifest -Name compose -MemberType NoteProperty)) {
        throw "Manifest '$Path' has deployType 'compose' (the default) but no 'compose' field."
    }

    if (Get-Member -InputObject $Manifest -Name phase -MemberType NoteProperty) {
        if ($Manifest.phase -isnot [int] -and $Manifest.phase -isnot [long]) {
            throw "Manifest '$Path' has non-integer 'phase' value '$($Manifest.phase)'."
        }
    }
}

function Import-ServiceManifests {
    <#
    .SYNOPSIS
        Recursively loads every services/**/<id>.json under -Root, validates
        each against the schema, normalizes optional fields, and returns an
        ordered id -> manifest map.

    .PARAMETER RepoRoot
        When given, each compose-deployed manifest's .compose path (stored
        as a repo-relative string like "compose/foundation/caddy.yml") is
        resolved to an absolute path under this root. Without it, .compose
        stays exactly as written in the JSON.

        This matters because Deploy.psm1 hands that string straight to
        `docker compose -f <path>`, which resolves a relative path against
        the *process's current working directory* -- not against this
        repo. That CWD is not reliably the repo root: an elevated
        self-relaunch (Start-Process -Verb RunAs) commonly starts in the
        user's home directory rather than inheriting the launching
        process's CWD, and -WhatIf mode never surfaces the problem since
        it builds a descriptive string without ever actually invoking
        docker with the path. Resolving once here, at load time, makes
        every consumer correct regardless of how the entry script was
        launched, rather than relying on CWD being right by accident.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$RepoRoot
    )

    if (-not (Test-Path -Path $Root -PathType Container)) {
        throw "Manifest root '$Root' does not exist."
    }

    $files = Get-ChildItem -Path $Root -Filter '*.json' -Recurse -File | Sort-Object FullName
    $manifests = [ordered]@{}

    foreach ($file in $files) {
        $raw = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        try {
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Manifest '$($file.FullName)' is not valid JSON: $($_.Exception.Message)"
        }

        Test-ManifestSchema -Manifest $obj -Path $file.FullName

        # Normalize optional fields so every consumer can rely on their presence.
        if (-not (Get-Member -InputObject $obj -Name dependsOn -MemberType NoteProperty)) {
            $obj | Add-Member -NotePropertyName dependsOn -NotePropertyValue @()
        }
        if (-not (Get-Member -InputObject $obj -Name ports -MemberType NoteProperty)) {
            $obj | Add-Member -NotePropertyName ports -NotePropertyValue @()
        }
        if (-not (Get-Member -InputObject $obj -Name manualGates -MemberType NoteProperty)) {
            $obj | Add-Member -NotePropertyName manualGates -NotePropertyValue @()
        }
        if (-not (Get-Member -InputObject $obj -Name phase -MemberType NoteProperty)) {
            $obj | Add-Member -NotePropertyName phase -NotePropertyValue 0
        }
        if (-not (Get-Member -InputObject $obj -Name deployType -MemberType NoteProperty)) {
            $obj | Add-Member -NotePropertyName deployType -NotePropertyValue 'compose'
        }
        if ($RepoRoot -and $obj.deployType -eq 'compose' -and
            (Get-Member -InputObject $obj -Name compose -MemberType NoteProperty) -and
            -not [System.IO.Path]::IsPathRooted($obj.compose)) {
            $obj.compose = Join-Path $RepoRoot $obj.compose
        }
        $obj | Add-Member -NotePropertyName _sourcePath -NotePropertyValue $file.FullName -Force

        if ($manifests.Contains([string]$obj.id)) {
            throw "Duplicate service id '$($obj.id)' found in '$($file.FullName)' and '$($manifests[[string]$obj.id]._sourcePath)'."
        }
        $manifests[[string]$obj.id] = $obj
    }

    # Second pass: every dependsOn reference must resolve within the loaded set.
    foreach ($id in $manifests.Keys) {
        foreach ($dep in @($manifests[$id].dependsOn)) {
            if (-not $manifests.Contains([string]$dep)) {
                throw "Service '$id' depends on unknown service '$dep' (declared in $($manifests[$id]._sourcePath))."
            }
        }
    }

    return $manifests
}

function Resolve-ServiceSelection {
    <#
    .SYNOPSIS
        Expands a user's checked services to include every transitive
        dependency, and produces human-readable "Added X - required by Y"
        messages plus a dep -> direct-parent map for later gate messaging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifests,
        [Parameter(Mandatory)][string[]]$SelectedIds
    )

    $selected = [System.Collections.Generic.HashSet[string]]::new([string[]]$SelectedIds)
    $additions = [System.Collections.Generic.List[psobject]]::new()
    $addedVia = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new([string[]]$SelectedIds)

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $Manifests.Contains($current)) {
            throw "Selected service '$current' has no manifest."
        }
        foreach ($dep in @($Manifests[$current].dependsOn)) {
            $dep = [string]$dep
            if (-not $selected.Contains($dep)) {
                [void]$selected.Add($dep)
                $additions.Add([pscustomobject]@{ Dep = $dep; Via = $current })
                if (-not $addedVia.ContainsKey($dep)) { $addedVia[$dep] = $current }
                $queue.Enqueue($dep)
            }
        }
    }

    $messages = [System.Collections.Generic.List[string]]::new()
    foreach ($group in ($additions | Group-Object Via)) {
        $depNames = @($group.Group | ForEach-Object { $Manifests[$_.Dep].name })
        $viaName = $Manifests[$group.Name].name
        $joined = if ($depNames.Count -eq 1) {
            $depNames[0]
        } else {
            ($depNames[0..($depNames.Count - 2)] -join ', ') + ' and ' + $depNames[-1]
        }
        $messages.Add("Added $joined - required by $viaName")
    }

    [pscustomobject]@{
        SelectedIds = @($selected)
        Messages    = @($messages)
        AddedVia    = $addedVia
    }
}

function Get-PortCollisions {
    <#
    .SYNOPSIS
        Returns one entry per host port claimed by more than one selected
        service. Empty result means the pre-flight port check passes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifests,
        [Parameter(Mandatory)][string[]]$SelectedIds
    )

    $portMap = @{}
    foreach ($id in $SelectedIds) {
        foreach ($port in @($Manifests[$id].ports)) {
            $key = [string]$port
            if (-not $portMap.ContainsKey($key)) { $portMap[$key] = [System.Collections.Generic.List[string]]::new() }
            $portMap[$key].Add($id)
        }
    }

    $collisions = foreach ($key in $portMap.Keys) {
        if ($portMap[$key].Count -gt 1) {
            [pscustomobject]@{ Port = [int]$key; ServiceIds = @($portMap[$key] | Sort-Object) }
        }
    }
    return , @($collisions | Sort-Object Port)
}

function Get-TopologicalOrder {
    <#
    .SYNOPSIS
        Kahn's-algorithm topological sort of -Ids using dependsOn edges,
        restricted to edges where both ends are in -Ids (cross-phase edges
        are validated separately by Get-InstallOrder). Deterministic: input
        ids are sorted alphabetically before sorting so the result doesn't
        depend on selection order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifests,
        [Parameter(Mandatory)][string[]]$Ids
    )

    $sortedIds = @($Ids | Sort-Object)
    $idSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$sortedIds)
    $inDegree = @{}
    $dependents = @{}
    foreach ($id in $sortedIds) {
        $inDegree[$id] = 0
        $dependents[$id] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($id in $sortedIds) {
        foreach ($dep in @($Manifests[$id].dependsOn)) {
            $dep = [string]$dep
            if ($idSet.Contains($dep)) {
                $dependents[$dep].Add($id)
                $inDegree[$id]++
            }
        }
    }

    $ready = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $sortedIds) { if ($inDegree[$id] -eq 0) { $ready.Add($id) } }

    $result = [System.Collections.Generic.List[string]]::new()
    while ($ready.Count -gt 0) {
        $next = $ready[0]
        $ready.RemoveAt(0)
        $result.Add($next)
        foreach ($dependent in $dependents[$next]) {
            $inDegree[$dependent]--
            if ($inDegree[$dependent] -eq 0) { $ready.Add($dependent) }
        }
    }

    if ($result.Count -ne $sortedIds.Count) {
        $remaining = @($sortedIds | Where-Object { -not $result.Contains($_) })
        throw "Manifest error: dependency cycle detected among same-phase services: $($remaining -join ', ')."
    }

    return , @($result)
}

function Get-InstallOrder {
    <#
    .SYNOPSIS
        Computes the deploy order for -SelectedIds: primary sort key is
        phase (ascending), topological sort on dependsOn as a tiebreak
        within each phase. Throws if a dependency's phase is later than its
        dependent's - that is a manifest authoring error, not something the
        wizard resolves silently.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifests,
        [Parameter(Mandatory)][string[]]$SelectedIds
    )

    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$SelectedIds)

    foreach ($id in $SelectedIds) {
        $m = $Manifests[$id]
        foreach ($dep in @($m.dependsOn)) {
            $dep = [string]$dep
            if (-not $selectedSet.Contains($dep)) { continue } # satisfied outside this run
            $depPhase = [int]$Manifests[$dep].phase
            if ($depPhase -gt [int]$m.phase) {
                throw "Manifest error: '$id' (phase $($m.phase)) depends on '$dep' (phase $depPhase), which installs later. Fix the phase numbers in the manifests."
            }
        }
    }

    $byPhase = $SelectedIds | Group-Object { [int]$Manifests[$_].phase } | Sort-Object { [int]$_.Name }

    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($phaseGroup in $byPhase) {
        $orderedPhase = Get-TopologicalOrder -Manifests $Manifests -Ids @($phaseGroup.Group)
        foreach ($id in $orderedPhase) { $ordered.Add($id) }
    }
    return , @($ordered)
}

Export-ModuleMember -Function Test-ManifestSchema, Import-ServiceManifests, Resolve-ServiceSelection, Get-PortCollisions, Get-TopologicalOrder, Get-InstallOrder
