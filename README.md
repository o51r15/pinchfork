<div align="center">

# Pinchfork

**Self-hosted YouTube media manager — download, organize, and serve your library.**

A PostgreSQL-backed fork of [Pinchflat](https://github.com/kieraneglin/pinchflat) with continued active development focused on backend stability, operational improvements, and new features.

[![GitHub last commit](https://img.shields.io/github/last-commit/o51r15/pinchfork)](https://github.com/o51r15/pinchfork)
[![Latest Release](https://img.shields.io/github/v/release/o51r15/pinchfork?color=purple)](https://github.com/o51r15/pinchfork/releases)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-ee512b.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-1.17%2B-purple.svg)](https://elixir-lang.org/)

</div>

---

> **Active fork** — the upstream project entered a development pause in September 2025. This fork continues with new features, bug fixes, and infrastructure improvements. See the [Fork Changes](https://github.com/o51r15/pinchfork/wiki/Fork-Changes) wiki page for a full breakdown.

## What It Does

Pinchfork downloads YouTube content via [yt-dlp](https://github.com/yt-dlp/yt-dlp) on a schedule. You set up rules for channels or playlists — it handles the rest, periodically checking for new content and organizing downloads for use with media center apps (Plex, Jellyfin, Kodi) or direct playback.

Unlike one-off downloaders, Pinchfork is designed for ongoing library management: automatic re-downloads, content aging policies, quality upgrades, and a Sonarr-style UI for browsing your collection.

## Features

- **Sonarr-Style UI** — source grid with fanart banners, year-grouped episode lists, activity page
- **Channel Discovery** — find new channels based on your existing library using heuristic scanning, with daily auto-scan and a dedicated Discovery page
- **PostgreSQL Backend** — reliable concurrent job processing via Oban Pro
- **Powerful Naming** — flexible templates so content is stored where and how you want it
- **Media Center Integration** — first-class support for Plex, Jellyfin, and Kodi
- **RSS Feeds** — serve sources to your favourite podcast app
- **Source Metadata Editor** — edit name and description with lock toggles; upload custom posters
- **Content Availability Filtering** — independently control public and members-only video downloads
- **YouTube Shorts & Livestreams** — custom rules for each
- **Apprise Notifications** — alerts via Discord, Gotify, Telegram, email, and 80+ services
- **Auto Re-download** — periodically re-download media for quality upgrades
- **Content Aging** — optionally delete old content automatically
- **Cookie Support** — pass cookies for private playlists and members-only content
- **PO Token Support** — bgutil sidecar for reliable YouTube access
- **SponsorBlock** — skip or remove sponsor segments
- **Custom yt-dlp Options** — pass any yt-dlp flag per source
- **Custom Lifecycle Scripts** — hook into download events (alpha)
- **Per-Source Client Override** — cookie behaviour and video client override for SABR bypass

## Quick Start

### Docker Compose (recommended)

```bash
# 1. Create your compose file
mkdir -p ~/pinchfork
curl -o ~/pinchfork/docker-compose.yml \
  https://raw.githubusercontent.com/o51r15/pinchfork/master/docker-compose.example.yml

# 2. Edit docker-compose.yml — set your paths and Postgres password
nano ~/pinchfork/docker-compose.yml

# 3. Run
docker compose -f ~/pinchfork/docker-compose.yml up -d
```

Dashboard: **http://localhost:8945**

Migrations run automatically at startup. The stack includes Postgres 16 and the bgutil PO token provider.

> **Updating:** `docker compose pull && docker compose up -d`

### Docker Compose File

```yaml
services:
  pinchflat-db:
    container_name: pinchflat-db
    image: postgres:16-alpine
    restart: unless-stopped
    environment:      POSTGRES_USER: pinchflat
      POSTGRES_PASSWORD: your_password_here
      POSTGRES_DB: pinchflat
    volumes:
      - pinchflat_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U pinchflat']
      interval: 10s
      timeout: 5s
      retries: 5

  bgutil-provider:
    container_name: bgutil-provider
    image: brainicism/bgutil-ytdlp-pot-provider:latest
    restart: unless-stopped

  pinchflat:
    container_name: pinchflat
    image: ghcr.io/o51r15/pinchfork:latest
    restart: unless-stopped
    depends_on:
      pinchflat-db:
        condition: service_healthy
      bgutil-provider:
        condition: service_started
    environment:
      - TZ=America/New_York
      - DATABASE_URL=ecto://pinchflat:your_password_here@pinchflat-db/pinchflat
      - POOL_SIZE=10    ports:
      - '8945:8945'
    volumes:
      - /path/to/config:/config
      - /path/to/downloads:/downloads

volumes:
  pinchflat_pgdata:
```

## Configuration

| Setting                     | Required | Default  | Description                                                         |
| --------------------------- | -------- | -------- | ------------------------------------------------------------------- |
| `DATABASE_URL`              | **Yes**  | —        | Postgres connection string: `ecto://user:pass@host/db`              |
| `TZ`                        | No       | `UTC`    | IANA timezone format                                                |
| `POOL_SIZE`                 | No       | `10`     | Postgres connection pool size                                       |
| `LOG_LEVEL`                 | No       | `debug`  | `debug` or `info`                                                   |
| `UMASK`                     | No       | `022`    | Unraid users may want `000`                                         |
| `BASIC_AUTH_USERNAME`       | No       | —        | Enables basic auth (both username and password required)            |
| `BASIC_AUTH_PASSWORD`       | No       | —        | Enables basic auth (both username and password required)            |
| `EXPOSE_FEED_ENDPOINTS`     | No       | `false`  | Enable RSS feed endpoints                                           |
| `ENABLE_IPV6`               | No       | `false`  | Any non-blank value enables                                         |
| `BASE_ROUTE_PATH`           | No       | `/`      | Base path for reverse proxy subdirectory deployments                |
| `YT_DLP_WORKER_CONCURRENCY` | No       | `2`      | yt-dlp workers per queue. Set to `1` if getting IP limited          |
| `YT_DLP_VERSION`            | No       | `stable` | `stable`, `nightly`, `master`, `pinned`/`none`, or specific version |
| `ENABLE_PROMETHEUS`         | No       | `false`  | Any non-blank value enables                                         |

For a full breakdown of env vars added/removed and Oban behavior changes, see [Fork Changes — Configuration differences from upstream](https://github.com/o51r15/pinchfork/wiki/Fork-Changes#configuration-differences-from-upstream) on the wiki.

> **Reverse proxies:** Pinchfork makes heavy use of websockets for real-time updates. Ensure your reverse proxy is configured to support websockets.

## Roadmap

See the [Roadmap](https://github.com/o51r15/pinchfork/wiki/Roadmap) on the wiki for planned features and known bugs.

## Documentation

- [Fork Changes](https://github.com/o51r15/pinchfork/wiki/Fork-Changes) — full breakdown of differences from upstream
- [Discovery](https://github.com/o51r15/pinchfork/wiki/Discovery) — channel discovery feature guide
- [Roadmap](https://github.com/o51r15/pinchfork/wiki/Roadmap) — planned features and version targets
- [Upstream Wiki](https://github.com/kieraneglin/pinchflat/wiki) — media profiles, SponsorBlock, RSS feeds, Apprise, lifecycle scripts, Jellyfin/Plex/Kodi setup

## Requirements

- Docker host with Docker Compose
- ~1GB RAM for the app + Postgres
- Storage for downloaded media

## Tech Stack

Elixir 1.17+, Phoenix/LiveView, Ecto, Oban Pro, PostgreSQL 16, yt-dlp, Alpine (Docker)

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing. Contributed as open PRs to upstream; incorporated here with attribution.

## License

[AGPL-3.0](LICENSE) — Original project by [kieraneglin](https://github.com/kieraneglin).
