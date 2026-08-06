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
  "dependsOn": ["deluge", "prowlarr"],
  "compose": "compose/media/sonarr.yml",
  "manualGates": [],
  "validate": {
    "container": "sonarr",
    "httpCheck": { "url": "http://localhost:8989/ping", "expectStatus": 200 },
    "configChecks": [
      { "type": "sonarrDownloadClient", "expects": "deluge" }
    ],
    "volumePaths": ["<bulk>/media/tv", "<fast>/appdata/sonarr"]
  }
}
```

- `dependsOn` drives auto-selection and install ordering (topological sort;
  foundation services always resolve first).
- `manualGates` names one or more gates defined centrally in `Gate.psm1`
  (e.g. `"plex-claim"`, `"tailscale-login"`), so gate text/logic lives in
  one place rather than being duplicated per manifest.
- `configChecks` are small typed checks (`sonarrDownloadClient`,
  `overseerrPlexLink`, etc.), each implemented as a function in
  `Validate.psm1` keyed by `type`. Adding a new check kind later means
  adding one function, not changing the schema.
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
   Prowlarr — required by Sonarr"`.
5. **Compute install order** via topological sort over the final
   selection, foundation first.
6. **For each service in order:**
   - **Check current state** (`Validate.psm1`): is the container present
     and healthy, do config checks pass, are volume paths correct? If
     fully valid already, mark `already-valid` and skip deployment.
   - **If a manual gate applies and isn't yet satisfied** (per
     `config.json`): pause, print exact instructions, wait for
     acknowledgment or input, then re-check before proceeding.
   - **Deploy** (`Deploy.psm1`): `docker compose -f <compose> up -d`,
     using the resolved tier paths and any gate-supplied values
     (tokens/credentials) as environment input to that service's compose.
   - **Re-validate** using the same checks; record pass/fail and detail.
7. **Report** (`Report.psm1`): a table of
   `service | status (already-valid / installed / needs-attention) | detail`,
   followed by a deduplicated list of any manual follow-ups still
   outstanding (e.g. "Prowlarr: add indexer accounts — not automatable").

## Manual-gate mechanics

`Gate.psm1` holds a small table of named gates, each one of two kinds:

- **Blocking-with-input** — the script needs a value it cannot obtain
  itself (a token, a credential); it prompts, reads the value, and injects
  it into that service's compose environment. Examples: `plex-claim`,
  `backup-dest` (cloud backup credentials).
- **Blocking-acknowledgment** — a real-world action the script cannot
  verify programmatically; it prints instructions and waits for the user
  to confirm completion. Examples: `tailscale-login` (run `tailscale up`,
  press Enter), `router-dns` (point router DNS at AdGuard, press Enter),
  `indexer-keys` (add indexer accounts in Prowlarr's UI, press Enter).

A satisfied gate is recorded in `config.json` so re-runs don't re-prompt
for it — unless a later validation shows it's no longer satisfied (e.g.
Tailscale reports logged out), in which case the gate re-triggers.

## Validation checks

Each service's validation may include up to four check types, matching
what a completed setup actually needs to demonstrate:

- **Container health** — `docker inspect`: running, correct image, not
  restart-looping.
- **Reachability** — HTTP check against the service's own port directly
  (works even before the reverse proxy is configured for it), and
  separately against its reverse-proxy hostname once Caddy is deployed.
- **Config wiring** — service-specific, implemented as small functions
  (e.g. querying Sonarr's API to confirm its download client list
  includes Deluge at the expected host:port).
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

- **Pester unit tests** for the pure logic: dependency resolution /
  topological sort, manifest schema validation. Deterministic, no Docker
  required.
- **Manual end-to-end testing** on the actual homelab PC for the
  deploy/validate/gate flow — this depends on real Docker and real running
  services, and mocking it away would lose the point of the validation
  step.

## Out of scope for this pass

- Cross-platform support (Linux/TrueNAS/Unraid) — the role-based agnostic
  plan still describes *what* to build there; this wizard automates the
  Windows path specifically.
- A GUI or web-based picker — CLI wizard only.
- Any service not already in the fixed list from the existing
  implementation plans.
