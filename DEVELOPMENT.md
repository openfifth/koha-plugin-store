# Development

Local setup for working on the backend. For production deployment, see
[DEPLOYMENT.md](DEPLOYMENT.md). For the certification pipeline every submitted
plugin runs through, see [docs/CERTIFICATION.md](docs/CERTIFICATION.md).

## Notes

- A `koha_plugin_store.conf` file is required. Follow the example from
  `koha_plugin_store.conf.example` (host dev) or
  `koha_plugin_store.conf.docker.example` (Docker dev) — these two differ in
  `pg_dsn`'s host, don't mix them up.
- `.kpz` files downloaded from GitHub land in an ephemeral `File::Temp`
  directory (the system temp dir, both in Docker and host dev), cleaned up
  automatically once each submission's checks finish — there's no
  persistent package directory to look in.
- Developer login is GitHub OAuth — there's no password-based login anymore.
  Local/Docker dev needs a real GitHub OAuth App registered (callback URL
  matching your `morbo`/Docker host and port), with its `client_id`/
  `client_secret` added to `koha_plugin_store.conf`'s `oauth_providers` block —
  or use the `oauth_mock` shortcut described below.
- Submitting a plugin requires the developer to have at least one public
  GitHub repository — the submission form picks from a list of the
  developer's own public repos rather than accepting a free-text URL.
- Plugin submission is asynchronous: picking a repo+tag creates the
  plugin/version rows immediately and a Minion background job does the
  actual download/parse/validation. A Minion worker process must be running
  for submissions to ever complete — either
  `perl script/koha_plugin_store minion worker` locally, or the `worker`
  service in Docker (already included in `docker-compose.yml`).
- To install cpan dependencies for host dev, run `cpanm --installdeps .` at
  the project root dir. Dev/Docker deliberately stays on plain `cpanm`
  (fast, no lockfile overhead) — production installs from a committed
  `cpanfile.snapshot` via Carton instead, for reproducible deploys. See
  [DEPLOYMENT.md](DEPLOYMENT.md). If you add or change a dependency in
  `cpanfile` (either the root one or `sandbox_broker/cpanfile`), regenerate
  the matching snapshot and commit it, even though dev itself doesn't use
  it:
  ```bash
  cpanm --notest Carton && carton install   # updates cpanfile.snapshot
  ```
- Local Postgres runs via `docker compose up -d postgres` (see
  `docker-compose.yml`).

## Commands

- Start local Postgres: `docker compose up -d postgres`
- Apply migrations: `script/koha_plugin_store migrate`
- Reset test data: `script/koha_plugin_store reset_test_data`
- Run tests: `prove -l t/`
- Run the syntax-sandbox broker's own tests (separate `lib/`, see
  [sandbox_broker/](sandbox_broker/)): `(cd sandbox_broker && prove -l -I lib t/)`

## Docker development

No local Perl or Postgres install needed:

1. `cp koha_plugin_store.conf.docker.example koha_plugin_store.conf` (edit in your
   `github_app_token` if you need GitHub-backed features)
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

## Testing developer login (GitHub OAuth)

Two ways to test the login flow, depending on what you're working on.

**Quick path — no GitHub account needed:**

`koha_plugin_store.conf.docker.example` already sets `oauth_mock => 1`. With that in
place, clicking "Log in with GitHub" logs you in instantly as a fixed `mockdev`
account, skipping GitHub entirely — good enough for anything that just needs *a*
logged-in developer (submission flow, ownership checks, etc.), but it never
exercises the actual OAuth2 code path.

**Real path — testing the OAuth flow itself:**

1. Register an OAuth App at <https://github.com/settings/developers> → OAuth Apps →
   New OAuth App:
   - **Homepage URL**: wherever you're reaching the app (e.g. `http://127.0.0.1:3000`
     for host dev, or your Docker host's LAN address/hostname if you're browsing from
     another machine)
   - **Authorization callback URL**: the same host, path `/auth/github` (e.g.
     `http://127.0.0.1:3000/auth/github`) — must match exactly, GitHub does an exact
     host:port match. Plain `http://` is fine for local dev; GitHub doesn't require
     HTTPS here.
2. Copy the generated **Client ID** and **Client secret** into `koha_plugin_store.conf`'s
   `oauth_providers` block, and remove (or set to `0`) the `oauth_mock` flag:
   ```perl
   oauth_providers => [
     {
       key           => 'github',
       kind          => 'github',
       display_name  => 'GitHub',
       client_id     => 'your real Client ID',
       client_secret => 'your real Client secret',
     },
   ],
   ```
3. Restart so the app picks up the config change — it's only read at startup, and
   `morbo`'s auto-reload watches Perl/template files, not `.conf`:
   ```bash
   docker compose restart app        # Docker — no rebuild needed
   ```
   (for host dev, just re-run `morbo script/koha_plugin_store`)

**Common pitfalls:**

- **Wrong `pg_dsn` host.** `koha_plugin_store.conf.docker.example`'s `pg_dsn` points at
  `postgres:5432` (the compose service name). If you started from
  `koha_plugin_store.conf.example` instead, or hand-edited an existing conf, it may
  still say `127.0.0.1:55432` — not reachable *from inside* the app container.
  Double-check this if the app fails to connect to Postgres after editing `.conf`.
- **Testing from another machine on your LAN.** The app's Docker port is published on
  all interfaces (`3000:3000`), reachable via the Docker host's LAN IP or hostname —
  but `127.0.0.1` in your OAuth App's callback URL only ever means "this machine."
  Use whatever hostname/IP your browser will actually use to reach the Docker host,
  and register that exact value with GitHub.
- **Clicking "Cancel"/"Deny" on GitHub's authorize screen** renders a plain 400
  response rather than logging you in — that's expected, not a bug.

## Launch server (host dev, no Docker)

- `morbo script/koha_plugin_store`
