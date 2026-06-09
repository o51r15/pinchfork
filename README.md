> **This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat).** The upstream project entered a development pause in September 2025. This fork continues active development with a focus on backend stability and operational improvements.

[![License](https://img.shields.io/badge/license-AGPL--3.0-ee512b?style=for-the-badge)](https://github.com/o51r15/pinchflat/blob/master/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/o51r15/pinchflat?style=for-the-badge&color=purple)](https://github.com/o51r15/pinchflat/releases)

# Pinchflat (o51r15 fork)

*logo by [@hernandito](https://github.com/hernandito)*

Pinchflat is a self-hosted app for automatically downloading YouTube content using [yt-dlp](https://github.com/yt-dlp/yt-dlp). Set up rules for channels or playlists and it handles the rest — checking for new content on a schedule and saving it to disk. Designed for use with media center apps like Plex, Jellyfin, and Kodi, or for archiving.

This fork replaces the upstream SQLite backend with **PostgreSQL**, resolving job queue contention and crash loops under load. Additional UX and reliability improvements have been made on top.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
  - [Docker Compose (with Postgres)](#docker-compose-with-postgres)
  - [Environment Variables](#environment-variables)
  - [Reverse Proxies](#reverse-proxies)
- [Fork Changes](#fork-changes)
- [Roadmap](#roadmap)
- [Upstream Documentation](#upstream-documentation)
- [Contributors](#contributors)
- [License](#license)

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
- **Per-source content availability filtering** — control whether public and/or members-only videos are downloaded
- **Error classification** — permanent failures (members-only, geo-blocked, removed) are automatically stopped from retrying
- **YouTube client override** — per-source setting to select an alternate YouTube client, resolving SABR streaming failures on affected sources

---

## Installation

### Docker Compose (with Postgres)

This fork requires a Postgres container alongside the app. You will need to build the image locally from this repository.

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

> **Migrating from upstream?** Replace `DATABASE_PATH` with `DATABASE_URL` (Postgres connection string) and remove any `JOURNAL_MODE` setting — it is SQLite-only and has no effect here. See [Fork Changes](#fork-changes) for the full list of differences.

### Environment Variables

Variables marked **†** are specific to this fork and have no upstream equivalent.

| Name | Required? | Default | Notes |
| --- | --- | --- | --- |
| `DATABASE_URL` † | **Yes** | — | Postgres connection string: `ecto://user:pass@host/db`. Replaces the upstream `DATABASE_PATH`. |
| `TZ` | No | `UTC` | Must follow IANA TZ format |
| `POOL_SIZE` † | No | `10` | Postgres connection pool size |
| `LOG_LEVEL` | No | `debug` | Can be set to `info` |
| `UMASK` | No | `022` | Unraid users may want `000` |
| `BASIC_AUTH_USERNAME` | No | — | Enables basic auth when both username and password are set |
| `BASIC_AUTH_PASSWORD` | No | — | Enables basic auth when both username and password are set |
| `EXPOSE_FEED_ENDPOINTS` | No | `false` | See RSS feed docs |
| `ENABLE_IPV6` | No | `false` | Set to any non-blank value to enable |
| `TZ_DATA_DIR` | No | `/etc/elixir_tzdata_data` | Container path for timezone database |
| `BASE_ROUTE_PATH` | No | `/` | Base path for reverse proxy subdirectory deployments |
| `YT_DLP_WORKER_CONCURRENCY` | No | `2` | yt-dlp workers per queue. Set to `1` if getting IP limited |
| `YT_DLP_VERSION` † | No | `stable` | yt-dlp update behavior: `stable`, `nightly`, `master`, `pinned`/`none` to disable, or a specific version like `2025.12.08` |
| `ENABLE_PROMETHEUS` | No | `false` | Set to any non-blank value to enable |

**Removed from upstream:**

| Variable | Reason |
| --- | --- |
| `DATABASE_PATH` | SQLite-only. Use `DATABASE_URL` instead. |
| `JOURNAL_MODE` | SQLite-only workaround for network shares. Not applicable. |

### Reverse Proxies

Pinchflat makes heavy use of websockets for real-time updates. Ensure your reverse proxy is configured to support websockets.

---

## Fork Changes

### PostgreSQL backend (replaces SQLite)

The original Pinchflat uses SQLite. This fork replaces it with PostgreSQL:

- SQLite + Oban is a structural mismatch. Oban was built for Postgres and the SQLite adapter causes write contention, query timeouts, and crash loops as library size grows.
- Postgres handles concurrent job queues (indexing, downloading, metadata, file sync) correctly without file locking issues.
- The `JOURNAL_MODE` workaround for network shares is no longer needed.

**Code changes:**

- `ecto_sqlite3` replaced with `postgrex`
- Oban engine changed from `Lite` (SQLite-only) to `Basic` (Postgres native)
- SQLite-specific SQL replaced throughout (`IFNULL` → `COALESCE`, `DATETIME()` → interval arithmetic, `date()` → `::date`, `regexp_like` → `~`)
- Full-text search migrated from SQLite FTS5 to Postgres `tsvector` with a GIN index and trigger-maintained updates

The `Oban.Plugins.Lifeline` plugin is enabled with a 30-minute rescue window — any job stuck in `executing` state after a crash or restart is automatically re-queued. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#860](https://github.com/kieraneglin/pinchflat/pull/860))*

**What stays the same:**

All application features, the web UI, yt-dlp integration, media profiles, sources, Jellyfin/Plex/Kodi support, SponsorBlock, RSS feeds, Apprise notifications, and lifecycle scripts are unchanged.

### Source configuration additions

**Content availability filtering** — Each source has two new fields:

- **Download public videos** (default: on) — controls whether videos with `availability: public` are downloaded.
- **Download members-only videos** (default: off) — controls whether `subscriber_only`, `premium_only`, and `needs_auth` videos are downloaded. Requires cookies to be configured for the source.

Unlisted and private videos are always skipped regardless of these settings.

**YouTube client override (SABR bypass)** — A per-source dropdown to select which YouTube client yt-dlp uses for downloads. The default is yt-dlp's built-in behavior. Setting an alternate client is useful when a source experiences SABR (Streaming Adaptive Bitrate) failures that cause download errors or incomplete files. When a client override is set, cookies are automatically disabled as they are incompatible with non-web clients.

Available client options: Default, iOS, Android, TV Embedded.

### Media item error tracking

Two new fields on media items not present in upstream:

- **`availability`** — captured from yt-dlp at index time. Values: `public`, `unlisted`, `subscriber_only`, `premium_only`, `needs_auth`, `private`.
- **`error_type`** — set during download failures. `transient` (will retry) or `permanent` (sets `prevent_download: true`, stops retrying). Permanent failures include: video unavailable, removed, private, members-only, age-restricted, geo-blocked, and premium-only errors.

### Database schema fixes

- **`last_error` column** — expanded from `varchar(255)` to `text` to prevent truncation of verbose yt-dlp error messages.

### UX improvements

- **Source form reorganized** — the Downloading Options section now flows logically: Download Media → Content Availability → Cookie Behaviour → Video Client. Min/Max Duration moved into the contiguous Advanced Options block.
- **Fast Indexing help card** — made collapsible via a native `<details>` element to reduce visual noise for users who don't need the explanation.

---

## Roadmap

- [x] **v0.1.0** — PostgreSQL backend migration. Replaces SQLite with Postgres, resolves Oban write contention, migrates full-text search to `tsvector`, rewrites all SQLite-specific query syntax.
- [x] **Source-level content availability filtering** — per-source control over public and members-only downloads
- [x] **Error classification system** — `error_type` field distinguishing permanent from transient failures
- [x] **Permanent failure prevention** — auto-sets `prevent_download: true` on permanent failures
- [x] **Oban Lifeline plugin** — rescues stuck jobs after crash/restart *(credit: [ddacunha](https://github.com/ddacunha), PR [#860](https://github.com/kieraneglin/pinchflat/pull/860))*
- [x] **yt-dlp version management** — `YT_DLP_VERSION` env var *(credit: [ddacunha](https://github.com/ddacunha), PR [#858](https://github.com/kieraneglin/pinchflat/pull/858))*
- [x] **YouTube API key tester** — one-click validation from Settings *(credit: [ddacunha](https://github.com/ddacunha), PR [#857](https://github.com/kieraneglin/pinchflat/pull/857))*
- [x] **YouTube client override (SABR bypass)** — per-source client selection to resolve SABR streaming failures
- [x] **`last_error` column expansion** — `varchar(255)` → `text` to prevent truncation of long error messages
- [x] **Source form UX improvements** — Downloading Options reorganized for clearer flow; Fast Indexing help card made collapsible
- [ ] **Download prevention reason tracking** — `download_prevented_reason` field to distinguish manually prevented, policy-blocked, and error-stopped downloads so re-indexing doesn't accidentally re-enable intentionally blocked items
- [ ] **Queue diagnostics page** — Oban queue health stats, stuck job detection, and bulk reset/cancel actions *(credit: [ddacunha](https://github.com/ddacunha), PR [#859](https://github.com/kieraneglin/pinchflat/pull/859))*
- [ ] **Media profile template visibility** — show effective output path template on profile and source pages; add preset re-apply button to profile edit form

---

## Upstream Documentation

For documentation on features, media profiles, sources, Jellyfin/Plex setup, cookies, SponsorBlock, and other functionality, refer to the [upstream wiki](https://github.com/kieraneglin/pinchflat/wiki). All feature documentation remains accurate for this fork — only the installation and database backend differ.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Contributed several improvements submitted as open PRs to the upstream project but not yet merged. Work on the Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing has been incorporated into this fork with attribution.

---

## License

See `LICENSE` file. This fork is also licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin). Logo by [@hernandito](https://github.com/hernandito).
