# Deployment

Running the store in production, outside of the Docker Compose dev setup
described in [DEVELOPMENT.md](DEVELOPMENT.md). Production runs three
long-lived processes directly on the host — the web app, a Minion worker,
and the syntax-sandbox broker — behind systemd.

## Prerequisites

- Perl 5.36+, with `build-essential`, `libpq-dev`, `git`, `nodejs`/`npm` and
  `yarn` available (see `Dockerfile` for the exact package list the dev image
  installs — production needs the same). The syntax-sandbox broker
  (`sandbox_broker/`) is a much smaller, separate Perl app — it only needs
  `git` and the `docker` CLI, see its own `Dockerfile` for the exact list.
- A reachable Postgres instance (not the dev-only `docker-compose.yml`
  Postgres, which binds to `127.0.0.1` with well-known weak credentials).
- Docker installed on the **syntax-sandbox broker's** host, with outbound
  network access from that host to `git.koha-community.org` (to clone each
  Koha release tag the first time it's needed) and to wherever
  `koha/koha-testing` images are pulled from (Docker Hub by default —
  `docker run` pulls a missing tag automatically, no separate `docker pull`
  step is scripted here). **Only the syntax-sandbox broker needs Docker
  socket access** — it's a separate process/systemd unit/user from the main
  app and worker, deliberately: the worker handles untrusted plugin content
  (parsing submitted metadata, unzipping a submitted `.kpz`) before the
  `perl_syntax` check ever runs, so keeping Docker socket access out of that
  process means a bug there doesn't also mean host root. Do **not** add the
  `plugin-store` user to the `docker` group — see
  `koha_plugin_store-sandbox-broker.service.example` for the dedicated user
  it should run as instead. The app and worker hosts themselves need no
  Docker install or egress to either of these at all if split onto separate
  hosts from the broker.
- A dedicated `plugin-store` user and group (matches
  `koha_plugin_store.service.example`'s `User=`/`Group=`), and a separate
  `plugin-store-sandbox` user and group for the syntax-sandbox broker
  (matches `koha_plugin_store-sandbox-broker.service.example`) — the latter
  needs to be in the `docker` group; the former should NOT be, and instead
  needs to be a supplementary member of `plugin-store-sandbox` to reach the
  broker's socket.

## Install

1. Clone the repo to the path you'll run from (the example unit files assume
   `/opt/plugin-store`):
   ```bash
   git clone <repo-url> /opt/plugin-store
   cd /opt/plugin-store
   ```
2. Install CPAN dependencies:
   ```bash
   cpanm --installdeps .
   ```
   `Koha::QA::PerlCritic` (needed for the `perl_critic` check) isn't on CPAN —
   see the `cpanfile` comment for the exact `cpanm -L local --force <git-url>@<ref>`
   command, and set `PERL5LIB` to include that local `lib/` for anything that
   loads it (the app, `minion worker`, `prove`).

   The syntax-sandbox broker has its own, much smaller dependency set —
   install it separately:
   ```bash
   (cd sandbox_broker && cpanm --installdeps .)
   ```
3. Copy `koha_plugin_store.conf.example` to `koha_plugin_store.conf` and fill in:
   - `github_app_token` — a fine-grained, public-repos-read-only PAT.
   - `pg_dsn` — your production Postgres connection string.
   - `oauth_providers` — a real GitHub OAuth App's `client_id`/`client_secret`
     (registered at <https://github.com/settings/developers>, callback URL
     `https://<your-host>/auth/github`). Do **not** set `oauth_mock` in
     production — it bypasses GitHub login entirely and exists for dev only.
   - `signing_key_path` — a file path for the store's Ed25519 signing key (see
     below). Keep the key file itself out of the conf and out of git.
   - `secrets` — a random string used to sign session cookies (see the
     comment above it in the example file for how to generate one).
     Optional, but recommended: without it, Mojolicious auto-generates one
     per process, so a restart invalidates every session. The app also
     marks session cookies `Secure` automatically whenever it's running in
     `production` mode (the default unless `MOJO_MODE`/`PLACK_ENV` says
     otherwise) — make sure you're actually serving over HTTPS (see the TLS
     step below) before relying on that.
4. Generate the signing key referenced above (see
   [docs/CERTIFICATION.md](docs/CERTIFICATION.md) for what it's used for):
   ```bash
   script/koha_plugin_store generate_signing_key /opt/plugin-store/signing_key.pem
   ```
   Refuses to overwrite an existing file unless `--force` is given — back this
   file up; losing it means every previously-published version's signature
   can no longer be verified against a newly-generated key.
5. Apply migrations:
   ```bash
   script/koha_plugin_store migrate
   ```
6. Place your TLS certificate and key at `ssl/cert.pem` and `ssl/privkey.pem`
   (paths the example systemd unit points `MOJO_SSL_CERT`/`MOJO_SSL_PRIV` at).
   If you're terminating TLS at a reverse proxy instead (e.g. Traefik/nginx in
   front of the app), skip this and change the unit's `ExecStart` to listen
   on plain `http` on a loopback/internal port instead.

## systemd units

Three example unit files ship at the repo root — copy all three into
`/etc/systemd/system/`, editing the `User`/`Group`,
`PERL5LIB`/`WorkingDirectory`, and SSL paths to match your install:

- **`koha_plugin_store.service.example`** → `koha-plugin-store.service` — the
  web app, run via `prefork` (Mojolicious's multi-worker production server).
- **`koha_plugin_store-worker.service.example`** → `koha-plugin-store-worker.service`
  — the Minion worker. Without this running, submissions stay stuck at
  `status = 'submitted'` forever, identical to forgetting to start the
  `worker` service in the dev Docker Compose setup.
- **`koha_plugin_store-sandbox-broker.service.example`** →
  `koha-plugin-store-sandbox-broker.service` — the `perl_syntax` check's
  sandboxed compile-check, run as its own dedicated user with Docker socket
  access (see Prerequisites above). Without this running, every submission
  fails its required `perl_syntax` check with a `check_error` status rather
  than publishing.

```bash
sudo cp koha_plugin_store.service.example /etc/systemd/system/koha-plugin-store.service
sudo cp koha_plugin_store-worker.service.example /etc/systemd/system/koha-plugin-store-worker.service
sudo cp koha_plugin_store-sandbox-broker.service.example /etc/systemd/system/koha-plugin-store-sandbox-broker.service
sudo usermod -aG plugin-store-sandbox plugin-store
sudo systemctl daemon-reload
sudo systemctl enable --now koha-plugin-store koha-plugin-store-worker koha-plugin-store-sandbox-broker
```

## Upgrading

```bash
git pull
cpanm --installdeps .
(cd sandbox_broker && cpanm --installdeps .)
script/koha_plugin_store migrate
sudo systemctl restart koha-plugin-store koha-plugin-store-worker koha-plugin-store-sandbox-broker
```
