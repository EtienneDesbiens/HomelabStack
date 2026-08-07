#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for lib/Gate.psm1: Input vs Acknowledgment re-trigger
    semantics, per the design doc's "Manual-gate mechanics" section.

    NOTE: closures below capture a hashtable "box" (a reference type)
    rather than a $script: variable -- see the note at the top of
    Deploy.Tests.ps1 for why.

    NOTE: pure ASCII only -- see the note at the top of lib/Gate.psm1.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'lib\Gate.psm1') -Force

Describe 'Invoke-Gate -Instructions override' {

    It 'uses the override text instead of the gate table default when given' {
        $state = @{}
        $box = @{ written = $null }
        Invoke-Gate -Name 'router-dns' -GateState $state `
            -Instructions 'Open AdGuard Home at http://localhost:3000 and note its IP.' `
            -ReadInput { param($p) '' } `
            -WriteOutput { param($t) if ($t -match '\[router-dns\]') { $box.written = $t } }.GetNewClosure() | Out-Null
        $box.written | Should Match 'http://localhost:3000'
    }

    It 'falls back to the gate table default when no override is given' {
        $state = @{}
        $box = @{ written = $null }
        Invoke-Gate -Name 'router-dns' -GateState $state `
            -ReadInput { param($p) '' } `
            -WriteOutput { param($t) if ($t -match '\[router-dns\]') { $box.written = $t } }.GetNewClosure() | Out-Null
        $box.written | Should Match "AdGuard Home's address"
    }
}

Describe 'Invoke-Gate input gates' {

    It 'prompts and records a value on first invocation' {
        $state = @{}
        $box = @{ prompted = $false }
        $r = Invoke-Gate -Name 'plex-claim' -GateState $state `
            -ReadInput { param($p) $box.prompted = $true; 'my-token' }.GetNewClosure() `
            -WriteOutput { param($t) }
        $box.prompted | Should Be $true
        $r.Satisfied | Should Be $true
        $r.Value | Should Be 'my-token'
        (Test-GateSatisfied -GateState $state -Name 'plex-claim') | Should Be $true
    }

    It 'never re-prompts once satisfied' {
        $state = @{}
        Set-GateSatisfied -GateState $state -Name 'plex-claim'
        $box = @{ prompted = $false }
        $r = Invoke-Gate -Name 'plex-claim' -GateState $state `
            -ReadInput { param($p) $box.prompted = $true; 'should-not-be-used' }.GetNewClosure() `
            -WriteOutput { param($t) }
        $box.prompted | Should Be $false
        $r.Satisfied | Should Be $true
        $r.Reason | Should Be 'already-satisfied'
    }
}

Describe 'Invoke-Gate acknowledgment gates -- not reverifiable' {

    It 'trusts a prior acknowledgment forever, never re-checking' {
        $state = @{}
        Set-GateSatisfied -GateState $state -Name 'router-dns'
        $box = @{ prompted = $false }
        $r = Invoke-Gate -Name 'router-dns' -GateState $state `
            -ReadInput { param($p) $box.prompted = $true; '' }.GetNewClosure() `
            -WriteOutput { param($t) }
        $box.prompted | Should Be $false
        $r.Reason | Should Be 'trusted-acknowledgment'
    }
}

Describe 'Invoke-Gate acknowledgment gates -- reverifiable' {

    It 'skips re-prompting when the live check still passes' {
        $state = @{}
        Set-GateSatisfied -GateState $state -Name 'tailscale-login'
        $box = @{ prompted = $false }
        $r = Invoke-Gate -Name 'tailscale-login' -GateState $state `
            -VerifyScriptBlock { $true } `
            -ReadInput { param($p) $box.prompted = $true; '' }.GetNewClosure() `
            -WriteOutput { param($t) }
        $box.prompted | Should Be $false
        $r.Reason | Should Be 'reverified'
    }

    It 'reprompts when a prior acknowledgment now fails its live check' {
        $state = @{}
        Set-GateSatisfied -GateState $state -Name 'tailscale-login'
        $box = @{ prompted = $false }
        $r = Invoke-Gate -Name 'tailscale-login' -GateState $state `
            -VerifyScriptBlock { $false } `
            -ReadInput { param($p) $box.prompted = $true; '' }.GetNewClosure() `
            -WriteOutput { param($t) } `
            -MaxVerifyAttempts 1
        $box.prompted | Should Be $true
        $r.Satisfied | Should Be $false
        $r.Reason | Should Be 'verification-failed'
    }

    It 'gives up and reports unsatisfied after MaxVerifyAttempts failures' {
        $state = @{}
        $r = Invoke-Gate -Name 'indexer-keys' -GateState $state `
            -VerifyScriptBlock { $false } `
            -ReadInput { param($p) '' } `
            -WriteOutput { param($t) } `
            -MaxVerifyAttempts 2
        $r.Satisfied | Should Be $false
        $r.Reason | Should Be 'verification-failed'
        (Test-GateSatisfied -GateState $state -Name 'indexer-keys') | Should Be $false
    }

    It 'succeeds once the live check passes after a retry' {
        $state = @{}
        $box = @{ attempt = 0 }
        $r = Invoke-Gate -Name 'indexer-keys' -GateState $state `
            -VerifyScriptBlock { $box.attempt++; $box.attempt -ge 2 }.GetNewClosure() `
            -ReadInput { param($p) '' } `
            -WriteOutput { param($t) } `
            -MaxVerifyAttempts 5
        $r.Satisfied | Should Be $true
        $box.attempt | Should Be 2
    }
}

Describe 'Test-GateReferencesExist' {

    It 'passes for known gate names' {
        { Test-GateReferencesExist -GateNames @('plex-claim', 'tailscale-login') } | Should Not Throw
    }

    It 'throws listing unknown gate names' {
        { Test-GateReferencesExist -GateNames @('plex-claim', 'made-up-gate') } | Should Throw 'made-up-gate'
    }
}
