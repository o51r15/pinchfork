> **This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat).** The upstream project entered a development pause in September 2025. This fork continues active development with a focus on backend stability and operational improvements. See the [Fork Changes](#fork-changes) section for details.

[![License](https://img.shields.io/badge/license-AGPL--3.0-ee512b?style=for-the-badge)](https://github.com/o51r15/pinchfork/blob/master/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/o51r15/pinchfork?style=for-the-badge&color=purple)](https://github.com/o51r15/pinchfork/releases)

# Pinchfork

<p align="center">
  <img src="priv/static/images/pinchfork-logo.png" alt="Pinchfork" width="512">
</p>

*a fork of [Pinchflat](https://github.com/kieraneglin/pinchflat)*

> **A note on naming:** **Pinchfork** is this project — the active PostgreSQL fork. **Pinchflat** is the upstream project it was forked from. Throughout this document, "Pinchfork" refers to this fork and "Pinchflat" refers to the original upstream build. A few low-level identifiers (the Docker image's database container, user, and connection string) still use the `pinchflat` name because they are inherited from the upstream-derived image and renaming them would break existing deployments; these are called out where they appear.

## Table of contents

- [Fork Changes](#fork-changes)
- [Roadmap](#roadmap)
- [What it does](#what-it-does)
- [Features](#features)
- [Installation](#installation)
  - [Docker Compose (with Postgres)](#docker-compose-with-postgres)
  - [Environment Variables](#environment-variables)
  - [Reverse Proxies](#reverse-proxies)
- [Documentation](#documentation)
- [Configuration Differences from Upstream](#configuration-differences-from-upstream)
- [Contributors](#contributors)
- [License](#license)

---

## Fork Changes

This fork diverges from upstream in the following ways:

### PostgreSQL backend (replaces SQLite)

The original Pinchflat uses SQLite as its database. Pinchfork replaces it with PostgreSQL. The motivation:

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
- [x] **SABR bypass / PO Token provider** — Per-source Video Client override plus an optional bgutil PO Token sidecar to work around YouTube SABR-corrupted downloads. Cookie ↔ bypass mutual-exclusivity enforced in code. See [SABR bypass / PO Token provider](#sabr-bypass--po-token-provider).
- [x] **Local temp staging** — `LOCALTEMP` env var to stage all yt-dlp intermediate work on a local disk and move finished files to a (possibly network-mounted) downloads directory in one operation. See [Local Temp Staging](#local-temp-staging).
- [x] **v0.3.0** — Per-item staging cleanup (each download isolated under a per-id staging dir, orphans auto-cleaned on failure/restart/success) and a home-page failure-state split: the Pending tab is now **Pending / Retry / Failed**, with a live retry countdown and Retry Now / Force Retry actions.
- [x] **Oban Lifeline plugin** — Rescues jobs stuck in `executing` state after a crash or container restart. Automatically retries them after 30 minutes. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#860](https://github.com/kieraneglin/pinchflat/pull/860))*
- [x] **yt-dlp version management** — `YT_DLP_VERSION` environment variable to control update behavior: `stable` (default), `nightly`, `master`, `pinned`/`none` to disable, or a specific version string. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#858](https://github.com/kieraneglin/pinchflat/pull/858))*
- [x] **Download prevention reason tracking** — `download_prevented_reason` field that distinguishes manually prevented, policy-blocked, and error-stopped downloads so re-indexing doesn't accidentally re-enable intentionally blocked items. Surfaced on the media-item page.
- [x] **v0.3.1** — PO Token plugin baked into the image (one-and-done sidecar setup, no manual plugin mount) and a fail-open fix so a missing or empty plugin directory can no longer break yt-dlp on a fresh install. Also locks permanent-failure classification with regression tests.
- [ ] **Queue diagnostics page** — New Config menu item with Oban queue health stats, stuck job detection, and bulk reset/cancel actions. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#859](https://github.com/kieraneglin/pinchflat/pull/859))*
- [x] **YouTube API key tester** — One-click API key validation from the Settings page. *(credit: [ddacunha](https://github.com/ddacunha), upstream PR [#857](https://github.com/kieraneglin/pinchflat/pull/857))*

---

## What it does

Pinchfork is a self-hosted app for downloading YouTube content built using [yt-dlp](https://github.com/yt-dlp/yt-dlp). It's designed to be lightweight, self-contained, and easy to use. You set up rules for how to download content from YouTube channels or playlists and it'll do the rest, periodically checking for new content. It's perfect for people who want to download content for use with a media center app (Plex, Jellyfin, Kodi) or for those who want to archive media.

While you can download individual videos, Pinchfork is best suited for downloading content from channels or playlists. It's also not meant for consuming content in-app — Pinchfork downloads content to disk where you can then watch it with a media center app or VLC.

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

Pinchfork is distributed as a prebuilt image: `ghcr.io/o51r15/pinchfork:latest` (or pin a version like `:v0.3.1`). It requires a Postgres container, and a PO Token sidecar is strongly recommended (see [SABR bypass / PO Token provider](#sabr-bypass--po-token-provider)).

**Step 1 — Create your compose file.** A complete, annotated sample with all three containers is in the repo at [`docker-compose.sample.yml`](docker-compose.sample.yml). A minimal version:

```yaml
services:
  bgutil-provider:                                  # PO Token sidecar (recommended)
    container_name: bgutil-provider
    image: brainicism/bgutil-ytdlp-pot-provider:1.3.1
    restart: unless-stopped

  pinchfork-db:                                     # Postgres (required)
    container_name: pinchfork-db
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: pinchflat                       # inherited from upstream image — do not rename
      POSTGRES_PASSWORD: your_password_here          # must match DATABASE_URL below
      POSTGRES_DB: pinchflat                         # inherited from upstream image — do not rename
    volumes:
      - pinchfork_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pinchflat"]
      interval: 10s
      timeout: 5s
      retries: 5

  pinchfork:                                        # the app
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
      # DATABASE_URL keeps the pinchflat user/db names (inherited from the upstream image);
      # only the host segment matches the db service name above.
      - DATABASE_URL=ecto://pinchflat:your_password_here@pinchfork-db/pinchflat
      - POOL_SIZE=10
      # Optional — only if /downloads is a NETWORK mount (SMB/NFS). Stages all yt-dlp
      # work on a local disk and moves finished files over in one operation. Requires
      # the /downloads-staging volume below. See the Local Temp Staging section.
      # - LOCALTEMP=true
    ports:
      - "8945:8945"
    volumes:
      - /path/to/config:/config
      - /path/to/downloads:/downloads
      # Local staging target for LOCALTEMP above — MUST be a real LOCAL disk (not the
      # network mount, not a container path). Uncomment together with LOCALTEMP.
      # - /path/to/local/staging:/downloads-staging

volumes:
  pinchfork_pgdata:
```

**Step 2 — Start it:**

```bash
docker compose -f /path/to/your/docker-compose.yml up -d
```

Migrations run automatically at startup. The app will be available at `http://your-server:8945`.

> **Updating:** `docker compose pull && docker compose up -d` pulls the newest image and recreates the container.

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
| `LOCALTEMP` | No | — | **Fork-only.** Set to `true` to stage yt-dlp's intermediate files on a local disk and move only the finished file to the (possibly network-mounted) downloads dir. Requires the `/downloads-staging` volume mount. See [Local Temp Staging](#local-temp-staging). |

### Reverse Proxies

Pinchfork makes heavy use of websockets for real-time updates. Ensure your reverse proxy is configured to support websockets.

---

## Configuration Differences from Upstream

Pinchfork introduces configuration options and behaviors that differ from or extend the upstream Pinchflat documentation. If you're migrating from upstream or referencing the upstream wiki, note the following.

### Environment Variables (additions)

| Variable | Default | Notes |
| --- | --- | --- |
| `DATABASE_URL` | — | **Required.** Postgres connection string: `ecto://user:pass@host/db`. Replaces the SQLite `DATABASE_PATH` variable which does not exist in this fork. |
| `POOL_SIZE` | `10` | Postgres connection pool size. No equivalent in upstream. |
| `YT_DLP_VERSION` | `stable` | Controls yt-dlp update behavior. `stable`, `nightly`, `master`, `pinned`/`none` to disable, or a specific version like `2025.12.08`. No equivalent in upstream. |
| `LOCALTEMP` | — | Set to `true` to enable local temp staging for downloads (see below). No equivalent in upstream. |

### Environment Variables (removed)

| Variable | Reason |
| --- | --- |
| `DATABASE_PATH` | SQLite-only. Not used in this fork. |
| `JOURNAL_MODE` | SQLite-only workaround for network shares. Not used in this fork. |

### Oban job queue behavior

Pinchfork uses the `Oban.Engines.Basic` engine (Postgres native) instead of `Oban.Engines.Lite` (SQLite-only). This resolves write contention and crash loops that could occur on the upstream under load.

The `Oban.Plugins.Lifeline` plugin is enabled with a 30-minute rescue window. Any job that gets stuck in `executing` state after a crash or container restart will automatically be moved back to `retryable` and re-queued. Upstream does not include this plugin.

### Source configuration (additions)

Each source has two new fields not present in upstream:

- **Download public videos** (default: on) — controls whether videos with `availability: public` are downloaded.
- **Download members-only videos** (default: off) — controls whether `subscriber_only`, `premium_only`, and `needs_auth` videos are downloaded. Requires cookies to be configured for the source.

Unlisted and private videos are always skipped regardless of these settings.

### Media item error tracking (additions)

Three new fields on media items not present in upstream:

- **`availability`** — captured from yt-dlp at index time. Values: `public`, `unlisted`, `subscriber_only`, `premium_only`, `needs_auth`, `private`.
- **`error_type`** — set during download failures. Values: `transient` (will retry), `permanent` (sets `prevent_download: true`, stops retrying).
- **`download_prevented_reason`** — records *why* a download was prevented: `permanent_error`, `manual`, `user_script`, or a policy reason (`policy_public` / `policy_members` / `policy_other`). Surfaced on the media-item page so a prevented item explains itself.

Permanent failures include: video unavailable, removed, private, members-only, age-restricted, geo-blocked, and premium-only errors.

### SABR bypass / PO Token provider

YouTube's SABR streaming protocol can produce corrupt downloads on the default web client — videos that fail with `Postprocessing: Error opening input files: Invalid data found when processing input` even though indexing succeeds. Pinchfork mitigates that in two ways.

**Video Client override (per source).** Under **Source → Edit → Downloading Options** there is a **Video Client** dropdown that selects which yt-dlp player client(s) to use for that source. The options are grouped into cookie-compatible and cookie-incompatible clients. Choosing a SABR-bypassing client routes downloads around the corrupting code path.

> **Cookies and SABR bypass are mutually exclusive.** The SABR-bypassing clients refuse cookies, and the cookie-carrying clients are SABR-affected. Pinchfork enforces this in code: selecting a cookie-incompatible client disables cookies for that source, and incoherent combinations are blocked at save time with an explanatory error. A source that needs cookies (members-only content) cannot also use a cookie-incompatible bypass client.

**PO Token (POT) provider sidecar.** Some clients require a GVS PO Token to fetch the good video formats. Pinchfork supports the [bgutil POT provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider) running as a sidecar container. **The matching yt-dlp plugin is baked into the Pinchfork image** (under `/etc/yt-dlp/plugins/`), so there is nothing to mount or extract — add the sidecar service and PO tokens work automatically. If the sidecar is absent, the plugin simply stays idle and the app is unaffected.

To enable it, add the sidecar to your compose file — that is all that is required:

```yaml
services:
  bgutil-provider:
    image: brainicism/bgutil-ytdlp-pot-provider:1.3.1   # baked-in plugin matches this version
    container_name: bgutil-provider
    restart: unless-stopped

  pinchfork:
    depends_on:
      bgutil-provider:
        condition: service_started
    # ... the app passes --extractor-args
    # "youtubepot-bgutilhttp:base_url=http://bgutil-provider:4416" automatically
```

> **The plugin is pinned to a specific bgutil version in the image** (built from `bgutil-ytdlp-pot-provider` 1.3.1). Run the matching sidecar tag (`brainicism/bgutil-ytdlp-pot-provider:1.3.1`) — a version mismatch between the baked-in plugin and the sidecar is a known failure mode. Because the plugin ships inside the image rather than under the config volume, it is rebuilt with each release and survives yt-dlp's binary self-updates automatically.

### Local Temp Staging

When your downloads directory is a network mount (SMB/CIFS, NFS), all of yt-dlp's intermediate work — fragment downloads, merging separate video and audio streams, the `.temp.mp4` write-then-rename that the `[FixupM3u8]` post-processor performs, and every post-processing step (thumbnail conversion, metadata embed) — happens over the network. On some setups this intermediate read/write/rename activity over the mount can corrupt the in-progress file, producing a `Postprocessing: Error opening input files: Invalid data found when processing input` error at the muxing step.

Setting `LOCALTEMP=true` tells yt-dlp to stage **all** intermediate files on a local disk and perform the full download/merge/post-process pipeline there, moving only the finished files to the downloads directory at the very end. This keeps every network-fragile operation off the mount until a single final move per file.

To enable it, set the env var and mount a local directory at `/downloads-staging`:

```yaml
services:
  pinchfork:
    environment:
      - LOCALTEMP=true
    volumes:
      - /path/to/local/staging:/downloads-staging   # must be a LOCAL disk
      - /path/to/network/downloads:/downloads
```

The staging directory must be on a real local disk — not the network mount, and not a container-internal path — and needs enough free space for the largest in-flight download (plus its intermediates). To disable, remove `LOCALTEMP=true` (the volume mount is harmless if left in place).

Each download stages into its own per-item subdirectory under `/downloads-staging`, keyed on the video's unique id. Failed or abandoned attempts have their staging files cleaned up automatically (before the next attempt, on failure, and after success), so stale intermediates can't accumulate or interfere with a later retry.

> **How it works:** yt-dlp ignores `--paths` when `--output` is an absolute path. To make staging take effect, Pinchfork passes the base directory as `--paths home:<dir>`, a per-item staging directory as `--paths temp:<dir>/<video-id>`, and rewrites the output template to be relative — but only when `LOCALTEMP=true`. With the variable unset, download options are completely unchanged.

---

## Documentation

For Pinchfork-specific documentation, see the [Pinchfork wiki](https://github.com/o51r15/pinchfork/wiki).

For documentation on upstream features, media profiles, sources, Jellyfin/Plex setup, cookies, SponsorBlock, and other base functionality, refer to the [upstream Pinchflat wiki](https://github.com/kieraneglin/pinchflat/wiki). All base feature documentation remains accurate for this fork — only the installation, database backend, and fork-specific features differ.

---

## Contributors

**[ddacunha](https://github.com/ddacunha)** — Contributed several improvements that were submitted as open PRs to the upstream project but not yet merged. Their work on the Oban Lifeline plugin, yt-dlp version management, queue diagnostics, and YouTube API key testing has been incorporated into this fork with attribution.

---

## License

See `LICENSE` file. This fork is also licensed under AGPL-3.0.

Original project by [kieraneglin](https://github.com/kieraneglin). Logo by [@hernandito](https://github.com/hernandito).
