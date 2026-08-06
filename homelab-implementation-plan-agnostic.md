# Homelab Implementation Plan (Setup-Agnostic)

This plan describes **what** to build and **in what order**, independent of
which OS, container runtime, or specific tool you pick within each category.
Every step names the *role* a piece of software fills; a short "options"
note lists common implementations of that role so the plan can be executed
on Windows, Linux, TrueNAS/Unraid, or a hybrid, without rewriting the plan.

Service scope (fixed — these are the decisions already made, only the
underlying platform is left open):

- **Media**: Plex (server), Sonarr, Radarr, Prowlarr, Bazarr, Overseerr
- **Audiobooks**: Audiobookshelf, Readarr (audiobook profile), AudiobookRequest
- **Files**: Nextcloud (files/docs only — photo module disabled)
- **Photos**: Immich
- **Security**: Vaultwarden
- **Network**: AdGuard Home
- **Shared infra**: a torrent/download client, a backup tool, an uptime
  monitor, a reverse proxy, a remote-access mesh, a container-stack UI

## 0. Roles and interchangeable options

| Role | Purpose | Common options |
|---|---|---|
| Host OS | Runs the container runtime | Windows + Docker Desktop/WSL2, Linux (Ubuntu/Debian), TrueNAS Scale, Unraid |
| Container runtime | Isolates each service | Docker Engine, Docker Desktop, Podman |
| Redundant storage | Survives one drive failure | Windows Storage Spaces mirror, Linux mdadm RAID1, ZFS mirror (TrueNAS), Unraid parity array |
| Reverse proxy | Clean hostnames + HTTPS per service | Caddy, Nginx Proxy Manager, Traefik |
| Remote access mesh | Reach services securely without port-forwarding | Tailscale, WireGuard (self-managed), ZeroTier |
| Download client | Fetches media/audiobook files found by the *arr apps | Deluge, qBittorrent, SABnzbd (Usenet) |
| Backup tool | Off-box copies of irreplaceable app data | Duplicati, Kopia, restic |
| Uptime monitor | Alerts when a service goes down | Uptime Kuma, Healthchecks.io (self-hosted) |
| Stack management UI | Visual layer over compose files | Dockge, Portainer |

Pick one option per role before starting; the phases below are written
against the *role*, not the specific product, so substituting a different
option in a role doesn't change the plan's structure.

## 1. Storage design (role: redundant storage + fast storage)

Regardless of implementation, the storage layer needs exactly two tiers:

1. **Fast tier** — hosts the container runtime, app configs, and app
   databases (Postgres/SQLite for Immich, Nextcloud, Vaultwarden). Should be
   solid-state; latency-sensitive, small footprint.
2. **Bulk/redundant tier** — hosts media, audiobooks, downloads, Nextcloud
   file data, and the Immich photo library. Must tolerate one physical drive
   failure without data loss — this requires at least two physical drives
   combined via whichever redundancy option from §0 fits the host OS.

Steps, in order:
1. Acquire and physically install the drives needed to form the redundant
   tier (minimum two drives of equal or compatible size).
2. Build the redundant volume using the chosen mirror/RAID/parity mechanism.
3. Migrate any existing media data onto the new redundant volume.
4. Establish a consistent top-level folder layout on the redundant volume,
   independent of OS path syntax:
   ```
   <bulk>/media/movies
   <bulk>/media/tv
   <bulk>/media/audiobooks
   <bulk>/downloads
   <bulk>/files/nextcloud
   <bulk>/photos/immich
   ```
5. Keep `downloads` on the **same volume** as the media folders it feeds —
   avoids slow cross-volume moves when the *arr apps import completed
   downloads.
6. On the fast tier, establish:
   ```
   <fast>/homelab/compose/<group>/
   <fast>/homelab/appdata/<service>/
   ```

## 2. Base platform (roles: host OS, container runtime, reverse proxy, remote access, stack UI)

1. Install the container runtime on the host OS.
2. Configure the host to stay available: disable sleep/hibernate, set
   auto-login or an equivalent unattended-boot mechanism, and schedule OS
   updates for a window that won't interrupt active use.
3. Install the remote-access mesh option and join it to your private
   network; enable whatever internal-DNS feature it offers (e.g. Tailscale
   MagicDNS) so services get stable hostnames instead of raw IPs.
4. Create one shared internal network at the container-runtime level (e.g.
   `docker network create proxy-net`) that every service joins, so the
   reverse proxy can reach any container by name regardless of which
   compose file/stack it belongs to.
5. Deploy the reverse proxy, joined to that shared network. Confirm it can
   route to one throwaway test container over the remote-access mesh before
   deploying anything real — this validates the whole chain (mesh → proxy →
   container) cheaply.
6. Deploy the stack management UI, pointed at the compose directory from §1.

## 3. Stack organization

One compose definition per logical group, all attached to the shared
internal network, data paths referencing the two storage tiers from §1:

```
media/         plex, sonarr, radarr, prowlarr, bazarr, overseerr
audiobooks/    audiobookshelf, readarr (audiobook), audiobookrequest
files/         nextcloud + its database
photos/        immich + its database/cache dependencies
security/      vaultwarden
network/       adguardhome
infra/         download client, backup tool, uptime monitor
proxy/         reverse proxy
```

Each service's config/database lives in `<fast>/homelab/appdata/<service>/`;
each service's library/media data references the relevant `<bulk>/...`
path.

## 4. Build order

Build in dependency order — each phase assumes the previous one is
reachable and healthy. Skip ahead only if a phase is genuinely irrelevant
to you (none are, given the fixed service scope in this plan).

**Phase 1 — Foundation**
1. Redundant storage volume built and populated (§1).
2. Container runtime + shared internal network created (§2.4).
3. Remote-access mesh joined, internal DNS enabled (§2.3).
4. Reverse proxy deployed and validated against a test container (§2.5).
5. Stack management UI deployed (§2.6).

**Phase 2 — Download infrastructure**
6. Download client deployed, data directory on the bulk tier's
   `downloads` folder.
7. Indexer manager (Prowlarr) deployed and connected to your indexer
   accounts.

**Phase 3 — Media**
8. Plex deployed, libraries pointed at `<bulk>/media/movies` and
   `<bulk>/media/tv`.
9. Sonarr + Radarr deployed, each pointed at the download client and the
   indexer manager, output folders into the matching media subfolders.
10. Subtitle manager (Bazarr) deployed, connected to Sonarr/Radarr.
11. Request front-end (Overseerr) deployed, connected to Plex + Sonarr +
    Radarr. Verify one request end-to-end: request → Radarr/Sonarr grabs it
    → download client fetches it → Plex library updates.

**Phase 4 — Audiobooks**
12. Audiobookshelf deployed, library pointed at `<bulk>/media/audiobooks`.
13. Readarr (audiobook profile) deployed, connected to the download client
    and indexer manager, output into the same folder.
14. AudiobookRequest deployed, connected to Readarr. Verify one request
    end-to-end.

**Phase 5 — Files and photos**
15. Nextcloud + its database deployed, data directory on
    `<bulk>/files/nextcloud`. Disable Nextcloud's built-in photo/gallery
    app — Immich is the sole photo path, to avoid storing the same images
    twice.
16. Immich (server + its database/cache dependencies) deployed, library on
    `<bulk>/photos/immich`. Install its mobile app on personal devices and
    verify automatic backup of a test photo over the remote-access mesh.

**Phase 6 — Security and network**
17. Vaultwarden deployed. Install a Bitwarden-compatible client on personal
    devices, point it at Vaultwarden's URL, and import any existing
    password vault.
18. AdGuard Home deployed. Point your network's DNS (router-level, or
    per-device) at it. Verify blocking on at least one real device.

**Phase 7 — Operations**
19. Backup tool deployed. Configure jobs specifically for the data that is
    *not* re-obtainable elsewhere: Immich's library + database, Nextcloud's
    data + database, Vaultwarden's data folder. Target a destination
    physically or logically separate from the redundant storage volume
    (cloud object storage, or a separate physical drive) — redundancy
    protects against drive failure, not deletion, corruption, or
    ransomware. Run each job at least once and confirm success.
20. Uptime monitor deployed. Add a check per service (via the reverse
    proxy's hostnames), configure a notification channel, and confirm a
    manual downtime test triggers an alert.

**Phase 8 — Ready for future projects**
21. Confirm the repeatable pattern for adding a new self-built app: give it
    its own compose file under the shared compose directory, join it to
    the shared internal network, add one reverse-proxy site entry, add one
    uptime-monitor check. No structural change to the rest of the stack is
    required per new app.

## 5. Verification checklist

- [ ] Redundant volume reports healthy, no degraded members
- [ ] Every service reachable by hostname through the reverse proxy over
      the remote-access mesh
- [ ] Media request flow works end-to-end (Overseerr → Sonarr/Radarr →
      download client → Plex)
- [ ] Audiobook request flow works end-to-end (AudiobookRequest → Readarr →
      download client → Audiobookshelf)
- [ ] Immich mobile app auto-backs-up a test photo
- [ ] Nextcloud's photo/gallery module is disabled
- [ ] Vaultwarden reachable from a client app, existing vault imported
- [ ] AdGuard Home actively blocking on a real device
- [ ] Backup tool has at least one successful run for Immich, Nextcloud,
      and Vaultwarden data
- [ ] Uptime monitor shows all services healthy, and a manual downtime test
      produces a notification

## 6. Explicitly out of scope

- Single sign-on across services — revisit only once the stack is stable
  and login fatigue becomes a real friction point.
- Any public (non-mesh) exposure of a service — everything stays reachable
  only over the remote-access mesh by default; a public-facing path is
  added deliberately, per-service, only if a specific need arises (e.g.
  sharing a request app with someone outside the mesh).
