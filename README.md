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

## Fork Changes

This fork diverges from upstream in the following ways:

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

**What stays the same:**

All application features, the web UI, yt-dlp integration, media profiles, sources, Jellyfin/Plex/Kodi support, SponsorBlock, RSS feeds, Apprise notifications, and lifecycle scripts are unchanged. This is purely a backend infrastructure change.

---

## Roadmap

- [x] **v0.1.0** — PostgreSQL backend migration. Replaces SQLite with Postgres, resolves Oban write contention, migrates full-text search to `tsvector`, rewrites all SQLite-specific query syntax.
- [x] **Source-level content availability filtering** — Per-source checkboxes to control whether public videos, members-only videos, or both are downloaded. Captures yt-dlp `availability` field at index time and re-evaluates on rescan.
- [x] **Error classification system** — `error_type` field on `media_items` to distinguish permanent failures (members-only, unavailable, geo-blocked) from transient ones (network errors, rate limits).
- [x] **Permanent failure prevention** — Once a video is classified as a permanent failure, set `prevent_download: true` automatically so it stops consuming retry cycles.
- [x] **Oban Lifeline plugin** — Rescues jobs stuck in `executing` state after a crash or container restart. Automatically retries them after 30 minutes. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#860](https://github.com/kieraneglin/pinchflat/pull/860))*
- [x] **yt-dlp version management** — `YT_DLP_VERSION` environment variable to control update behavior: `stable` (default), `nightly`, `master`, `pinned`/`none` to disable, or a specific version string. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#858](https://github.com/kieraneglin/pinchflat/pull/858))*
- [x] **Download prevention reason tracking** — `download_prevented_reason` field to distinguish between manually prevented, policy-blocked, and error-stopped downloads so re-indexing doesn't accidentally re-enable intentionally blocked items.
- [ ] **Queue diagnostics page** — New Config menu item with Oban queue health stats, stuck job detection, and bulk reset/cancel actions. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#859](https://github.com/kieraneglin/pinchflat/pull/859))*
- [x] **YouTube API key tester** — One-click API key validation from the Settings page. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#857](https://github.com/kieraneglin/pinchflat/pull/857))*
- [x] **Sonarr-inspired UI overhaul** — Source library displays as a poster card grid with download progress bars and one-click monitored toggles. Source detail pages use a Sonarr-style fanart banner, granular stats bar (Downloaded / Pending / Failed / Prevented / Skipped), and a horizontal action bar replacing the dropdown menu. Episode list groups media by year (season analog) with collapsible sections, per-item status badges, and monitored toggles. Dedicated Activity page replaces the cluttered home dashboard.
- [x] **System status page** — Shows Pinchfork version, yt-dlp version, PostgreSQL version and database size, Oban queue health, and live bgutil PO token server status with a one-click token generation test.

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

For documentation on features, media profiles, sources, Jellyfin/Plex setup, cookies, SponsorBlock, and other functionality, refer to the [upstream wiki](https://github.com/kieraneglin/pinchflat/wiki). All feature documentation remains accurate for this fork — only the installation and database backend differ.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Contributed several improvements that were submitted as open PRs to the upstream project but not yet merged. Their work on the Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing has been incorporated into this fork with attribution.

---

## License

See `LICENSE` file. This fork is also licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin). Logo by [@hernandito](https://github.com/hernandito).
