# WIP koha-plugin-store

Koha plugin store project consisting of 2 distinct components:

- Backend
- Client

## Backend

- Mojolicious app (Perl)
- Koha plugins database

- Features:

  - Restricted access UI for review process of new plugin submissions
  - Authorized community members can access and review plugins
  - Provides REST API to be consumed by core Koha
  - Automatically manage latest version releases for each plugin

- Notes

  - A `koha_plugin_store.conf` file is required. Follow the example from `koha_plugin_store.conf.example`
    (now also holds `pg_dsn`, the Postgres connection string).
  - The `kpz_packages` directory is used to store `.kpz` files download from github.
  - Developer login is GitHub OAuth — there's no password-based login anymore. Local/Docker
    dev needs a real GitHub OAuth App registered (callback URL matching your `morbo`/Docker
    host and port), with its `client_id`/`client_secret` added to `koha_plugin_store.conf`'s
    `oauth_providers` block.
  - To install cpan dependencies, run `cpanm --installdeps .` at the project
    root dir.
  - Local Postgres runs via `docker compose up -d postgres` (see `docker-compose.yml`).

- Commands
  - Start local Postgres: `docker compose up -d postgres`
  - Apply migrations: `script/koha_plugin_store migrate`
  - Reset test data: `script/koha_plugin_store reset_test_data`

### Docker development

No local Perl or Postgres install needed:

1. `cp koha_plugin_store.conf.docker.example koha_plugin_store.conf` (edit in your
   `github_user_access_token` if you need GitHub-backed features)
2. `docker compose up -d --build`
3. `docker compose exec app script/koha_plugin_store migrate` (first run only)
4. `docker compose exec app script/koha_plugin_store reset_test_data` (optional demo data)
5. Visit http://127.0.0.1:3000 — the app port is published on all interfaces (`3000:3000`,
   not `127.0.0.1:3000:3000`), so it's also reachable from elsewhere on your LAN via the
   Docker host's own IP or hostname. That matters if you're browsing from a different
   machine than the Docker host (e.g. testing a real GitHub OAuth App's callback from your
   laptop against a Docker host running elsewhere on the network) — `127.0.0.1` would only
   ever mean "this machine," not the Docker host. Postgres stays bound to `127.0.0.1` only —
   its dev credentials are weak and well-known, so it's never exposed beyond the Docker host.

The `oauth_mock` flag is already enabled in `koha_plugin_store.conf.docker.example`, allowing you to log in instantly as a mock developer without registering a real GitHub OAuth App — just click "GitHub login" and you'll be logged in. To test the real OAuth flow instead, remove or set `oauth_mock => 0` in your `koha_plugin_store.conf`.

Edits to the repo on your host are picked up automatically (`morbo` hot-reloads inside the
container) — no rebuild needed unless you change `cpanfile` or the `Dockerfile` itself.

This is separate from `koha_plugin_store.conf.example`, used for running directly on the
host — the two files point at Postgres differently (`postgres` as the hostname inside
Docker's network vs. `127.0.0.1:55432` on the host).

## Client

- VueJS App
- Relevant repo/branch [here](https://github.com/PTFS-Europe/koha/tree/plugin_store)
- Interacts with backend using the REST API

- Features:
  - Provides UI for searching and installing plugins
  - Enables updating an installed plugin if installed version is out of date

### New submission diagram

![new submission](https://github.com/ammopt/koha-plugin-store/blob/main/new-submission.jpg?raw=true)

### New version release diagram

![new version release](https://github.com/ammopt/koha-plugin-store/blob/main/new-version-release.jpg?raw=true)

### Launch server

- morbo script/koha_plugin_store
