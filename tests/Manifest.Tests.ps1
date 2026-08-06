#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for lib/Manifest.psm1: dependency resolution, phase +
    topological ordering, port-collision detection, manifest schema
    validation. Pure logic, no Docker required -- per the design doc's
    "Testing approach" section.

    Written against Pester 3.4 syntax (no dash on Should operators) since
    that is what ships in Windows PowerShell 5.1 without any extra install.

    NOTE: pure ASCII only -- see the note at the top of lib/Gate.psm1.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'lib\Manifest.psm1') -Force

function New-Fixture {
    <#
    .SYNOPSIS
        Writes one manifest JSON file under $TestDrive\services\<group>\<id>.json.
    #>
    param(
        [string]$Id,
        [string]$Group = 'test',
        [int]$Phase = 0,
        [string[]]$DependsOn = @(),
        [int[]]$Ports = @(),
        [string]$Compose
    )
    $dir = Join-Path $TestDrive "services\$Group"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $obj = [ordered]@{
        id     = $Id
        name   = $Id
        group  = $Group
        phase  = $Phase
        compose = if ($Compose) { $Compose } else { "compose/$Group/$Id.yml" }
    }
    if ($DependsOn.Count -gt 0) { $obj.dependsOn = $DependsOn }
    if ($Ports.Count -gt 0) { $obj.ports = $Ports }

    ($obj | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $dir "$Id.json") -Encoding UTF8
}

Describe 'Import-ServiceManifests' {

    It 'loads a valid manifest and normalizes optional fields' {
        New-Fixture -Id 'caddy' -Group 'foundation' -Phase 0
        $m = Import-ServiceManifests -Root (Join-Path $TestDrive 'services')
        $m.Contains('caddy') | Should Be $true
        @($m['caddy'].dependsOn).Count | Should Be 0
        $m['caddy'].deployType | Should Be 'compose'
    }

    It 'leaves compose paths relative when -RepoRoot is not given' {
        New-Fixture -Id 'caddy' -Group 'foundation' -Phase 0
        $m = Import-ServiceManifests -Root (Join-Path $TestDrive 'services')
        $m['caddy'].compose | Should Be 'compose/foundation/caddy.yml'
    }

    It 'resolves compose paths to absolute under -RepoRoot' {
        # Regression test: Deploy.psm1 hands manifest.compose straight to
        # `docker compose -f <path>`, which resolves a relative path
        # against the *process's* current working directory, not the
        # repo. An elevated self-relaunch (Start-Process -Verb RunAs)
        # doesn't reliably inherit CWD -- it commonly starts in the user's
        # home directory instead -- which broke every compose deploy with
        # "the system cannot find the path" until -RepoRoot was added.
        New-Fixture -Id 'caddy' -Group 'foundation' -Phase 0
        $repoRoot = 'C:\some\repo\root'
        $m = Import-ServiceManifests -Root (Join-Path $TestDrive 'services') -RepoRoot $repoRoot
        $m['caddy'].compose | Should Be (Join-Path $repoRoot 'compose/foundation/caddy.yml')
        [System.IO.Path]::IsPathRooted($m['caddy'].compose) | Should Be $true
    }

    It 'does not touch compose paths for non-compose deployTypes even with -RepoRoot' {
        $dir = Join-Path $TestDrive 'noncompose'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{"id":"docker-network","name":"Docker Network","group":"foundation","deployType":"dockerNetwork"}' | Set-Content (Join-Path $dir 'docker-network.json')
        $m = Import-ServiceManifests -Root $dir -RepoRoot 'C:\some\repo\root'
        (Get-Member -InputObject $m['docker-network'] -Name compose -MemberType NoteProperty) | Should Be $null
    }

    It 'throws on duplicate service id' {
        $dir1 = Join-Path $TestDrive 'dup\a'
        $dir2 = Join-Path $TestDrive 'dup\b'
        New-Item -ItemType Directory -Path $dir1 -Force | Out-Null
        New-Item -ItemType Directory -Path $dir2 -Force | Out-Null
        '{"id":"dupe","name":"Dupe","group":"a","compose":"x.yml"}' | Set-Content (Join-Path $dir1 'dupe.json')
        '{"id":"dupe","name":"Dupe","group":"b","compose":"y.yml"}' | Set-Content (Join-Path $dir2 'dupe.json')
        { Import-ServiceManifests -Root (Join-Path $TestDrive 'dup') } | Should Throw 'Duplicate service id'
    }

    It 'throws when dependsOn references an unknown service' {
        $dir = Join-Path $TestDrive 'baddep'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{"id":"sonarr","name":"Sonarr","group":"media","compose":"x.yml","dependsOn":["nonexistent"]}' | Set-Content (Join-Path $dir 'sonarr.json')
        { Import-ServiceManifests -Root $dir } | Should Throw 'unknown service'
    }

    It 'throws on invalid JSON' {
        $dir = Join-Path $TestDrive 'badjson'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        'not valid json {{{' | Set-Content (Join-Path $dir 'broken.json')
        { Import-ServiceManifests -Root $dir } | Should Throw 'not valid JSON'
    }
}

Describe 'Test-ManifestSchema' {

    It 'throws when a required field is missing' {
        $obj = [pscustomobject]@{ id = 'x'; group = 'y' }  # missing name
        { Test-ManifestSchema -Manifest $obj -Path 'fake.json' } | Should Throw "missing required field 'name'"
    }

    It 'throws on an invalid id format' {
        $obj = [pscustomobject]@{ id = 'Bad_ID!'; name = 'X'; group = 'y'; compose = 'x.yml' }
        { Test-ManifestSchema -Manifest $obj -Path 'fake.json' } | Should Throw 'invalid id'
    }

    It 'throws when deployType compose has no compose field' {
        $obj = [pscustomobject]@{ id = 'x'; name = 'X'; group = 'y' }
        { Test-ManifestSchema -Manifest $obj -Path 'fake.json' } | Should Throw "no 'compose' field"
    }

    It 'allows deployType manual with no compose field' {
        $obj = [pscustomobject]@{ id = 'x'; name = 'X'; group = 'y'; deployType = 'manual' }
        { Test-ManifestSchema -Manifest $obj -Path 'fake.json' } | Should Not Throw
    }
}

Describe 'Resolve-ServiceSelection' {

    BeforeEach {
        $script:manifests = [ordered]@{
            deluge   = [pscustomobject]@{ id = 'deluge'; name = 'Deluge'; dependsOn = @() }
            prowlarr = [pscustomobject]@{ id = 'prowlarr'; name = 'Prowlarr'; dependsOn = @() }
            sonarr   = [pscustomobject]@{ id = 'sonarr'; name = 'Sonarr'; dependsOn = @('deluge', 'prowlarr') }
            bazarr   = [pscustomobject]@{ id = 'bazarr'; name = 'Bazarr'; dependsOn = @('sonarr') }
        }
    }

    It 'expands transitive dependencies' {
        $sel = Resolve-ServiceSelection -Manifests $manifests -SelectedIds @('bazarr')
        ($sel.SelectedIds | Sort-Object) | Should Be @('bazarr', 'deluge', 'prowlarr', 'sonarr')
    }

    It 'produces a combined message naming the pulling service' {
        $sel = Resolve-ServiceSelection -Manifests $manifests -SelectedIds @('sonarr')
        $sel.Messages | Should Be @('Added Deluge and Prowlarr - required by Sonarr')
    }

    It 'does not re-add an already-selected dependency or duplicate messages' {
        $sel = Resolve-ServiceSelection -Manifests $manifests -SelectedIds @('sonarr', 'deluge')
        ($sel.SelectedIds | Sort-Object) | Should Be @('deluge', 'prowlarr', 'sonarr')
        $sel.Messages.Count | Should Be 1
    }

    It 'records the direct parent that pulled in each dependency' {
        $sel = Resolve-ServiceSelection -Manifests $manifests -SelectedIds @('bazarr')
        $sel.AddedVia['sonarr'] | Should Be 'bazarr'
        $sel.AddedVia['deluge'] | Should Be 'sonarr'
    }
}

Describe 'Get-PortCollisions' {

    It 'reports no collisions when ports do not overlap' {
        $manifests = [ordered]@{
            a = [pscustomobject]@{ id = 'a'; ports = @(80) }
            b = [pscustomobject]@{ id = 'b'; ports = @(443) }
        }
        $collisions = Get-PortCollisions -Manifests $manifests -SelectedIds @('a', 'b')
        $collisions.Count | Should Be 0
    }

    It 'reports a single collision naming both services' {
        $manifests = [ordered]@{
            a = [pscustomobject]@{ id = 'a'; ports = @(9000) }
            b = [pscustomobject]@{ id = 'b'; ports = @(9000) }
        }
        $collisions = Get-PortCollisions -Manifests $manifests -SelectedIds @('a', 'b')
        $collisions.Count | Should Be 1
        $collisions[0].Port | Should Be 9000
        ($collisions[0].ServiceIds | Sort-Object) | Should Be @('a', 'b')
    }
}

Describe 'Get-InstallOrder' {

    It 'orders strictly by phase first' {
        $manifests = [ordered]@{
            late  = [pscustomobject]@{ id = 'late'; phase = 3; dependsOn = @() }
            early = [pscustomobject]@{ id = 'early'; phase = 0; dependsOn = @() }
            mid   = [pscustomobject]@{ id = 'mid'; phase = 1; dependsOn = @() }
        }
        $order = Get-InstallOrder -Manifests $manifests -SelectedIds @('late', 'early', 'mid')
        $order | Should Be @('early', 'mid', 'late')
    }

    It 'topologically sorts dependencies within the same phase' {
        $manifests = [ordered]@{
            sonarr   = [pscustomobject]@{ id = 'sonarr'; phase = 2; dependsOn = @('deluge', 'prowlarr') }
            deluge   = [pscustomobject]@{ id = 'deluge'; phase = 2; dependsOn = @() }
            prowlarr = [pscustomobject]@{ id = 'prowlarr'; phase = 2; dependsOn = @() }
        }
        $order = Get-InstallOrder -Manifests $manifests -SelectedIds @('sonarr', 'deluge', 'prowlarr')
        ($order.IndexOf('deluge')) | Should BeLessThan ($order.IndexOf('sonarr'))
        ($order.IndexOf('prowlarr')) | Should BeLessThan ($order.IndexOf('sonarr'))
    }

    It 'returns a single-element array intact for a single selected service' {
        $manifests = [ordered]@{ solo = [pscustomobject]@{ id = 'solo'; phase = 0; dependsOn = @() } }
        $order = Get-InstallOrder -Manifests $manifests -SelectedIds @('solo')
        , $order | Should Be @('solo')
        $order.Count | Should Be 1
    }

    It 'throws when a dependency is in a later phase than its dependent' {
        $manifests = [ordered]@{
            early = [pscustomobject]@{ id = 'early'; phase = 0; dependsOn = @('late') }
            late  = [pscustomobject]@{ id = 'late'; phase = 1; dependsOn = @() }
        }
        { Get-InstallOrder -Manifests $manifests -SelectedIds @('early', 'late') } | Should Throw 'installs later'
    }
}

Describe 'Get-TopologicalOrder' {

    It 'throws on a same-phase dependency cycle' {
        $manifests = [ordered]@{
            a = [pscustomobject]@{ id = 'a'; dependsOn = @('b') }
            b = [pscustomobject]@{ id = 'b'; dependsOn = @('a') }
        }
        { Get-TopologicalOrder -Manifests $manifests -Ids @('a', 'b') } | Should Throw 'cycle'
    }

    It 'is deterministic regardless of input order' {
        $manifests = [ordered]@{
            a = [pscustomobject]@{ id = 'a'; dependsOn = @() }
            b = [pscustomobject]@{ id = 'b'; dependsOn = @() }
            c = [pscustomobject]@{ id = 'c'; dependsOn = @() }
        }
        $order1 = Get-TopologicalOrder -Manifests $manifests -Ids @('c', 'a', 'b')
        $order2 = Get-TopologicalOrder -Manifests $manifests -Ids @('a', 'b', 'c')
        $order1 | Should Be $order2
    }
}
