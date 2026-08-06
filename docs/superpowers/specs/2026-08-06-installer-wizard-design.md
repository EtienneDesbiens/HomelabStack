# Homelab Installer Wizard — Design

## Goal

A single tool, runnable on the homelab PC, that lets a user pick which
services from the HomelabStack to install, deploys exactly those (plus any
required dependencies), and validates that anything already installed is
actually configured correctly. Safe to re-run at any time — re-running only
acts on what's missing or misconfigured.

## Scope for this pass

- Target platform: **Windows only** (matches the current homelab PC and the
  existing Windows-specific implementation plan). Cross-platform support is
  out of scope for now.
- Tool implementation: **PowerShell**, no additional runtime dependency.
- Interaction model: **interactive CLI wizard** — checkbox-style service
  selection, run top to bottom in one sitting (with inline pauses for steps
  that genuinely require the human, per the manual-gate design below).
- Service set: the same fixed list already defined across the Windows and
  agnostic implementation plans (Plex, Sonarr, Radarr, Prowlarr, Bazarr,
  Overseerr, Audiobookshelf, Readarr, AudiobookRequest, Nextcloud, Immich,
  Vaultwarden, AdGuard Home, plus the shared infra roles: download client,
  backup tool, uptime monitor, reverse proxy, remote-access mesh, stack UI).

## Repository layout

```
HomelabStack/
  install.ps1                     entry point
  lib/
    Manifest.psm1                 load/validate service manifests, resolve dependency graph
    Deploy.psm1                   docker compose up/down wrapper, network/volume prep
    Validate.psm1                 run a service's validation checks, return pass/fail + detail
    Gate.psm1                     pause-and-prompt logic for manual steps
    Report.psm1                   summary table + pending-manual-steps list
  services/
    foundation/
      docker-network.json
      caddy.json
      tailscale.json
      dockge.json
    media/
      plex.json
      sonarr.json
      radarr.json
      prowlarr.json
      bazarr.json
      overseerr.json
    audiobooks/
      audiobookshelf.json
      readarr-audiobook.json
      audiobookrequest.json
    files/
      nextcloud.json
    photos/
      immich.json
    security/
      vaultwarden.json
    network/
      adguardhome.json
    infra/
      deluge.json
      backup-tool.json
      uptime-kuma.json
  compose/
    foundation/caddy.yml, dockge.yml
    media/plex.yml, sonarr.yml, radarr.yml, prowlarr.yml, bazarr.yml, overseerr.yml
    audiobooks/audiobookshelf.yml, readarr-audiobook.yml, audiobookrequest.yml
    files/nextcloud.yml
    photos/immich.yml
    security/vaultwarden.yml
    network/adguardhome.yml
    infra/deluge.yml, uptime-kuma.yml, backup-tool.yml
  config.json                     generated on first run: storage tier paths, manual-gate satisfaction, remembered selections
```

One compose file per service (not per group) so selecting/deselecting a
service never requires editing a shared file.

## Manifest schema

Each `services/**/<id>.json`:

```json
{
  "id": "sonarr",
  "name": "Sonarr",
  "group": "media",
  "phase": 3,
  "dependsOn": ["deluge", "prowlarr"],
  "compose": "compose/media/sonarr.yml",
  "ports": [8989],
  "manualGates": [],
  "apiKeySource": {
    "type": "fileRead",
    "path": "<fast>/appdata/sonarr/config.xml",
    "xpath": "//Config/ApiKey"
  },
  "validate": {
    "container": "sonarr",
    "httpCheck": {
      "direct": { "url": "http://localhost:8989/ping", "expectStatus": 200 },
      "proxied": { "hostTemplate": "sonarr.{tailnetDomain}", "expectStatus": 200 }
    },
    "configChecks": [
      { "type": "sonarrDownloadClient", "expects": "deluge" }
    ],
    "volumePaths": ["<bulk>/media/tv", "<fast>/appdata/sonarr"]
  }
}
```

- `dependsOn` drives auto-selection and dependency-correctness ordering.
  `phase` (see step 6 of "Wizard flow" below) is the primary sort key;
  `dependsOn` is enforced as a tiebreak and as a correctness check within a
  phase.
- `ports` lists host ports this service binds, used for the pre-flight
  collision check (see "Wizard flow" step 5).
- `apiKeySource` tells `Validate.psm1` how to obtain the API key a
  config-wiring check needs, since apps like Sonarr/Radarr/Prowlarr/Overseerr
  generate their own key on first start rather than accepting one. Supported
  `type`s: `fileRead` (read a value out of the app's own config file inside
  its appdata volume, located via an xpath/jsonpath depending on the file
  format) or `none` (service has no config-wiring checks). Resolving this
  requires the service's own container to have started and written its config
  at least once — `Validate.psm1` retries with a short backoff for a service
  that was *just* deployed, and treats "config file not yet present" as
  `not-yet-valid` rather than an error.
- `manualGates` is a list of objects, not bare strings, each naming a gate
  defined centrally in `Gate.psm1` and the compose environment variable it
  feeds: `{ "name": "plex-claim", "envVar": "PLEX_CLAIM" }`. This is the
  explicit link between "a gate produced a value" and "where that value goes."
  Acknowledgment-only gates (e.g. `tailscale-login`) omit `envVar`.
- `configChecks` are small typed checks (`sonarrDownloadClient`,
  `overseerrPlexLink`, etc.), each implemented as a function in
  `Validate.psm1` keyed by `type`, taking the resolved API key as input.
  Adding a new check kind later means adding one function, not changing the
  schema.
- `httpCheck` has two variants: `direct` (the service's own container port,
  checkable even before Caddy is configured) and `proxied` (its
  reverse-proxy hostname, built from `hostTemplate` once Caddy + the
  remote-access mesh are up). Both are attempted when applicable; `proxied`
  is skipped with a `not-applicable` status (not a failure) if Caddy isn't
  deployed yet.
- `<bulk>` and `<fast>` are placeholders resolved from `config.json` at
  run time (the two storage tier roots established in the Windows/agnostic
  implementation plans).

## Wizard flow (`install.ps1`)

1. **Load `config.json`** if present (fast/bulk tier root paths, prior
   selections, satisfied manual gates). On first run, prompt for the two
   storage tier root paths and persist them.
2. **Load all manifests**, build the dependency graph.
3. **Present checkboxes**, grouped by category (media, audiobooks, files,
   photos, security, network). Foundation services are listed as an
   always-on informational section, not a checkbox — they underpin
   everything and are never separately opted out of.
4. **Resolve dependencies**: for each checked service, walk `dependsOn`
   and auto-check anything missing, printing e.g. `"Added Deluge and
   Prowlarr — required by Sonarr"`. When a later manual gate fires for an
   auto-added dependency, its prompt names the service that pulled it in
   (e.g. `"Prowlarr needs indexer accounts (added as a dependency of
   Sonarr) — ..."`) so the reason is never a mystery.
5. **Pre-flight checks** over the final selection, before anything is
   deployed:
   - **Port collisions**: compare `ports` across all selected services;
     abort with a clear message naming the conflicting services if any
     host port is claimed twice. Nothing is deployed until this passes.
   - **Deselected-but-installed dependencies**: if a selected service
     depends on something not selected, check whether that dependency is
     already installed and valid; if so, treat it as satisfied without
     re-adding it to the checklist output. If not installed, auto-add it
     per step 4.
6. **Compute install order**: primary sort key is each service's `phase`
   number (foundation implicitly phase 0), matching the phased build order
   from the implementation plans (foundation → download infra → media →
   audiobooks → files/photos → security/network → operations). Within a
   phase, apply a topological sort on `dependsOn` as a tiebreak and a
   correctness check — a same-phase dependency edge that would violate the
   order is a configuration error in the manifests, not something the
   wizard silently resolves.
7. **For each service in order:**
   - **Check current state** (`Validate.psm1`): is the container present
     and healthy, do config checks pass, are volume paths correct? If
     fully valid already, mark `already-valid` and skip deployment.
   - **If a manual gate applies and isn't yet satisfied** (per
     `config.json`): pause, print exact instructions, wait for
     acknowledgment or input, then re-check before proceeding.
   - **Deploy** (`Deploy.psm1`): `docker compose -f <compose> up -d`,
     using the resolved tier paths and any gate-supplied values
     (tokens/credentials) as environment input to that service's compose,
     per each gate's declared `envVar`.
   - **Re-validate** using the same checks; record pass/fail and detail.
8. **Report** (`Report.psm1`): a table of
   `service | status (already-valid / installed / needs-attention) | detail`,
   followed by a deduplicated list of any manual follow-ups still
   outstanding (e.g. "Prowlarr: add indexer accounts — not automatable").

**Interruption**: if the script is stopped mid-run (Ctrl+C, crash, closed
terminal), no explicit resume state is written beyond what `config.json`
already persists (tier paths, satisfied gates). This is intentional given
the idempotency design: re-running from the top always re-checks real
system state first, so a partially-completed run is resolved simply by
running the wizard again — already-deployed, already-valid services are
skipped, and work resumes from wherever it actually stopped.

**Uninstalling / deselecting**: the wizard never removes a service.
Unchecking a service that is already installed leaves its container
running untouched — this run treats it as "not part of this session's
work," not as a removal request. Uninstalling a service is out of scope
for this design (see "Out of scope").

## Manual-gate mechanics

`Gate.psm1` holds a small table of named gates, each one of two kinds, with
different re-trigger semantics:

- **Blocking-with-input** — the script needs a value it cannot obtain
  itself (a token, a credential); it prompts, reads the value, and injects
  it into that service's compose environment via the `envVar` declared on
  the manifest's `manualGates` entry. Examples: `plex-claim` (a short-lived,
  single-use token), `backup-dest` (cloud backup credentials). **Re-trigger
  rule**: once used successfully in a deploy, an input gate is considered
  permanently satisfied and is never re-validated — there is nothing to
  re-check about a token that's already been consumed. If a later
  deployment genuinely needs a fresh value (e.g. redeploying Plex from
  scratch), that is a new gate invocation tied to that new deploy action,
  not a re-validation of the old one.
- **Blocking-acknowledgment** — a real-world action the script cannot
  perform, but *can* verify after the fact; it prints instructions and
  waits for the user to confirm completion, then re-checks. Examples:
  `tailscale-login` (run `tailscale up`, press Enter — re-checked via
  `tailscale status`), `router-dns` (point router DNS at AdGuard, press
  Enter — not independently verifiable, treated as acknowledgment-only),
  `indexer-keys` (add indexer accounts in Prowlarr's UI, press Enter —
  re-checked by querying Prowlarr's indexer list). **Re-trigger rule**:
  recorded as satisfied in `config.json`, but re-validated on every run
  where verification is possible (Tailscale, Prowlarr indexers); if that
  check now fails, the gate fires again. Gates with no independent check
  (`router-dns`) are trusted once acknowledged and never re-prompted.

## Validation checks

Each service's validation may include up to four check types, matching
what a completed setup actually needs to demonstrate:

- **Container health** — `docker inspect`: running, correct image, not
  restart-looping.
- **Reachability** — HTTP check against the service's own port directly
  (works even before the reverse proxy is configured for it), and
  separately against its reverse-proxy hostname once Caddy is deployed
  (skipped as `not-applicable`, not failed, if Caddy isn't up yet).
- **Config wiring** — service-specific, implemented as small functions
  (e.g. querying Sonarr's API to confirm its download client list
  includes Deluge at the expected host:port). Requires an API key, obtained
  per the manifest's `apiKeySource` (see "Manifest schema") by reading it
  out of the service's own config file after its first successful start.
  If the config file doesn't exist yet (service was just deployed and
  hasn't written it), the check reports `not-yet-valid` and is retried with
  a short backoff rather than treated as a failure.
- **Data path correctness** — inspecting the container's mounted volumes
  and comparing against the manifest's `volumePaths`.

## Idempotency

No separate "have I run before" flag. Every run recomputes actual system
state (Docker state + each service's own API/config) before deciding to
act, so the wizard stays correct even if something was changed outside of
it. `config.json` persists only what genuinely can't be re-derived: the
two storage tier root paths, and which manual gates have already been
satisfied.

## Testing approach

- **Pester unit tests** for the pure logic: dependency resolution, phase +
  topological ordering, port-collision detection, manifest schema
  validation. Deterministic, no Docker required.
- **Dry-run mode** (`install.ps1 -WhatIf`): runs the full flow — manifest
  loading, dependency resolution, pre-flight checks, ordering, and
  per-service state checks — but replaces the `Deploy.psm1` calls with a
  logged no-op instead of actually invoking `docker compose`. This lets the
  planned action list (what would be installed, in what order, which gates
  would fire and why) be reviewed and regression-tested on every change to
  the wizard logic without requiring Docker or real services. `Deploy.psm1`
  exposes its `docker compose` calls through a small injectable wrapper so
  Pester can substitute a mock and assert on what *would* have been run.
- **Manual end-to-end testing** on the actual homelab PC for the real
  deploy/validate/gate flow — this depends on real Docker and real running
  services, and mocking it away would lose the point of the validation
  step. Dry-run mode narrows what still needs this kind of testing to just
  "does the actual deployment and validation work," not "did the wizard
  plan the right thing."

## Out of scope for this pass

- Cross-platform support (Linux/TrueNAS/Unraid) — the role-based agnostic
  plan still describes *what* to build there; this wizard automates the
  Windows path specifically.
- A GUI or web-based picker — CLI wizard only.
- Any service not already in the fixed list from the existing
  implementation plans.
- Uninstalling/removing a service — the wizard is additive only; removal
  is a manual `docker compose down` for now.

## Addendum (implementation pass): Docker Desktop bootstrap

Added after the initial design, so `install.ps1` is a true "clone the repo
and run it" experience with nothing to install first:

- **`lib/Prereqs.psm1`** runs as step 0, before manifest loading. It checks
  `Test-DockerAvailable` (the `docker` CLI exists *and* the daemon
  responds — Desktop can be installed but not started). If unavailable:
  - Not elevated → relaunches the whole script elevated (`Start-Process
    -Verb RunAs -Wait`) and exits with the elevated process's exit code.
  - Elevated but `wsl --status` doesn't exit cleanly → runs
    `wsl --install --no-distro` (the officially supported one-shot command
    that provisions the actual WSL2 kernel/platform, not just the
    Windows optional features), re-checks, and only reports
    reboot-required if `wsl --status` is *still* failing afterward. First
    version of this checked only whether the two underlying Windows
    optional features were toggled "Enabled" via DISM, which turned out
    to be necessary but not sufficient — Docker Desktop still reported
    "WSL not installed" with just the features on, since the WSL2
    kernel/platform component itself was still missing. Asking `wsl.exe`
    directly (the same thing Docker Desktop itself checks) avoids that
    class of bug by construction. Re-running `install.ps1` after a
    reboot resumes cleanly, same as any other idempotent step in this
    design.
  - Elevated and WSL2-ready → downloads Docker Desktop's installer and
    runs it silently (`install --quiet --accept-license --backend=wsl-2`),
    then polls until the daemon responds (Desktop's first launch is slow).
- Every external touchpoint (process launch, download, elevation check,
  `wsl.exe`, docker CLI) is an injectable scriptblock, same pattern as
  `Deploy.psm1`/`Validate.psm1`, so the branching logic is Pester-tested
  without ever running a real installer, touching Windows features, or
  needing real elevation.
- Skipped entirely under `-WhatIf` (just logs whether it would install) or
  the new `-SkipDockerInstall` switch, for anyone managing Docker
  themselves or running outside Windows/Desktop's auto-install path.
- Windows-only, matching the rest of this design's platform scope. Backend
  is hardcoded to WSL2 (not Hyper-V) since the target machine is Windows
  11 **Home**, which can't run Hyper-V.
