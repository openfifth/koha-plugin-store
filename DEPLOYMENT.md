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
sudo useradd --system --create-home plugin-store-sandbox
sudo usermod -aG plugin-store-sandbox plugin-store
```

`plugin-store-sandbox` needs a real home directory too (the default
`/home/plugin-store-sandbox` is fine — it's only for tool caches like
`cpanm`'s build cache, not application data, which lives entirely under
`/opt/plugin-store/sandbox_broker/`, handed to this user in the Install
section below). `--no-create-home` looked more minimal but doesn't
actually create anything at the `$HOME` path it still assigns, and `cpanm`
fails outright without a writable one (`Can't write to cpanm home
'/home/plugin-store-sandbox/.cpanm'`) — confirmed by hitting this for
real running through this doc's own Install steps end to end.

## Install

**Run each step as the user noted in its heading, not as `root`.** The
systemd units run the app as `plugin-store`/`plugin-store-sandbox` (see
Users, above); anything installed or generated as `root` instead —
`local/` (Carton's install), `koha_plugin_store.conf`, `signing_key.pem`,
`sandbox_broker/`'s own `local/` and data directories — won't necessarily
be readable (or in the sandbox broker's case, writable) by the account
that actually runs the service, and the service will fail at startup with
a permissions error. `sudo -u <user> <command>` works fine for this even
though these are `--system` accounts with no real login shell; you don't
need `su -`/`sudo -i`. If you've already run some of this as `root` (mixed
ownership), see "Fixing mixed ownership" at the end of this section before
starting the systemd units.

1. **(as `plugin-store`)** Clone the repo to the path you'll run from (the
   example unit files assume `/opt/plugin-store`, already `plugin-store`'s
   home directory from the `useradd --create-home` above, so it can write
   there):
   ```bash
   sudo -u plugin-store git clone <repo-url> /opt/plugin-store
   cd /opt/plugin-store
   ```
   Then hand the `sandbox_broker/` subdirectory over to the other user, since
   its own service needs to write to it (installing its dependencies next,
   then its checkout cache and staging area at runtime):
   ```bash
   sudo chown -R plugin-store-sandbox:plugin-store-sandbox sandbox_broker
   ```
2. **(as `root`)** Install **Carton** itself, once, system-wide — it's
   build tooling shared by both apps below, not a per-app runtime
   dependency, so it belongs in the normal system Perl paths rather than
   either service user's own tree:
   ```bash
   sudo cpanm --notest Carton
   ```
   Don't run this particular command as `plugin-store`/`plugin-store-sandbox`
   — `cpanm` running as a non-root user with no write access to the system
   Perl directories silently falls back to installing into that user's own
   `~/perl5`, which isn't on `PATH`/`@INC` for a plain `sudo -u <user>
   <command>` invocation (there's no login shell involved to source the
   `local::lib` environment `cpanm` would otherwise set up) — the next step
   would then fail with `carton: command not found`.

   Then install this project's actual dependencies from **Carton**, not
   plain `cpanm`. Dev/Docker stays on plain `cpanm --installdeps .` (fast,
   no lockfile overhead), but production installs from
   `cpanfile.snapshot` — a lockfile committed to this repo pinning exact
   dependency versions — so every deploy gets identical versions instead of
   whatever `cpanm` resolves to on CPAN that day. This part *does* run as
   the service user, since it's writing into this project's own
   `local/` directory:
   ```bash
   # (as plugin-store)
   sudo -u plugin-store carton install --deployment
   ```
   `cpanfile.snapshot` and `Carton` itself resolve `Koha::QA` — needed for
   the `perl_critic` check — as an ordinary CPAN distribution; no special
   install steps or extra tooling needed for it specifically. The
   systemd units set `PERL5LIB` to point at the resulting `local/` — see
   below.

   The syntax-sandbox broker has its own, separate `cpanfile`/
   `cpanfile.snapshot` (just Mojolicious) — install it the same way, as its
   own user, now that it owns that subdirectory (Carton itself is already
   installed system-wide from the step above, shared by both):
   ```bash
   # (as plugin-store-sandbox)
   sudo -u plugin-store-sandbox bash -c 'cd sandbox_broker && carton install --deployment'
   ```
3. **(as `plugin-store`)** Copy `koha_plugin_store.conf.example` to
   `koha_plugin_store.conf` and fill in:
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

   `koha_plugin_store.conf` holds a GitHub PAT, an OAuth client secret, your
   Postgres password, and the session secret — lock it down:
   ```bash
   sudo -u plugin-store chmod 600 koha_plugin_store.conf
   ```
4. **(as `plugin-store`)** Apply migrations — needs the Postgres instance
   from above already running and `pg_dsn` already pointed at it correctly
   (not the `koha_plugin_store.conf.example` placeholder, which points at
   `127.0.0.1:55432`, the dev-only Docker Compose port):
   ```bash
   sudo -u plugin-store env PERL5LIB=/opt/plugin-store/local/lib/perl5 script/koha_plugin_store migrate
   ```
   This creates the application's own tables (`plugins`, `plugin_versions`,
   `developers`, ...) in the database you created — there's nothing else to
   set up on the Postgres side first. If this fails with a `DBI connect(...)
   Connection refused` error, Postgres isn't reachable at the `pg_dsn`
   you've configured — double check it's actually running
   (`sudo systemctl status postgresql`) and that `pg_dsn`'s host/port match.
5. **(as `plugin-store`)** Generate the signing key referenced above (see
   [docs/CERTIFICATION.md](docs/CERTIFICATION.md) for what it's used for):
   ```bash
   sudo -u plugin-store env PERL5LIB=/opt/plugin-store/local/lib/perl5 script/koha_plugin_store generate_signing_key /opt/plugin-store/signing_key.pem
   sudo -u plugin-store chmod 600 /opt/plugin-store/signing_key.pem
   ```
   Refuses to overwrite an existing file unless `--force` is given — back this
   file up; losing it means every previously-published version's signature
   can no longer be verified against a newly-generated key. **This also
   needs Postgres reachable**, same as every `script/koha_plugin_store`
   command — not because generating a keypair touches the database, but
   because `KohaPluginStore->startup()` unconditionally registers Minion
   against Postgres before any command runs, so booting the app at all
   fails if step 4 isn't already working. Doing step 4 first means you hit
   that failure mode somewhere more obviously DB-related if it's going to
   happen. Running it as `plugin-store` (not `root`) means the key comes
   out already owned by the account that needs to read it, with no chown
   needed afterward.
6. Place your TLS certificate and key at `ssl/cert.pem` and `ssl/privkey.pem`
   (paths the example systemd unit points `MOJO_SSL_CERT`/`MOJO_SSL_PRIV` at).
   If you're terminating TLS at a reverse proxy instead (e.g. Traefik/nginx in
   front of the app), skip this and change the unit's `ExecStart` to listen
   on plain `http` on a loopback/internal port instead. Make sure
   `plugin-store` can read both files (`sudo chown plugin-store:plugin-store
   ssl/cert.pem ssl/privkey.pem`, and `chmod 600` the private key) if
   whatever process obtained them (e.g. certbot) left them owned by `root`.

   **If you're using certbot** (the actual production setup this app runs
   under, as of 2026-09), point these at certbot's own `live/` symlinks
   rather than copying the files:
   ```bash
   sudo -u plugin-store ln -sf /etc/letsencrypt/live/<your-domain>/fullchain.pem /opt/plugin-store/ssl/cert.pem
   sudo -u plugin-store ln -sf /etc/letsencrypt/live/<your-domain>/privkey.pem /opt/plugin-store/ssl/privkey.pem
   ```
   A one-off `chown`/`chmod` isn't enough here: certbot writes a **fresh**
   file into `/etc/letsencrypt/archive/<your-domain>/` on every renewal, with
   its own default `root:root 600`, then swaps the `live/` symlink to point
   at it — silently discarding whatever ownership fix you applied to the
   previous generation, breaking the site again at the next renewal (found
   the hard way: a real deploy's cert had drifted to permissive `777` after
   repeated manual fixes, each undone by the next renewal). Install a
   certbot deploy hook to reapply it automatically, every time:
   ```bash
   sudo tee /etc/letsencrypt/renewal-hooks/deploy/koha-plugin-store.sh > /dev/null <<'SCRIPT'
   #!/bin/sh
   set -e

   # Runs after EVERY certbot renewal on this host, for every cert it
   # manages -- guard on $RENEWED_LINEAGE (set by certbot for each deploy
   # hook invocation) rather than assuming this is the only cert here.
   case "$RENEWED_LINEAGE" in
       */<your-domain>)
           chown plugin-store:plugin-store "$RENEWED_LINEAGE/privkey.pem" "$RENEWED_LINEAGE/fullchain.pem"
           chmod 600 "$RENEWED_LINEAGE/privkey.pem"
           chmod 644 "$RENEWED_LINEAGE/fullchain.pem"
           systemctl restart koha-plugin-store
           ;;
   esac
   SCRIPT
   sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/koha-plugin-store.sh
   ```
   Certbot picks up everything under `renewal-hooks/deploy/` automatically —
   no further registration needed. Verify the script itself before trusting
   it to run unattended overnight: `sh -n` it for syntax, then invoke it
   manually once with `$RENEWED_LINEAGE` pointed at the real `live/`
   directory (safe — it's idempotent) to confirm it actually fixes
   permissions and restarts the app cleanly, rather than waiting for the
   next real renewal to find out:
   ```bash
   sudo env RENEWED_LINEAGE=/etc/letsencrypt/live/<your-domain> /etc/letsencrypt/renewal-hooks/deploy/koha-plugin-store.sh
   ```

### Fixing mixed ownership

If you ran any of the above as `root` instead of the noted user — an easy
mistake, since `root` can write anywhere and won't hit a permissions error
until the *service* tries to start — fix it before enabling the systemd
units, rather than discovering it as a startup failure (or worse, not
discovering it at all, if a permissive default umask made the affected
files world-readable):

```bash
sudo chown -R plugin-store:plugin-store /opt/plugin-store
sudo chown -R plugin-store-sandbox:plugin-store-sandbox /opt/plugin-store/sandbox_broker
sudo chmod 600 /opt/plugin-store/koha_plugin_store.conf
sudo chmod 600 /opt/plugin-store/signing_key.pem
sudo chmod 600 /opt/plugin-store/ssl/privkey.pem   # if present
```

The order matters: the first `chown -R` covers the whole tree including
`sandbox_broker/`, then the second one narrows just that subdirectory back
to its own user — running them in the other order would leave
`sandbox_broker/` owned by `plugin-store` again.

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
sudo systemctl daemon-reload
sudo systemctl enable --now koha-plugin-store koha-plugin-store-worker koha-plugin-store-sandbox-broker
```

## Upgrading

```bash
cd /opt/plugin-store
sudo -u plugin-store git pull
sudo -u plugin-store carton install --deployment
sudo -u plugin-store-sandbox bash -c 'cd sandbox_broker && carton install --deployment'
sudo -u plugin-store env PERL5LIB=/opt/plugin-store/local/lib/perl5 script/koha_plugin_store migrate
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
