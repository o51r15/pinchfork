> **This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat).** The upstream project entered a development pause in September 2025. This fork continues active development with a focus on backend stability and operational improvements.

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

Pinchfork is a self-hosted app for downloading YouTube content built using [yt-dlp](https://github.com/yt-dlp/yt-dlp). You set up rules for how to download content from YouTube channels or playlists and it checks periodically for new content. It's designed for use with a media center app (Plex, Jellyfin, Kodi) or for archiving media.

While you can download individual videos, Pinchfork is best suited for downloading large amounts of content from channels or playlists. It's not meant for consuming content in-app — it downloads to disk for use with a media player.

---

## Features

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
- **PostgreSQL backend** for reliable concurrent job processing
- **SABR bypass** and **PO Token support** for clean YouTube downloads
- **Local temp staging** for network-mount download directories

---

## Why this fork exists

The original Pinchflat uses SQLite with Oban's SQLite engine. Under load this causes write contention, query timeouts, and crash loops as the library grows. Pinchfork replaces the backend with PostgreSQL and Oban's native Postgres engine, which handles concurrent job queues correctly without file locking issues.

Everything else — the UI, yt-dlp integration, media profiles, sources, media center support, SponsorBlock, RSS feeds, Apprise, and lifecycle scripts — is unchanged. This is purely a backend infrastructure change with several quality-of-life additions on top.

For full technical details and migration guidance from upstream, see [Configuration Differences from Upstream](https://github.com/o51r15/pinchfork/wiki/Configuration-Differences).

---

## Roadmap

- [x] **v0.1.0** — PostgreSQL backend, Oban Basic engine, full-text search via `tsvector`
- [x] **Source-level content availability filtering** — per-source controls for public vs. members-only content
- [x] **Error classification** — permanent vs. transient failure detection; auto-prevents retry on permanent errors
- [x] **SABR bypass / PO Token provider** — per-source Video Client override + bgutil sidecar support. See [SABR Bypass and PO Tokens](https://github.com/o51r15/pinchfork/wiki/SABR-Bypass-and-PO-Tokens)
- [x] **Local temp staging** — `LOCALTEMP` env var for network-mount downloads. See [Local Temp Staging](https://github.com/o51r15/pinchfork/wiki/Local-Temp-Staging)
- [x] **v0.3.0** — per-item staging cleanup, Pending/Retry/Failed tab split with live retry countdown
- [x] **Oban Lifeline** — auto-rescues stuck jobs after crash or restart *(credit: [ddacunha](https://github.com/ddacunha))*
- [x] **yt-dlp version management** — `YT_DLP_VERSION` env var *(credit: [ddacunha](https://github.com/ddacunha))*
- [x] **Download prevention reason tracking** — `download_prevented_reason` field surfaced on media-item page
- [x] **v0.3.1** — bgutil plugin baked into image (one-and-done sidecar setup), fail-open plugin dir fix
- [x] **YouTube API key tester** — one-click validation in Settings *(credit: [ddacunha](https://github.com/ddacunha))*
- [ ] **Queue diagnostics page** — Oban queue health, stuck job detection, bulk actions *(credit: [ddacunha](https://github.com/ddacunha))*

---

## Installation

Pinchfork requires a PostgreSQL container. A PO Token sidecar is strongly recommended.

**Image:** `ghcr.io/o51r15/pinchfork:latest` (or pin a version: `:v0.3.1`)

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
      - TZ=America/New_York
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

For base feature documentation (media profiles, sources, Jellyfin/Plex setup, cookies, SponsorBlock, RSS feeds, lifecycle scripts), the [upstream Pinchflat wiki](https://github.com/kieraneglin/pinchflat/wiki) remains accurate — only installation, the database backend, and the fork-specific features documented above differ.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing. Submitted as upstream PRs [#857](https://github.com/kieraneglin/pinchflat/pull/857), [#858](https://github.com/kieraneglin/pinchflat/pull/858), [#859](https://github.com/kieraneglin/pinchflat/pull/859), [#860](https://github.com/kieraneglin/pinchflat/pull/860).

---

## License

See `LICENSE` file. Licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin). Logo by [@hernandito](https://github.com/hernandito).
