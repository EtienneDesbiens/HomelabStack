#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a service's validation checks (container health, HTTP reachability,
    config wiring, volume paths) and returns a pass/fail/not-yet-valid
    verdict with detail. Used both as the "is this already valid, skip
    deploying it" pre-check and the post-deploy re-check -- same function,
    same checks, per the design doc's "Idempotency" section.

    See docs/superpowers/specs/2026-08-06-installer-wizard-design.md
    ("Validation checks", "Manifest schema") for the design this module
    implements.

    NOTE: pure ASCII only in this file -- see the note at the top of
    Gate.psm1 for why.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Injectable I/O: every external touchpoint (Docker, HTTP, filesystem) goes
# through one of these so Pester can substitute a mock and this module never
# needs a real Docker daemon, real network, or real files to be unit tested.
# ---------------------------------------------------------------------------

$script:DockerRunner = {
    param([string[]]$Arguments, [hashtable]$EnvVars = @{})
    $output = & docker @Arguments 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output | ForEach-Object { "$_" }) }
}

function Get-ValidateDockerRunner { $script:DockerRunner }
function Set-ValidateDockerRunner {
    param([Parameter(Mandatory)][scriptblock]$Runner)
    $script:DockerRunner = $Runner
}

$script:HttpChecker = {
    param([string]$Method = 'GET', [string]$Url, [hashtable]$Headers = @{}, [int]$TimeoutSec = 5)
    try {
        $resp = Invoke-WebRequest -Method $Method -Uri $Url -Headers $Headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        $parsed = $resp.Content
        try { $parsed = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { }
        [pscustomobject]@{ Success = $true; StatusCode = [int]$resp.StatusCode; Content = $parsed; Detail = $null }
    } catch {
        $statusCode = $null
        if ($_.Exception.PSObject.Properties.Match('Response').Count -gt 0 -and $_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        }
        [pscustomobject]@{ Success = $false; StatusCode = $statusCode; Content = $null; Detail = $_.Exception.Message }
    }
}

function Get-HttpChecker { $script:HttpChecker }
function Set-HttpChecker {
    param([Parameter(Mandatory)][scriptblock]$Checker)
    $script:HttpChecker = $Checker
}

$script:FileTester = { param([string]$Path) Test-Path -Path $Path -PathType Leaf }
function Get-FileTester { $script:FileTester }
function Set-FileTester {
    param([Parameter(Mandatory)][scriptblock]$Tester)
    $script:FileTester = $Tester
}

$script:FileContentReader = { param([string]$Path) Get-Content -Path $Path -Raw }
function Get-FileContentReader { $script:FileContentReader }
function Set-FileContentReader {
    param([Parameter(Mandatory)][scriptblock]$Reader)
    $script:FileContentReader = $Reader
}

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

function Resolve-ManifestPath {
    <#
    .SYNOPSIS
        Substitutes the <fast>/<bulk> placeholders used throughout manifests
        with the actual tier root paths from config.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$TierPaths
    )
    $root = $null
    $rest = $Path
    if ($Path.StartsWith('<fast>')) { $root = $TierPaths.Fast; $rest = $Path.Substring(6) }
    elseif ($Path.StartsWith('<bulk>')) { $root = $TierPaths.Bulk; $rest = $Path.Substring(6) }

    if (-not $root) {
        return ($Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    }

    $rest = $rest.TrimStart('/', '\') -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $rootTrimmed = $root.TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($rest)) { return $rootTrimmed }
    # Plain string join, not Join-Path -- Join-Path validates the drive exists via
    # the filesystem provider, which fails in tests/dry-run on a machine that
    # doesn't have the target's drive letters.
    return "$rootTrimmed$([System.IO.Path]::DirectorySeparatorChar)$rest"
}

# ---------------------------------------------------------------------------
# Container health
# ---------------------------------------------------------------------------

function Test-ContainerHealth {
    <#
    .SYNOPSIS
        docker inspect on -ContainerName: not-installed if absent, running
        if healthy, restart-looping / stopped otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [scriptblock]$DockerRunner
    )
    if (-not $DockerRunner) { $DockerRunner = Get-ValidateDockerRunner }

    $result = & $DockerRunner -Arguments @('inspect', $ContainerName, '--format', '{{json .State}}') -EnvVars @{}
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Status = 'not-installed'; Detail = "container '$ContainerName' not found" }
    }

    try {
        $state = ($result.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Detail = "could not parse docker inspect output for '$ContainerName'" }
    }

    if ($null -eq $state -or $state -isnot [System.Management.Automation.PSCustomObject] -or
        $state.PSObject.Properties.Match('Running').Count -eq 0) {
        return [pscustomobject]@{ Status = 'fail'; Detail = "unexpected docker inspect output for '$ContainerName'" }
    }

    if (-not $state.Running) {
        $statusText = if ($state.PSObject.Properties.Match('Status').Count -gt 0) { $state.Status } else { 'unknown' }
        return [pscustomobject]@{ Status = 'fail'; Detail = "container '$ContainerName' exists but is not running (status: $statusText)" }
    }
    if ($state.PSObject.Properties.Match('RestartCount').Count -gt 0 -and [int]$state.RestartCount -ge 5) {
        return [pscustomobject]@{ Status = 'fail'; Detail = "container '$ContainerName' is restart-looping ($($state.RestartCount) restarts)" }
    }

    return [pscustomobject]@{ Status = 'pass'; Detail = "container '$ContainerName' running" }
}

# ---------------------------------------------------------------------------
# HTTP reachability
# ---------------------------------------------------------------------------

function Test-HttpReachability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$ExpectStatus = 200,
        [scriptblock]$HttpChecker
    )
    if (-not $HttpChecker) { $HttpChecker = Get-HttpChecker }
    $resp = & $HttpChecker -Method 'GET' -Url $Url
    if ($resp.Success -and $resp.StatusCode -eq $ExpectStatus) {
        return [pscustomobject]@{ Status = 'pass'; Detail = "$Url returned $($resp.StatusCode)" }
    }
    if ($resp.Success) {
        return [pscustomobject]@{ Status = 'fail'; Detail = "$Url returned $($resp.StatusCode), expected $ExpectStatus" }
    }
    return [pscustomobject]@{ Status = 'fail'; Detail = "$Url unreachable: $($resp.Detail)" }
}

# ---------------------------------------------------------------------------
# API key resolution (needed by config-wiring checks)
# ---------------------------------------------------------------------------

function Resolve-ApiKey {
    <#
    .SYNOPSIS
        Resolves apiKeySource (type 'fileRead' or 'none') into an API key.
        'fileRead' supports an XML config (apiKeySource.xpath, e.g. Sonarr/
        Radarr/Prowlarr/Bazarr's config.xml) or a JSON config
        (apiKeySource.jsonPath, a dotted property path). A config file that
        doesn't exist yet is reported as not-yet-valid, not a failure --
        the service may have just been deployed and not written it yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][hashtable]$TierPaths,
        [scriptblock]$FileTester,
        [scriptblock]$FileContentReader
    )
    if (-not $FileTester) { $FileTester = Get-FileTester }
    if (-not $FileContentReader) { $FileContentReader = Get-FileContentReader }

    $src = $Manifest.apiKeySource
    if (-not $src -or $src.type -eq 'none') {
        return [pscustomobject]@{ Status = 'not-applicable'; Key = $null; Detail = 'no API key required' }
    }

    if ($src.type -ne 'fileRead') {
        throw "Unknown apiKeySource.type '$($src.type)' on manifest for '$($Manifest.id)'."
    }

    $path = Resolve-ManifestPath -Path $src.path -TierPaths $TierPaths
    if (-not (& $FileTester $path)) {
        return [pscustomobject]@{ Status = 'not-yet-valid'; Key = $null; Detail = "config file not found yet at $path" }
    }

    $content = & $FileContentReader $path

    if ($src.PSObject.Properties.Match('xpath').Count -gt 0) {
        try {
            [xml]$xmlDoc = $content
            $node = $xmlDoc.SelectSingleNode($src.xpath)
        } catch {
            return [pscustomobject]@{ Status = 'fail'; Key = $null; Detail = "could not parse $path as XML: $($_.Exception.Message)" }
        }
        if (-not $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
            return [pscustomobject]@{ Status = 'not-yet-valid'; Key = $null; Detail = "$($src.xpath) not present yet in $path" }
        }
        return [pscustomobject]@{ Status = 'pass'; Key = $node.InnerText; Detail = "API key read from $path" }
    }

    if ($src.PSObject.Properties.Match('jsonPath').Count -gt 0) {
        try {
            $obj = $content | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Status = 'fail'; Key = $null; Detail = "could not parse $path as JSON: $($_.Exception.Message)" }
        }
        $cursor = $obj
        foreach ($segment in ($src.jsonPath -split '\.')) {
            if ($null -eq $cursor -or -not ($cursor.PSObject.Properties.Match($segment).Count -gt 0)) {
                return [pscustomobject]@{ Status = 'not-yet-valid'; Key = $null; Detail = "$($src.jsonPath) not present yet in $path" }
            }
            $cursor = $cursor.$segment
        }
        if ([string]::IsNullOrWhiteSpace([string]$cursor)) {
            return [pscustomobject]@{ Status = 'not-yet-valid'; Key = $null; Detail = "$($src.jsonPath) empty in $path" }
        }
        return [pscustomobject]@{ Status = 'pass'; Key = [string]$cursor; Detail = "API key read from $path" }
    }

    throw "apiKeySource on manifest for '$($Manifest.id)' has type 'fileRead' but neither 'xpath' nor 'jsonPath'."
}

# ---------------------------------------------------------------------------
# Config-wiring checks -- one small function per check 'type', keyed in a
# dispatch table. Adding a new check kind means adding one entry here, not
# changing the manifest schema (per the design doc).
# ---------------------------------------------------------------------------

$script:ConfigCheckHandlers = @{
    sonarrDownloadClient = {
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v3/downloadclient" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query $HttpBaseUrl/api/v3/downloadclient : $($resp.Detail)" } }
        $match = @($resp.Content | Where-Object { $_.implementation -eq $Check.expects -or $_.name -eq $Check.expects })
        if ($match.Count -gt 0) { return [pscustomobject]@{ Status = 'pass'; Detail = "download client '$($Check.expects)' configured" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = "no download client matching '$($Check.expects)' found" }
    }
    radarrDownloadClient = {
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v3/downloadclient" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query $HttpBaseUrl/api/v3/downloadclient : $($resp.Detail)" } }
        $match = @($resp.Content | Where-Object { $_.implementation -eq $Check.expects -or $_.name -eq $Check.expects })
        if ($match.Count -gt 0) { return [pscustomobject]@{ Status = 'pass'; Detail = "download client '$($Check.expects)' configured" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = "no download client matching '$($Check.expects)' found" }
    }
    readarrDownloadClient = {
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v1/downloadclient" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query $HttpBaseUrl/api/v1/downloadclient : $($resp.Detail)" } }
        $match = @($resp.Content | Where-Object { $_.implementation -eq $Check.expects -or $_.name -eq $Check.expects })
        if ($match.Count -gt 0) { return [pscustomobject]@{ Status = 'pass'; Detail = "download client '$($Check.expects)' configured" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = "no download client matching '$($Check.expects)' found" }
    }
    arrIndexerSource = {
        # Sonarr/Radarr (Servarr v3 API).
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v3/indexer" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query $HttpBaseUrl/api/v3/indexer : $($resp.Detail)" } }
        $count = @($resp.Content).Count
        if ($count -gt 0) { return [pscustomobject]@{ Status = 'pass'; Detail = "$count indexer(s) synced from Prowlarr" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = 'no indexers present yet -- check the Prowlarr application link' }
    }
    readarrIndexerSource = {
        # Readarr's stable API is versioned v1, unlike Sonarr/Radarr's v3.
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v1/indexer" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query $HttpBaseUrl/api/v1/indexer : $($resp.Detail)" } }
        $count = @($resp.Content).Count
        if ($count -gt 0) { return [pscustomobject]@{ Status = 'pass'; Detail = "$count indexer(s) synced from Prowlarr" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = 'no indexers present yet -- check the Prowlarr application link' }
    }
    prowlarrIndexerCount = {
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v1/indexer" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query $HttpBaseUrl/api/v1/indexer : $($resp.Detail)" } }
        $count = @($resp.Content).Count
        if ($count -gt 0) { return [pscustomobject]@{ Status = 'pass'; Detail = "$count indexer(s) configured" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = 'no indexers configured yet -- this is the indexer-keys manual gate' }
    }
    overseerrPlexLink = {
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/v1/settings/plex" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query Overseerr's Plex settings: $($resp.Detail)" } }
        if ($resp.Content -and $resp.Content.ip) { return [pscustomobject]@{ Status = 'pass'; Detail = "Plex linked at $($resp.Content.ip)" } }
        return [pscustomobject]@{ Status = 'fail'; Detail = 'Plex is not linked in Overseerr settings yet' }
    }
    bazarrArrLink = {
        param($ApiKey, $Check, $HttpBaseUrl, $HttpChecker)
        $resp = & $HttpChecker -Method 'GET' -Url "$HttpBaseUrl/api/system/status" -Headers @{ 'X-Api-Key' = $ApiKey }
        if (-not $resp.Success) { return [pscustomobject]@{ Status = 'fail'; Detail = "could not query Bazarr's status: $($resp.Detail)" } }
        return [pscustomobject]@{ Status = 'pass'; Detail = 'Bazarr reachable via its API (Sonarr/Radarr link set up manually in its UI)' }
    }
}

function Invoke-ConfigCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Check,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$HttpBaseUrl,
        [scriptblock]$HttpChecker
    )
    if (-not $HttpChecker) { $HttpChecker = Get-HttpChecker }
    if (-not $script:ConfigCheckHandlers.ContainsKey($Check.type)) {
        throw "Unknown configCheck type '$($Check.type)'. Add a handler to Validate.psm1's ConfigCheckHandlers table."
    }
    & $script:ConfigCheckHandlers[$Check.type] $ApiKey $Check $HttpBaseUrl $HttpChecker
}

# ---------------------------------------------------------------------------
# Volume path correctness
# ---------------------------------------------------------------------------

function Test-VolumePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][string[]]$ExpectedPaths,
        [Parameter(Mandatory)][hashtable]$TierPaths,
        [scriptblock]$DockerRunner
    )
    if (-not $DockerRunner) { $DockerRunner = Get-ValidateDockerRunner }

    $result = & $DockerRunner -Arguments @('inspect', $ContainerName, '--format', '{{json .Mounts}}') -EnvVars @{}
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Status = 'fail'; Detail = "could not inspect mounts for '$ContainerName'" }
    }

    try {
        $mounts = ($result.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Status = 'fail'; Detail = "could not parse mount list for '$ContainerName'" }
    }
    $sources = @($mounts | ForEach-Object { $_.Source })

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($expected in $ExpectedPaths) {
        $resolved = Resolve-ManifestPath -Path $expected -TierPaths $TierPaths
        if ($sources -notcontains $resolved) { $missing.Add($resolved) }
    }

    if ($missing.Count -eq 0) {
        return [pscustomobject]@{ Status = 'pass'; Detail = "all $($ExpectedPaths.Count) expected volume path(s) mounted" }
    }
    return [pscustomobject]@{ Status = 'fail'; Detail = "missing expected mount(s): $($missing -join ', ')" }
}

# ---------------------------------------------------------------------------
# Top-level orchestrator
# ---------------------------------------------------------------------------

function Test-ServiceState {
    <#
    .SYNOPSIS
        Runs every applicable check for one manifest and rolls them up into
        an overall status: not-installed, needs-attention, not-yet-valid,
        or already-valid. Used both pre-deploy (can this be skipped?) and
        post-deploy (did the deploy actually work?) -- same checks either
        time, per the design doc's idempotency model.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][hashtable]$TierPaths,
        [bool]$CaddyDeployed = $false,
        [string]$TailnetDomain = '',
        [scriptblock]$DockerRunner,
        [scriptblock]$HttpChecker,
        [scriptblock]$FileTester,
        [scriptblock]$FileContentReader
    )

    $checks = [ordered]@{}

    $hasValidate = $Manifest.PSObject.Properties.Match('validate').Count -gt 0
    if (-not $hasValidate) {
        return [pscustomobject]@{ Id = $Manifest.id; Status = 'already-valid'; Detail = 'no validation defined for this service'; Checks = $checks }
    }
    $v = $Manifest.validate

    if ($v.PSObject.Properties.Match('container').Count -gt 0) {
        $containerResult = Test-ContainerHealth -ContainerName $v.container -DockerRunner $DockerRunner
        $checks['container'] = $containerResult
        if ($containerResult.Status -eq 'not-installed') {
            return [pscustomobject]@{ Id = $Manifest.id; Status = 'not-installed'; Detail = $containerResult.Detail; Checks = $checks }
        }
        if ($containerResult.Status -eq 'fail') {
            return [pscustomobject]@{ Id = $Manifest.id; Status = 'needs-attention'; Detail = $containerResult.Detail; Checks = $checks }
        }
    }

    $subStatuses = [System.Collections.Generic.List[string]]::new()

    if ($v.PSObject.Properties.Match('httpCheck').Count -gt 0) {
        $hc = $v.httpCheck
        if ($hc.PSObject.Properties.Match('direct').Count -gt 0) {
            $r = Test-HttpReachability -Url $hc.direct.url -ExpectStatus $hc.direct.expectStatus -HttpChecker $HttpChecker
            $checks['httpDirect'] = $r
            $subStatuses.Add($r.Status)
        }
        if ($hc.PSObject.Properties.Match('proxied').Count -gt 0) {
            if ($CaddyDeployed -and -not [string]::IsNullOrWhiteSpace($TailnetDomain)) {
                $host_ = $hc.proxied.hostTemplate -replace '\{tailnetDomain\}', $TailnetDomain
                $r = Test-HttpReachability -Url "https://$host_" -ExpectStatus $hc.proxied.expectStatus -HttpChecker $HttpChecker
                $checks['httpProxied'] = $r
                $subStatuses.Add($r.Status)
            } elseif (-not $CaddyDeployed) {
                $checks['httpProxied'] = [pscustomobject]@{ Status = 'not-applicable'; Detail = 'Caddy not deployed yet' }
            } else {
                $checks['httpProxied'] = [pscustomobject]@{ Status = 'not-applicable'; Detail = 'tailnet domain not set in config.json yet' }
            }
        }
    }

    $apiKeyResult = $null
    if ($v.PSObject.Properties.Match('configChecks').Count -gt 0 -and @($v.configChecks).Count -gt 0) {
        $apiKeyResult = Resolve-ApiKey -Manifest $Manifest -TierPaths $TierPaths -FileTester $FileTester -FileContentReader $FileContentReader
        if ($apiKeyResult.Status -eq 'pass') {
            $baseUrl = $hc.direct.url -replace '/[^/]*$', ''
            foreach ($check in @($v.configChecks)) {
                $r = Invoke-ConfigCheck -Check $check -ApiKey $apiKeyResult.Key -HttpBaseUrl $baseUrl -HttpChecker $HttpChecker
                $checks["config:$($check.type)"] = $r
                $subStatuses.Add($r.Status)
            }
        } else {
            $checks['apiKey'] = $apiKeyResult
            $subStatuses.Add($apiKeyResult.Status)
        }
    }

    if ($v.PSObject.Properties.Match('volumePaths').Count -gt 0 -and @($v.volumePaths).Count -gt 0) {
        $r = Test-VolumePaths -ContainerName $v.container -ExpectedPaths @($v.volumePaths) -TierPaths $TierPaths -DockerRunner $DockerRunner
        $checks['volumePaths'] = $r
        $subStatuses.Add($r.Status)
    }

    $overall = 'already-valid'
    if ($subStatuses -contains 'fail') {
        $overall = 'needs-attention'
    } elseif ($subStatuses -contains 'not-yet-valid') {
        $overall = 'not-yet-valid'
    }

    $failDetails = @($checks.Values | Where-Object { $_.Status -in @('fail', 'not-yet-valid') } | ForEach-Object { $_.Detail })
    $detail = if ($failDetails.Count -gt 0) { $failDetails -join '; ' } else { 'all checks passed' }

    [pscustomobject]@{ Id = $Manifest.id; Status = $overall; Detail = $detail; Checks = $checks }
}

Export-ModuleMember -Function `
    Get-ValidateDockerRunner, Set-ValidateDockerRunner, `
    Get-HttpChecker, Set-HttpChecker, `
    Get-FileTester, Set-FileTester, `
    Get-FileContentReader, Set-FileContentReader, `
    Resolve-ManifestPath, Test-ContainerHealth, Test-HttpReachability, `
    Resolve-ApiKey, Invoke-ConfigCheck, Test-VolumePaths, Test-ServiceState
