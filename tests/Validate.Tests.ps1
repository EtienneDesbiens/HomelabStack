#Requires -Version 5.1
<#
.SYNOPSIS
    Pester tests for lib/Validate.psm1. Currently covers Get-ServiceUrls
    only -- the rest of this module was verified via extensive manual
    smoke testing during initial development but never got a formal
    Pester file; this is a starting point, not full coverage.

    NOTE: pure ASCII only -- see the note at the top of lib/Gate.psm1.
#>

$moduleRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $moduleRoot 'lib\Validate.psm1') -Force

Describe 'Get-ServiceUrls' {

    $manifest = [pscustomobject]@{
        id       = 'prowlarr'
        validate = [pscustomobject]@{
            httpCheck = [pscustomobject]@{
                direct  = [pscustomobject]@{ url = 'http://localhost:9696/ping'; expectStatus = 200 }
                proxied = [pscustomobject]@{ hostTemplate = 'prowlarr.{tailnetDomain}'; expectStatus = 200 }
            }
        }
    }

    It 'extracts the direct base URL, stripping the endpoint path' {
        $urls = Get-ServiceUrls -Manifest $manifest
        $urls.Direct | Should Be 'http://localhost:9696'
    }

    It 'leaves Proxied null when Caddy is not deployed' {
        $urls = Get-ServiceUrls -Manifest $manifest -CaddyDeployed $false -TailnetDomain 'my-tailnet.ts.net'
        $urls.Proxied | Should Be $null
    }

    It 'leaves Proxied null when no tailnet domain is configured, even if Caddy is deployed' {
        $urls = Get-ServiceUrls -Manifest $manifest -CaddyDeployed $true -TailnetDomain ''
        $urls.Proxied | Should Be $null
    }

    It 'resolves the proxied URL once Caddy is deployed and a tailnet domain is set' {
        $urls = Get-ServiceUrls -Manifest $manifest -CaddyDeployed $true -TailnetDomain 'my-tailnet.ts.net'
        $urls.Proxied | Should Be 'https://prowlarr.my-tailnet.ts.net'
    }

    It 'returns null for both when the manifest has no httpCheck at all' {
        $noHttpManifest = [pscustomobject]@{ id = 'tailscale' }
        $urls = Get-ServiceUrls -Manifest $noHttpManifest -CaddyDeployed $true -TailnetDomain 'my-tailnet.ts.net'
        $urls.Direct | Should Be $null
        $urls.Proxied | Should Be $null
    }

    It 'returns null Direct when httpCheck has no direct entry' {
        $proxiedOnlyManifest = [pscustomobject]@{
            id       = 'x'
            validate = [pscustomobject]@{
                httpCheck = [pscustomobject]@{
                    proxied = [pscustomobject]@{ hostTemplate = 'x.{tailnetDomain}'; expectStatus = 200 }
                }
            }
        }
        $urls = Get-ServiceUrls -Manifest $proxiedOnlyManifest
        $urls.Direct | Should Be $null
    }
}
