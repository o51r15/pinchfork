> **This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat).** The upstream project entered a development pause in September 2025. This fork continues active development with a focus on backend stability, operational improvements, and continued feature development.

[![License](https://img.shields.io/badge/license-AGPL--3.0-ee512b?style=for-the-badge)](https://github.com/o51r15/pinchfork/blob/master/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/o51r15/pinchfork?style=for-the-badge&color=purple)](https://github.com/o51r15/pinchfork/releases)

# Pinchfork

<p align="center">
  <img src="priv/static/images/pinchfork-logo.png" alt="Pinchfork" width="512">
</p>

*a fork of [Pinchflat](https://github.com/kieraneglin/pinchflat)*

> **A note on naming:** **Pinchfork** is this project — the active PostgreSQL fork. **Pinchflat** is the upstream project it was forked from. A few low-level identifiers (the database container, DB user, and `DATABASE_URL` segments) keep the `pinchflat` name because they are inherited from the upstream-derived image — renaming them breaks existing deployments.

## Table of contents

- [What it does](#what-it-does)
- [Features](#features)
- [Why this fork exists](#why-this-fork-exists)
- [Roadmap](#roadmap)
- [Installation](#installation)
- [Environment Variables](#environment-variables)
- [Documentation](#documentation)
- [Contributors](#contributors)
- [License](#license)

---

## What it does

Pinchfork is a self-hosted app for downloading YouTube content built using [yt-dlp](https://github.com/yt-dlp/yt-dlp). You set up rules for how to download content from YouTube channels or playlists and it checks periodically for new content. It's designed to handle large, growing libraries reliably over time — for use with a media center app (Plex, Jellyfin, Kodi) or for archiving media.

While you can download individual videos, Pinchfork is best suited for downloading content from channels or playlists at scale. It downloads to disk for use with a media player rather than streaming in-app.

---

## Features

### Inherited from upstream

- Powerful naming system so content is stored where and how you want it
- Easy-to-use web interface with presets to get you started
- First-class support for Plex, Jellyfin, and Kodi
- RSS feeds for podcast apps
- Automatically downloads new content from channels and playlists
- Audio-only download support
- Custom rules for Shorts and livestreams
- Apprise notifications
- Automatic media redownload after a set period
- Optional automatic deletion of old content
- Cutoff dates and title regex filtering
- Cookie support for private playlists and members-only content
- SponsorBlock integration
- Custom `yt-dlp` options and lifecycle scripts

### Pinchfork additions

- **PostgreSQL backend** — replaces SQLite; eliminates write contention and crash loops under load
- **Redesigned home page** — Pending/Retry/Failed tab split with live retry countdown and Retry Now / Force Retry actions
- **Content availability filtering** — per-source controls for public vs. members-only content; `availability` field captured at index time
- **Error classification** — permanent vs. transient failure detection; permanently failed items stop consuming retry cycles automatically. `download_prevented_reason` field explains why a download was blocked
- **SABR bypass and PO Token support** — per-source Video Client override to work around SABR-corrupted downloads; bgutil POT provider plugin baked into the image for one-and-done sidecar setup. See [SABR Bypass and PO Tokens](https://github.com/o51r15/pinchfork/wiki/SABR-Bypass-and-PO-Tokens)
- **Local temp staging** — `LOCALTEMP` env var stages all yt-dlp intermediate work on a local disk and moves only finished files to the (possibly network-mounted) downloads directory. See [Local Temp Staging](https://github.com/o51r15/pinchfork/wiki/Local-Temp-Staging)
- **yt-dlp version management** — `YT_DLP_VERSION` env var controls update behavior: pin to a specific version, disable updates, or track nightly/master builds
- **Oban Lifeline** — automatically rescues jobs stuck in `executing` state after a crash or container restart
- **YouTube API key tester** — one-click validation in Settings, no log-diving required
- **Per-item staging cleanup** — failed or abandoned downloads clean up their own staging files automatically

---

## Why this fork exists

The original Pinchflat uses SQLite with Oban's SQLite engine. Under load this causes write contention, query timeouts, and crash loops as the library grows. Pinchfork replaces the backend with PostgreSQL and Oban's native Postgres engine, which handles concurrent job queues correctly without file locking issues.

The core feature set — media profiles, sources, media center support, SponsorBlock, RSS feeds, Apprise, and lifecycle scripts — carries over from upstream unchanged. On top of the backend port, Pinchfork adds several UI and operational improvements: content availability filtering per source, permanent vs. transient error classification, SABR bypass and PO Token support, local temp staging for network mounts, a redesigned home page with Pending/Retry/Failed tabs and live retry counters, per-item staging cleanup, yt-dlp version management, and the bgutil plugin baked into the image.

For full technical details and migration guidance from upstream, see [Configuration Differences from Upstream](https://github.com/o51r15/pinchfork/wiki/Configuration-Differences).

---

## Roadmap

**v0.1.0**
- [x] PostgreSQL backend, Oban Basic engine, full-text search via `tsvector`

**v0.2.x**
- [x] Source-level content availability filtering — per-source controls for public vs. members-only content; `availability` field captured at index time
- [x] Error classification — permanent vs. transient failure detection; permanently failed items auto-set `prevent_download: true` and stop consuming retry cycles
- [x] SABR bypass / PO Token provider — per-source Video Client override + bgutil sidecar support. See [SABR Bypass and PO Tokens](https://github.com/o51r15/pinchfork/wiki/SABR-Bypass-and-PO-Tokens)
- [x] Local temp staging — `LOCALTEMP` env var for network-mount downloads. See [Local Temp Staging](https://github.com/o51r15/pinchfork/wiki/Local-Temp-Staging)
- [x] Full-text search hardening — `build_tsquery` hardened against edge-case input, FTS config switched to `simple` for multilingual library support, search trigger guard added
- [x] Source form reorganization — Download Media / Content Availability / Cookie Behaviour / Video Client grouping; Fast Indexing help card made collapsible
- [x] Oban Lifeline — auto-rescues stuck jobs after crash or restart *(credit: [ddacunha](https://github.com/ddacunha))*
- [x] yt-dlp version management — `YT_DLP_VERSION` env var *(credit: [ddacunha](https://github.com/ddacunha))*
- [x] YouTube API key tester — one-click validation in Settings *(credit: [ddacunha](https://github.com/ddacunha))*

**v0.3.0**
- [x] Per-item staging cleanup — each download isolated under its own staging dir; orphans auto-cleaned on failure, restart, and success
- [x] Pending/Retry/Failed tab split — redesigned home page with live retry countdown and Retry Now / Force Retry actions

**v0.3.1**
- [x] bgutil plugin baked into image — one-and-done sidecar setup, no manual plugin mount
- [x] Fail-open plugin dir fix — a missing or empty plugin directory can no longer break yt-dlp on a fresh install
- [x] Download prevention reason tracking — `download_prevented_reason` field surfaced on media-item page

**v0.3.2**
- [x] Oban priority constraint fix — widened `priority_range` to `0–9` via Oban schema migration v12; fixes downloads silently never starting on fresh deployments (Pi4, Windows, clean server)
- [x] Dockerfile and GitHub Actions workflow committed to repository — `ghcr.io/o51r15/pinchfork` now built and published automatically on tag push
- [x] bgutil plugin path fix — corrected Dockerfile extraction path for `bgutil-ytdlp-pot-provider` v1.3.1 zip structure change

**Upcoming**
- [ ] SQLite→PostgreSQL migration tool — `mix pinchflat.migrate_sqlite` task to migrate an existing Pinchflat SQLite database to Pinchfork's PostgreSQL schema; adoption path for current Pinchflat users
- [ ] UI filtering by availability and error type — filter media items by `availability` and `error_type` with shareable URL params
- [ ] Enriched notification payloads — structured error data in Apprise/webhook notifications
- [ ] PO Token / Visitor Data support — yt-dlp extractor args for tokens treated as sensitive credentials (encrypted at rest, never logged)
- [ ] Media profile path UX — display output path template outside the edit form, show effective path on source overview pages, add Reset to preset button
- [ ] Queue diagnostics page — Oban queue health, stuck job detection, bulk reset/cancel actions *(credit: [ddacunha](https://github.com/ddacunha))*

---

## Installation

Pinchfork requires a PostgreSQL container. A PO Token sidecar is strongly recommended.

**Image:** `ghcr.io/o51r15/pinchfork:latest` (or pin a version: `:v0.3.2`)

A complete annotated compose file is in the repo at [`docker-compose.sample.yml`](docker-compose.sample.yml). Minimal setup:

```yaml
services:
  bgutil-provider:
    container_name: bgutil-provider
    image: brainicism/bgutil-ytdlp-pot-provider:1.3.1
    restart: unless-stopped

  pinchfork-db:
    container_name: pinchfork-db
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: pinchflat        # inherited — do not rename
      POSTGRES_PASSWORD: changeme     # must match DATABASE_URL below
      POSTGRES_DB: pinchflat          # inherited — do not rename
    volumes:
      - pinchfork_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pinchflat"]
      interval: 10s
      timeout: 5s
      retries: 5

  pinchfork:
    container_name: pinchfork
    image: ghcr.io/o51r15/pinchfork:latest
    restart: unless-stopped
    depends_on:
      pinchfork-db:
        condition: service_healthy
      bgutil-provider:
        condition: service_started
    environment:
      - TZ=America/New_York  # set your timezone (IANA format)
      - DATABASE_URL=ecto://pinchflat:changeme@pinchfork-db/pinchflat
      - POOL_SIZE=10
    ports:
      - "8945:8945"
    volumes:
      - /path/to/config:/config
      - /path/to/downloads:/downloads

volumes:
  pinchfork_pgdata:
```

Start: `docker compose up -d`

Update: `docker compose pull && docker compose up -d`

For the full installation guide including environment variables, file permissions, and network-mount setup, see the [Installation wiki page](https://github.com/o51r15/pinchfork/wiki/Installation).

---

## Environment Variables

| Name | Required? | Default | Notes |
|---|---|---|---|
| `DATABASE_URL` | **Yes** | — | `ecto://user:pass@host/db` |
| `TZ` | No | `UTC` | IANA timezone format |
| `POOL_SIZE` | No | `10` | Postgres connection pool size |
| `LOG_LEVEL` | No | `debug` | Set to `info` to reduce noise |
| `UMASK` | No | `022` | Unraid users may want `000` |
| `BASIC_AUTH_USERNAME` | No | — | Enables basic auth when both are set |
| `BASIC_AUTH_PASSWORD` | No | — | Enables basic auth when both are set |
| `EXPOSE_FEED_ENDPOINTS` | No | — | Exposes RSS/streaming routes outside basic auth |
| `ENABLE_IPV6` | No | — | Set to any non-blank value to enable |
| `BASE_ROUTE_PATH` | No | `/` | For reverse proxy subdirectory deployments |
| `YT_DLP_WORKER_CONCURRENCY` | No | `2` | Lower to `1` if getting IP rate limited |
| `YT_DLP_VERSION` | No | `stable` | `stable`, `nightly`, `master`, `pinned`/`none`, or a version like `2025.12.08` |
| `ENABLE_PROMETHEUS` | No | — | Set to any non-blank value to enable |
| `LOCALTEMP` | No | — | Stage downloads locally for network-mount `/downloads`. See [Local Temp Staging](https://github.com/o51r15/pinchfork/wiki/Local-Temp-Staging) |

---

## Documentation

**Pinchfork wiki:** https://github.com/o51r15/pinchfork/wiki

Key pages:
- [Installation](https://github.com/o51r15/pinchfork/wiki/Installation) — full setup guide
- [SABR Bypass and PO Tokens](https://github.com/o51r15/pinchfork/wiki/SABR-Bypass-and-PO-Tokens) — working around corrupt downloads
- [Local Temp Staging](https://github.com/o51r15/pinchfork/wiki/Local-Temp-Staging) — network-mount download setup
- [Configuration Differences](https://github.com/o51r15/pinchfork/wiki/Configuration-Differences) — migrating from upstream Pinchflat
- [FAQ](https://github.com/o51r15/pinchfork/wiki/FAQ) — common questions

For topics not yet covered in the Pinchfork wiki, the [upstream Pinchflat wiki](https://github.com/kieraneglin/pinchflat/wiki) remains accurate for base features (media profiles, sources, Jellyfin/Plex setup, SponsorBlock, lifecycle scripts) — only installation, the database backend, and the fork-specific additions differ.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing. Submitted as upstream PRs [#857](https://github.com/kieraneglin/pinchflat/pull/857), [#858](https://github.com/kieraneglin/pinchflat/pull/858), [#859](https://github.com/kieraneglin/pinchflat/pull/859), [#860](https://github.com/kieraneglin/pinchflat/pull/860).

---

## License

See `LICENSE` file. Licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin). Logo by [@hernandito](https://github.com/hernandito).
