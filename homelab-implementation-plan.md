# Homelab Implementation Plan

Target: a dedicated Windows PC running Docker-based self-hosted services for
media, audiobooks, files, photos, passwords, network filtering, and future
personal dev projects. This document is meant to be handed to an agent
running on that PC to execute.

## 0. Assumptions / current state

- PC: Windows, 64GB RAM, dedicated to this role (not daily-use).
- Storage: 1x 1TB SSD (currently boot drive), 1x 14TB external HDD (currently
  has existing media data on it), plus a second 14TB+ HDD to be purchased.
- No Docker, no reverse proxy, no Tailscale installed yet.
- User has a Plex Pass subscription — Plex itself is the media server,
  keep using it (do not replace with Jellyfin).

## 1. Storage layout

1. Physically install the second 14TB (or larger, CMR not SMR) HDD internally
   alongside the existing 14TB drive.
2. Create a **Storage Spaces two-way mirror** across both HDDs. This is the
   redundancy layer — survives one physical drive failure with no data loss.
   - Migrate existing data from the external 14TB HDD onto the new mirrored
     volume before repurposing/retiring the old external enclosure.
3. Keep the 1TB SSD as a separate volume for:
   - Docker Desktop / Engine install
   - all container configs, app databases (Postgres/SQLite for Immich,
     Nextcloud, Vaultwarden, etc.)
   - anything latency-sensitive
4. Target folder structure (adjust drive letters to actual setup):

   ```
   D:\ (Storage Spaces mirror — bulk/media data)
     media\movies\
     media\tv\
     media\audiobooks\
     media\books\
     downloads\             <- Deluge writes here, *arr apps import from here
     nextcloud-data\
     photos\immich-library\

   C:\homelab\ (on the SSD — configs, compose files, app state)
     compose\               <- one subfolder per stack, see §3
     appdata\<service>\     <- persistent config/db volumes per service
   ```

5. Do not mix "downloads" and "final library" folders on different drives if
   avoidable — same-drive moves are instant, cross-drive moves get slow at
   scale; keep downloads and final media folders on the same mirrored volume.

## 2. Base platform

1. Install **Docker Desktop** (WSL2 backend) or Docker Engine directly in
   WSL2 — either is fine; Docker Desktop is the simpler default on Windows.
2. Enable Windows auto-login for this machine, and disable sleep/hibernate
   in power settings (server needs to stay up).
3. Schedule Windows Update active hours / defer restarts so updates don't
   silently reboot the box during active use; still allow updates to apply.
4. Install **Tailscale** (native Windows app) on the server. Enable
   **MagicDNS** on the tailnet so services get clean hostnames
   (`server.<tailnet>.ts.net`) instead of raw IPs.
5. Create one shared external Docker network (e.g. `proxy-net`) that every
   compose stack joins, so Caddy can reach every container by service name
   regardless of which compose file it came from.
   ```
   docker network create proxy-net
   ```
6. Set up **Caddy** as the reverse proxy, also joined to `proxy-net`. Give
   each service a subdomain over Tailscale's MagicDNS domain. Reload
   (`caddy reload`) rather than restart when adding new sites — zero
   downtime.
7. Install **Dockge** for a web UI over all the Compose stacks (point it at
   `C:\homelab\compose`).

## 3. Compose stack organization

Keep each logical group as its own `docker-compose.yml` under
`C:\homelab\compose\<group>\`, all attached to `proxy-net`. Suggested
grouping (mirrors the service groups in the diagram):

```
compose/
  proxy/          caddy
  media/          plex, sonarr, radarr, prowlarr, bazarr, overseerr
  audiobooks/     audiobookshelf, readarr-audiobook, audiobookrequest
  files/          nextcloud (+ its db, e.g. postgres/mariadb)
  photos/         immich (+ postgres, redis — per Immich's own compose reqs)
  security/       vaultwarden
  network/        adguardhome
  infra/          deluge, duplicati (or kopia), uptime-kuma
```

Each service's persistent data/config goes under
`C:\homelab\appdata\<service>\`; each service's media/library data
references the paths under `D:\` from §1.

## 4. Build order (do this sequentially, verify each phase before moving on)

**Phase 1 — Foundation**
1. Storage Spaces mirror created and existing data migrated (§1).
2. Docker installed, `proxy-net` created.
3. Tailscale installed and joined to tailnet, MagicDNS on.
4. Caddy stack up, confirm you can reach a trivial test container over
   Tailscale via a Caddy-routed hostname before adding anything real.
5. Dockge up, pointed at the compose folder.

**Phase 2 — Download infrastructure**
6. Deluge container up, data directory on the mirrored volume.
7. Prowlarr up, connect it to your indexers.

**Phase 3 — Media (Plex)**
8. Plex container (or keep existing native Plex install if already
   configured — don't force a migration if it's already working) pointed
   at the `media\movies` / `media\tv` folders.
9. Sonarr + Radarr up, each pointed at Deluge as the download client and
   Prowlarr as the indexer source, output folders into `media\tv` /
   `media\movies`.
10. Bazarr up, connected to Sonarr/Radarr for subtitle fetching.
11. Overseerr up, connected to Plex + Sonarr + Radarr. Confirm a manual
    request end-to-end (request in Overseerr → shows in Radarr → Deluge
    downloads → Plex library updates).

**Phase 4 — Audiobooks**
12. Audiobookshelf up, library pointed at `media\audiobooks`.
13. Readarr (audiobook profile/instance) up, connected to Deluge + Prowlarr,
    output into `media\audiobooks`.
14. AudiobookRequest up, connected to Readarr. Confirm a manual request
    end-to-end.

**Phase 5 — Files & photos**
15. Nextcloud + its database up, data directory on `nextcloud-data`.
    Explicitly **disable/skip the Photos/Memories app** in Nextcloud —
    Immich owns photos, avoid duplicate storage of the same images.
16. Immich (server + Postgres + Redis, per Immich's official compose file)
    up, library on `photos\immich-library`. Install the Immich mobile app
    and confirm auto-backup works over Tailscale.

**Phase 6 — Security & network**
17. Vaultwarden up. Install Bitwarden client apps pointed at its URL.
    Migrate/import existing passwords.
18. AdGuard Home up. Point the home router's DNS (or individual devices) at
    it. Confirm ad blocking works before rolling out to all devices.
19. (Optional, later) Home Assistant, only if/when actually wanted.

**Phase 7 — Operations**
20. Duplicati (or Kopia/restic) up. Configure backup jobs specifically for:
    - Immich library + its Postgres DB
    - Nextcloud data + its DB
    - Vaultwarden data folder
    Target an off-box destination (cloud cold storage like Backblaze B2, or
    at minimum a separate physical drive) — the Storage Spaces mirror does
    not protect against deletion, corruption, or ransomware.
21. Uptime Kuma up. Add a monitor per service (HTTP check against each
    Caddy-routed hostname). Configure a notification channel (e.g. push or
    email) for downtime alerts.

**Phase 8 — Ready for personal dev projects**
22. Document the "add a new app" pattern (already established by Caddy in
    §2.6): containerize the app, add its compose file under
    `compose/<project-name>/`, join `proxy-net`, add a Caddy site block, add
    an Uptime Kuma monitor. No structural changes needed per new app.

## 5. Verification checklist (run after each phase, not just at the end)

- [ ] Every service reachable via its Tailscale/MagicDNS hostname through Caddy
- [ ] Storage Spaces mirror shows healthy status, no drive degraded
- [ ] Overseerr → Sonarr/Radarr → Deluge → Plex request flow works end-to-end
- [ ] AudiobookRequest → Readarr → Deluge → Audiobookshelf request flow works
- [ ] Immich mobile app auto-backs-up a test photo
- [ ] Nextcloud photo/gallery app is disabled (no duplicate photo storage)
- [ ] Vaultwarden reachable from a Bitwarden client, existing vault imported
- [ ] AdGuard Home actively blocking on at least one test device
- [ ] Duplicati/Kopia backup job has completed at least one successful run for
      Immich, Nextcloud, and Vaultwarden data
- [ ] Uptime Kuma shows all services green, and a manual downtime test
      triggers a notification

## 6. Explicitly out of scope for this pass

- Authelia / single sign-on — revisit only if login fatigue becomes a real
  problem once the stack is stable.
- Public (non-Tailscale) exposure of any service — everything is
  Tailscale-only by default; only add a public-facing reverse proxy path
  deliberately and per-service if ever needed (e.g. sharing
  Overseerr/AudiobookRequest with someone outside the tailnet).
- Xteink X4 ebook reader integration — dropped from scope per earlier
  decision.
