# Deployment

Running the store in production, outside of the Docker Compose dev setup
described in [DEVELOPMENT.md](DEVELOPMENT.md). Production runs three
long-lived processes directly on the host — the web app, a Minion worker,
and the syntax-sandbox broker — behind systemd. These instructions assume
**Debian 12 (bookworm)**; package names below are its `apt` names.

## Prerequisites

### System packages

Debian 12's own `perl` package is 5.36 — no third-party Perl install needed.

On the **app/worker host**:

```bash
sudo apt-get update
sudo apt-get install -y perl build-essential libpq-dev libssl-dev zlib1g-dev git cpanminus
```

- `build-essential`, `libpq-dev`, `libssl-dev`, `zlib1g-dev` — compile
  toolchain and headers `cpanm` needs to build `DBD::Pg` (via `Mojo::Pg`),
  `Net::SSLeay`/`IO::Socket::SSL`, and `CryptX` from source. Confirmed by
  actually building this project's full dependency tree on a bare
  `debian:bookworm-slim` container with nothing else installed — dropping
  any of these produces a linker or configure failure (missing `-lssl`,
  missing `-lz`, or missing `libpq-fe.h`, respectively).
- `git` — the app itself doesn't shell out to git, but `cpanm`/`carton`
  need it for a couple of dependencies distributed as git checkouts, and
  it's how you'll be deploying this repo in the first place.
- `cpanminus` — provides `cpanm`, used below to bootstrap Carton (see
  Install).

On the **syntax-sandbox broker host** (can be the same host, or a separate
one — see below):

```bash
sudo apt-get update
sudo apt-get install -y perl git docker.io cpanminus
```

Its own dependency set is much smaller (just Mojolicious) and needs none of
the `-dev` packages above — see `sandbox_broker/Dockerfile` for the
authoritative list if that ever changes.

### Postgres

Needs a reachable Postgres instance — not the dev-only
`docker-compose.yml` Postgres, which binds to `127.0.0.1` with well-known
weak credentials. If you're self-hosting it on the same box:

```bash
sudo apt-get install -y postgresql
sudo -u postgres createuser --pwprompt koha_plugin_store
sudo -u postgres createdb --owner koha_plugin_store koha_plugin_store
```

(Debian 12 installs PostgreSQL 15 by default — no specific version is
required, migrations use nothing version-specific.) Set `pg_dsn` in
`koha_plugin_store.conf` (see Install below) to match, e.g.:

```
pg_dsn => 'postgresql://koha_plugin_store:<the password you set>@127.0.0.1:5432/koha_plugin_store',
```

If Postgres lives on a **different** host from the app, you'll additionally
need to set `listen_addresses` in `postgresql.conf` and add a matching
`host` line to `pg_hba.conf` for the app host's address — out of scope
here, see the [PostgreSQL server admin
docs](https://www.postgresql.org/docs/current/server-configuration.html).

### Docker (syntax-sandbox broker only)

Outbound network access from the **broker's** host to
`git.koha-community.org` (to clone each Koha release tag the first time
it's needed) and to wherever `koha/koha-testing` images are pulled from
(Docker Hub by default — `docker run` pulls a missing tag automatically, no
separate `docker pull` step is scripted here). **Only the syntax-sandbox
broker needs Docker socket access** — it's a separate process/systemd
unit/user from the main app and worker, deliberately: the worker handles
untrusted plugin content (parsing submitted metadata, unzipping a submitted
`.kpz`) before the `perl_syntax` check ever runs, so keeping Docker socket
access out of that process means a bug there doesn't also mean host root.
Do **not** add the `plugin-store` user to the `docker` group — see
`koha_plugin_store-sandbox-broker.service.example` for the dedicated user
it should run as instead. The app and worker hosts themselves need no
Docker install or egress to either of these at all if split onto separate
hosts from the broker.

### Users

A dedicated `plugin-store` user and group (matches
`koha_plugin_store.service.example`'s `User=`/`Group=`), and a separate
`plugin-store-sandbox` user and group for the syntax-sandbox broker
(matches `koha_plugin_store-sandbox-broker.service.example`) — the latter
needs to be in the `docker` group; the former should NOT be, and instead
needs to be a supplementary member of `plugin-store-sandbox` to reach the
broker's socket.

```bash
sudo useradd --system --create-home --home-dir /opt/plugin-store plugin-store
sudo useradd --system --no-create-home plugin-store-sandbox
```

## Install

1. Clone the repo to the path you'll run from (the example unit files assume
   `/opt/plugin-store`):
   ```bash
   git clone <repo-url> /opt/plugin-store
   cd /opt/plugin-store
   ```
2. Install CPAN dependencies with **Carton**, not plain `cpanm`. Dev/Docker
   stays on plain `cpanm --installdeps .` (fast, no lockfile overhead), but
   production installs from `cpanfile.snapshot` — a lockfile committed to
   this repo pinning exact dependency versions — so every deploy gets
   identical versions instead of whatever `cpanm` resolves to on CPAN that
   day:
   ```bash
   cpanm --notest Carton
   carton install --deployment
   ```
   This installs everything into a project-local `local/` directory (both
   `cpanfile.snapshot` and `Carton` itself resolve `Koha::QA` — needed for
   the `perl_critic` check — as an ordinary CPAN distribution; no special
   install steps or extra tooling needed for it specifically). The
   systemd units set `PERL5LIB` to point at it — see below.

   The syntax-sandbox broker has its own, separate `cpanfile`/
   `cpanfile.snapshot` (just Mojolicious) — install it the same way:
   ```bash
   (cd sandbox_broker && cpanm --notest Carton && carton install --deployment)
   ```
3. Copy `koha_plugin_store.conf.example` to `koha_plugin_store.conf` and fill in:
   - `github_app_token` — a fine-grained, public-repos-read-only PAT.
   - `pg_dsn` — your production Postgres connection string (see Postgres,
     above).
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
   PERL5LIB=/opt/plugin-store/local/lib/perl5 script/koha_plugin_store generate_signing_key /opt/plugin-store/signing_key.pem
   ```
   Refuses to overwrite an existing file unless `--force` is given — back this
   file up; losing it means every previously-published version's signature
   can no longer be verified against a newly-generated key.
5. Apply migrations (needs the Postgres instance from above already
   reachable and `pg_dsn` already set):
   ```bash
   PERL5LIB=/opt/plugin-store/local/lib/perl5 script/koha_plugin_store migrate
   ```
   This creates the application's own tables (`plugins`, `plugin_versions`,
   `developers`, ...) in the database you created — there's nothing else to
   set up on the Postgres side first.
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
carton install --deployment
(cd sandbox_broker && carton install --deployment)
script/koha_plugin_store migrate
sudo systemctl restart koha-plugin-store koha-plugin-store-worker koha-plugin-store-sandbox-broker
```

If the `git pull` changed `cpanfile` (either one) to add a module that
isn't already pinned in `cpanfile.snapshot`, `carton install --deployment`
fails loudly for that module (`Couldn't find module ... in deployment
mode`) rather than silently resolving whatever's newest on CPAN — that's
deliberate. Regenerate the snapshot on a dev machine after changing
`cpanfile`, before deploying:
```bash
carton install        # no --deployment: resolves and updates cpanfile.snapshot
git add cpanfile.snapshot
git commit
```
