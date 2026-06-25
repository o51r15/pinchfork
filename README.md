> **This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat).** The upstream project entered a development pause in September 2025. This fork continues active development with a focus on backend stability and operational improvements. See the [Fork Changes](#fork-changes) section for details.

[![License](https://img.shields.io/badge/license-AGPL--3.0-ee512b?style=for-the-badge)](https://github.com/o51r15/pinchflat/blob/master/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/o51r15/pinchflat?style=for-the-badge&color=purple)](https://github.com/o51r15/pinchflat/releases)

# Pinchfork

## Table of contents

- [Fork Changes](#fork-changes)
- [Roadmap](#roadmap)
- [What it does](#what-it-does)
- [Features](#features)
- [Installation](#installation)
  - [Docker Compose (with Postgres)](#docker-compose-with-postgres)
  - [Environment Variables](#environment-variables)
  - [Reverse Proxies](#reverse-proxies)
- [Upstream documentation](#upstream-documentation)
- [Configuration Differences from Upstream](#configuration-differences-from-upstream)
- [Contributors](#contributors)
- [License](#license)

---

> ⚠️ **Playlist support is currently inconsistent.** Playlists may fail to download media, fail to fetch metadata, or behave unpredictably depending on the deployment. Channel URLs are recommended. Playlist support is being actively investigated.

> ⚠️ **ARM hardware (Raspberry Pi) is unsupported.** Pinchfork runs on Pi hardware but there are known architecture-specific bugs with yt-dlp source type detection and YouTube authentication. Use on Pi at your own risk. Issues specific to ARM are low priority and may not be fixed.

---

## Fork Changes

See [Fork Changes](https://github.com/o51r15/pinchfork/wiki/Fork-Changes) on the wiki for a full breakdown of how this fork differs from upstream Pinchflat.

---

## Roadmap

See the [Roadmap](https://github.com/o51r15/pinchfork/wiki/Roadmap) on the wiki for planned features and known bugs.

---

## What it does

Pinchflat is a self-hosted app for downloading YouTube content built using [yt-dlp](https://github.com/yt-dlp/yt-dlp). It's designed to be lightweight, self-contained, and easy to use. You set up rules for how to download content from YouTube channels or playlists and it'll do the rest, periodically checking for new content. It's perfect for people who want to download content for use with a media center app (Plex, Jellyfin, Kodi) or for those who want to archive media.

While you can download individual videos, Pinchflat is best suited for downloading content from channels or playlists. It's also not meant for consuming content in-app — Pinchflat downloads content to disk where you can then watch it with a media center app or VLC.

---

## Features

- Powerful naming system so content is stored where and how you want it
- Easy-to-use web interface with presets to get you started right away
- Sonarr-style UI — source grid, fanart banners, year-grouped episode lists, activity page
- First-class support for media center apps like Plex, Jellyfin, and Kodi
- Supports serving RSS feeds to your favourite podcast app
- Automatically downloads new content from channels and playlists
- Source type selector — specify Channel or Playlist to override unreliable auto-detection
- Source metadata editor — edit name and description with lock toggles; upload a custom poster
- Content availability filtering — independently control public and members-only video downloads
- Supports downloading audio content
- Custom rules for handling YouTube Shorts and livestreams
- Apprise support for notifications
- Allows automatically redownloading new media after a set period
- Optionally automatically delete old content
- Advanced options like setting cutoff dates and filtering by title
- Can pass cookies to YouTube to download private playlists and members-only content
- Per-source cookie behaviour and video client override for SABR bypass
- PO token support via bgutil sidecar for reliable YouTube access
- SponsorBlock integration
- Custom `yt-dlp` options support
- Custom lifecycle scripts (alpha)
- **PostgreSQL backend** for reliable concurrent job processing

---

## Installation

### Docker Compose (with Postgres)

This fork requires a Postgres container alongside the app. Pre-built images are available on GHCR — no local build required.

**Create your docker-compose file.** Replace paths and password as needed:

```yaml
services:
  pinchflat-db:
    container_name: pinchflat-db
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: pinchflat
      POSTGRES_PASSWORD: your_password_here
      POSTGRES_DB: pinchflat
    volumes:
      - pinchflat_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pinchflat"]
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
      - POOL_SIZE=10
    ports:
      - "8945:8945"
    volumes:
      - /path/to/config:/config
      - /path/to/downloads:/downloads

volumes:
  pinchflat_pgdata:
```

**Start:**

```bash
docker compose -f /path/to/your/docker-compose.yml up -d
```

Migrations run automatically at startup. The app will be available at `http://your-server:8945`.

> **Updating:** Pull the latest image and recreate the container: `docker compose pull && docker compose up -d`

### Environment Variables

| Name | Required? | Default | Notes |
| --- | --- | --- | --- |
| `DATABASE_URL` | **Yes** | — | Postgres connection string: `ecto://user:pass@host/db` |
| `TZ` | No | `UTC` | Must follow IANA TZ format |
| `POOL_SIZE` | No | `10` | Postgres connection pool size |
| `LOG_LEVEL` | No | `debug` | Can be set to `info` |
| `UMASK` | No | `022` | Unraid users may want `000` |
| `BASIC_AUTH_USERNAME` | No | — | Enables basic auth when both username and password are set |
| `BASIC_AUTH_PASSWORD` | No | — | Enables basic auth when both username and password are set |
| `EXPOSE_FEED_ENDPOINTS` | No | `false` | See RSS feed docs |
| `ENABLE_IPV6` | No | `false` | Set to any non-blank value to enable |
| `TZ_DATA_DIR` | No | `/etc/elixir_tzdata_data` | Container path for timezone database |
| `BASE_ROUTE_PATH` | No | `/` | Base path for reverse proxy subdirectory deployments |
| `YT_DLP_WORKER_CONCURRENCY` | No | `2` | yt-dlp workers per queue. Set to `1` if getting IP limited |
| `YT_DLP_VERSION` | No | `stable` | yt-dlp update behavior: `stable`, `nightly`, `master`, `pinned`/`none` to disable, or a specific version like `2025.12.08` |
| `ENABLE_PROMETHEUS` | No | `false` | Set to any non-blank value to enable |

### Reverse Proxies

Pinchflat makes heavy use of websockets for real-time updates. Ensure your reverse proxy is configured to support websockets.

---

## Configuration Differences from Upstream

For a full breakdown of env vars added/removed, new source and media item fields, and Oban behavior changes, see [Fork Changes — Configuration differences from upstream](https://github.com/o51r15/pinchfork/wiki/Fork-Changes#configuration-differences-from-upstream) on the wiki.

---

## Upstream documentation

The [upstream wiki](https://github.com/kieraneglin/pinchflat/wiki) covers features that have not changed in this fork: media profiles, SponsorBlock, RSS feeds, Apprise notifications, lifecycle scripts, and Jellyfin/Plex/Kodi setup. For anything related to the UI, source management, or features added in this fork, refer to the [Pinchfork wiki](https://github.com/o51r15/pinchfork/wiki) instead.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Contributed several improvements that were submitted as open PRs to the upstream project but not yet merged. Their work on the Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing has been incorporated into this fork with attribution.

---

## License

See `LICENSE` file. This fork is also licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin).
