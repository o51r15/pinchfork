> **This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat).** The upstream project entered a development pause in September 2025. This fork continues active development with a focus on backend stability and operational improvements. See the [Fork Changes](#fork-changes) section for details.

[![License](https://img.shields.io/badge/license-AGPL--3.0-ee512b?style=for-the-badge)](https://github.com/o51r15/pinchflat/blob/master/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/o51r15/pinchflat?style=for-the-badge&color=purple)](https://github.com/o51r15/pinchflat/releases)

# Pinchflat (o51r15 fork)

*logo by [@hernandito](https://github.com/hernandito)*

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

What started as a targeted database swap has grown into a substantial independent rewrite. The fork now diverges from upstream across the backend, UI, and feature set.

### PostgreSQL backend (replaces SQLite)

The original Pinchflat uses SQLite as its database. This fork replaces it with PostgreSQL. The motivation:

- SQLite + Oban (the background job library) is a structural mismatch. Oban was built for Postgres and the SQLite adapter causes write contention under load, query timeouts, and crash loops as library size grows.
- Postgres handles concurrent job queues (indexing, downloading, metadata, file sync) correctly and without file locking issues.
- The `JOURNAL_MODE` workaround for network shares is no longer needed.

**What changed in the code:**

- `ecto_sqlite3` dependency replaced with `postgrex`
- Oban engine changed from `Lite` (SQLite-only) to `Basic` (Postgres native)
- SQLite-specific SQL in queries and migrations replaced with Postgres equivalents (`IFNULL` → `COALESCE`, `DATETIME()` → interval arithmetic, `date()` → `::date` cast, `regexp_like` → `~`)
- Full-text search migrated from SQLite FTS5 virtual table to Postgres `tsvector` with a GIN index and trigger-maintained updates
- Deployment requires a Postgres sidecar container (see installation below)

### UI overhaul (Sonarr-style)

The upstream UI has been significantly redesigned:

- Source library displays as a poster card grid with download progress bars and one-click monitored toggles
- Source detail pages use a fanart banner, poster overlay, and granular stats bar (Downloaded / Pending / Failed / Prevented / Skipped)
- Horizontal action bar replaces the dropdown menu
- Episode list groups by year with collapsible sections, per-item status badges, and monitored toggles
- Dedicated Activity page replaces the cluttered home dashboard
- System Status page shows Pinchfork version, yt-dlp version, PostgreSQL stats, Oban queue health, and live PO token server status

### Source management

- **Source type selector** — Channel vs Playlist is now user-selectable on the new source form, overriding yt-dlp's auto-detection which can be unreliable on some architectures
- **Metadata editor** — Edit source name and description directly with per-field lock toggles to prevent metadata refreshes from overwriting your changes; upload or link a custom poster image
- **Content availability filtering** — Per-source controls for public videos and members-only videos independently
- **Cookie behaviour per source** — Granular control over when cookies are used (disabled / when needed / all operations)
- **Video client override** — Select the yt-dlp player client per source to bypass SABR or work around authentication issues
- **Download cutoff date presets** — Quick-select common date offsets alongside the manual date field

### Media tracking

- **Error classification** — `error_type` field distinguishes permanent failures (members-only, unavailable, geo-blocked) from transient ones (network errors, rate limits). Permanent failures automatically set `prevent_download: true`.
- **Prevention reason tracking** — `download_prevented_reason` field distinguishes manual prevention, policy blocks, and error-stops so re-indexing doesn't accidentally re-enable intentionally blocked items

### yt-dlp and reliability

- **PO token support** — Integration with the bgutil sidecar for YouTube PO token generation. Required for reliable downloads on some content.
- **SABR bypass** — Video client selector allows routing around SABR-corrupted downloads
- **yt-dlp version management** — `YT_DLP_VERSION` env var controls update behavior: `stable`, `nightly`, `master`, `pinned`/`none`, or a specific version string
- **Oban Lifeline plugin** — Rescues jobs stuck in `executing` state after a crash or container restart, automatically re-queuing them after 30 minutes
- **Metadata reliability fixes** — Scoped yt-dlp output template prevents multi-MB JSON truncation on resource-constrained hosts; graceful error handling prevents metadata failures from causing noisy Oban retries

### Additional features

- **YouTube API key tester** — One-click validation from the Settings page
- **Local temp staging** — Downloads can stage to a local path before moving to a network share, eliminating partial-file issues on slow mounts

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
- First-class support for media center apps like Plex, Jellyfin, and Kodi
- Supports serving RSS feeds to your favourite podcast app
- Automatically downloads new content from channels and playlists
- Supports downloading audio content
- Custom rules for handling YouTube Shorts and livestreams
- Apprise support for notifications
- Allows automatically redownloading new media after a set period
- Optionally automatically delete old content
- Advanced options like setting cutoff dates and filtering by title
- Can pass cookies to YouTube to download private playlists
- SponsorBlock integration
- Custom `yt-dlp` options support
- Custom lifecycle scripts (alpha)
- **PostgreSQL backend** for reliable concurrent job processing

---

## Installation

### Docker Compose (with Postgres)

This fork requires a Postgres container alongside the app. A ready-to-use compose file is provided. You will need to build the image locally from this repository.

**Step 1 — Clone this repo on your server:**

```bash
git clone https://github.com/o51r15/pinchflat.git /opt/pinchflat-fork
```

**Step 2 — Create your docker-compose file.** Replace paths and password as needed:

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

  pinchflat:
    container_name: pinchflat
    build:
      context: /opt/pinchflat-fork
      dockerfile: docker/selfhosted.Dockerfile
    restart: unless-stopped
    depends_on:
      pinchflat-db:
        condition: service_healthy
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

**Step 3 — Build and start:**

```bash
docker compose -f /path/to/your/docker-compose.yml up -d --build
```

The first build will take several minutes. Migrations run automatically at startup. The app will be available at `http://your-server:8945`.

> **Note:** The `--build` flag is required on first run and after any code changes. The Elixir release is compiled into the image.

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

This fork introduces configuration options and behaviors that differ from or extend the upstream Pinchflat documentation. If you're migrating from upstream or referencing the upstream wiki, note the following.

### Environment Variables (additions)

| Variable | Default | Notes |
| --- | --- | --- |
| `DATABASE_URL` | — | **Required.** Postgres connection string: `ecto://user:pass@host/db`. Replaces the SQLite `DATABASE_PATH` variable which does not exist in this fork. |
| `POOL_SIZE` | `10` | Postgres connection pool size. No equivalent in upstream. |
| `YT_DLP_VERSION` | `stable` | Controls yt-dlp update behavior. `stable`, `nightly`, `master`, `pinned`/`none` to disable, or a specific version like `2025.12.08`. No equivalent in upstream. |

### Environment Variables (removed)

| Variable | Reason |
| --- | --- |
| `DATABASE_PATH` | SQLite-only. Not used in this fork. |
| `JOURNAL_MODE` | SQLite-only workaround for network shares. Not used in this fork. |

### Oban job queue behavior

This fork uses the `Oban.Engines.Basic` engine (Postgres native) instead of `Oban.Engines.Lite` (SQLite-only). This resolves write contention and crash loops that could occur on the upstream under load.

The `Oban.Plugins.Lifeline` plugin is enabled with a 30-minute rescue window. Any job that gets stuck in `executing` state after a crash or container restart will automatically be moved back to `retryable` and re-queued. Upstream does not include this plugin.

### Source configuration (additions)

Each source has two new fields not present in upstream:

- **Download public videos** (default: on) — controls whether videos with `availability: public` are downloaded.
- **Download members-only videos** (default: off) — controls whether `subscriber_only`, `premium_only`, and `needs_auth` videos are downloaded. Requires cookies to be configured for the source.

Unlisted and private videos are always skipped regardless of these settings.

### Media item error tracking (additions)

Two new fields on media items not present in upstream:

- **`availability`** — captured from yt-dlp at index time. Values: `public`, `unlisted`, `subscriber_only`, `premium_only`, `needs_auth`, `private`.
- **`error_type`** — set during download failures. Values: `transient` (will retry), `permanent` (sets `prevent_download: true`, stops retrying).

Permanent failures include: video unavailable, removed, private, members-only, age-restricted, geo-blocked, and premium-only errors.

---

## Upstream documentation

The [upstream wiki](https://github.com/kieraneglin/pinchflat/wiki) covers features that have not changed in this fork: media profiles, SponsorBlock, RSS feeds, Apprise notifications, lifecycle scripts, and Jellyfin/Plex/Kodi setup. For anything related to the UI, source management, or features added in this fork, refer to the [Pinchfork wiki](https://github.com/o51r15/pinchfork/wiki) instead.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Contributed several improvements that were submitted as open PRs to the upstream project but not yet merged. Their work on the Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing has been incorporated into this fork with attribution.

---

## License

See `LICENSE` file. This fork is also licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin). Logo by [@hernandito](https://github.com/hernandito).
