# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Koha plugin store: a Mojolicious (Perl) web app where developers submit their
Koha plugins (GitHub repo + tagged `.kpz` releases), and Koha instances can discover
and download them via a REST API. It has two parts:

- **Backend** (this repo) — Mojolicious app + Postgres database + server-rendered
  (`.html.ep`) submission/review UI.
- **Client** — a Vue.js component living in a fork of Koha itself
  ([PTFS-Europe/koha, `plugin_store` branch](https://github.com/PTFS-Europe/koha/tree/plugin_store)),
  which consumes this app's `/api/plugins` endpoint. It is not part of this repo.

This is early/WIP tooling (see `TODO.md`) — expect rough edges: dev-only auth,
regex-based Perl source parsing for plugin metadata.

`koha-plugin-store-spec.md` (untracked) is a **draft v2 rewrite spec** — Postgres,
OAuth2 developer login, a levelled trust/review model, federation. It describes a
target architecture, not the current implementation. Don't assume anything it
describes (tables, endpoints, auth flow) exists in the code yet.

### Documentation map

- [`DEVELOPMENT.md`](DEVELOPMENT.md) — local dev setup (Docker and host), testing GitHub OAuth login
- [`DEPLOYMENT.md`](DEPLOYMENT.md) — running the store in production (systemd units, SSL, signing key)
- [`docs/CERTIFICATION.md`](docs/CERTIFICATION.md) — the automated check pipeline and publish signing
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — workflow, testing, code conventions

## Commands

```bash
docker compose up -d postgres                          # start local Postgres
cpanm --installdeps .                                  # install CPAN dependencies (see cpanfile)
script/koha_plugin_store migrate                        # apply Postgres migrations
script/koha_plugin_store reset_test_data                # wipe and reseed demo developers/plugins/releases
morbo script/koha_plugin_store                          # run dev server with auto-reload
prove -l t/basic.t                                      # run a single test
prove -l t/                                             # run all tests
```

A `koha_plugin_store.conf` file (gitignored) is required at the project root —
copy `koha_plugin_store.conf.example` (host) or `koha_plugin_store.conf.docker.example`
(Docker — these two differ in `pg_dsn`'s host, don't mix them up). It holds
`github_app_token` (a fine-grained, public-repos-read-only PAT for the store's own
background GitHub API calls), `pg_dsn` (Postgres connection string), and
`oauth_providers` (developer login — see DEVELOPMENT.md's "Testing developer
login" section for the full GitHub OAuth App setup walkthrough and the `oauth_mock`
shortcut).

`t/login.t` is stale (marked `#TODO: Redo this, its out of date` in the file
itself) and tests a login flow that doesn't match the current app — don't treat
its failures as regressions.

## Architecture

### Request flow

Routes are all registered in `KohaPluginStore::startup()` (`lib/KohaPluginStore.pm`),
not split into a router class. Developer login is GitHub OAuth
(`Mojolicious::Plugin::OAuth2`, registered from a config-driven `oauth_providers`
list; the flow itself lives in `Controller::Auth`) — there's no password-based
login anymore. Auth is still a single Mojolicious route condition,
`user_authenticated`, checked against `$c->session->{developer}->{id}`; there's no
role/permission system beyond "logged in or not". The developer's GitHub access
token is kept in `session->{github_access_token}` after login (previously
discarded), so later requests can call GitHub's API as the developer. Controllers live in
`lib/KohaPluginStore/Controller/` (`Site`, `Plugins`, `Releases`, `Users`) and
follow standard Mojolicious controller conventions.

### Data layer — a thin Mojo::Pg CRUD wrapper

- `KohaPluginStore` (the app class) holds a lazy `pg` attribute (`has pg => sub {...}`)
  that builds a `Mojo::Pg` connection from `koha_plugin_store.conf`'s `pg_dsn` on first
  access — no class-level singleton. Controllers reach it via the `$c->pg` helper;
  commands via `$self->app->pg`.
- `KohaPluginStore::Model::Base` — base class for `Model::{Plugin,PluginVersion,Developer}`,
  taking `pg` and `data` as constructor-injected attributes (`has 'pg'`, `has 'data'`).
  `Model::Developer` replaced `Model::User` — developers are keyed by GitHub identity
  (`oauth_provider_key`, `provider_user_id`), not username/password, and
  `plugins.developer_id` replaced `plugins.user_id`.
  Each subclass declares `_table` (the Postgres table name) and `_columns` (used for
  `INSERT ... RETURNING`). `create`/`find`/`search` are built on `Mojo::Pg::Database`'s
  `insert`/`select` query builder. Column accessors (`->id`, `->name`, etc.) are still
  synthesized via `AUTOLOAD`, but now read/write directly against the fetched row's hash
  rather than reflecting a DBIx::Class result object's columns.
- Migrations are SQL statements embedded in `KohaPluginStore::Command::migrate`'s `__DATA__`
  section (Mojo::Pg's built-in `-- 1 up`/`-- 1 down` format), loaded via `from_data` scheme.
  The `migrate` command is a `Mojolicious::Command` class registered in `startup()` via
  `push @{$self->commands->namespaces}, 'KohaPluginStore::Command'`. Similarly, `reset_test_data`
  is a `Mojolicious::Command` class that wipes and reseeds demo data.
- `plugin_versions` is the Postgres name for what used to be SQLite's `releases` table;
  the Perl class is `KohaPluginStore::Model::PluginVersion` (was `Model::Release`).

### Plugin submission workflow (`Controller::Plugins`)

The interesting/fragile logic lives here:

Plugin submission picks from `GET /api/v1/developer/repos` (the developer's own
public GitHub repos, fetched via `KohaPluginStore::GitHub::fetch_public_repos`
using the access token stored in session at login) rather than accepting an
arbitrary URL — `new_plugin` re-validates the submitted repo against that same
list server-side, since the dropdown alone doesn't stop a hand-crafted request.

1. The developer picks a repo (constrained to their own public GitHub repos, §above) and
   a specific tagged release (`GET /repos/.../releases`, via the store's own
   `github_app_token` -- not the developer's login token). `new_plugin_confirm`/
   `new_release` re-fetch that exact release server-side, create the `plugins`/
   `plugin_versions` rows immediately with `status = 'submitted'`, and enqueue a Minion
   job -- they never download or parse anything themselves.
2. `KohaPluginStore::Task::ProcessPluginVersion` (the `process_plugin_version` Minion
   task) does the actual work: downloads the `.kpz` to a temp directory (never a
   permanent cache), extracts it, walks the tree for a file with `use base`/`use parent
   ... Koha::Plugins::Base`, regex-extracts the `our $metadata = { ... }` hash literal
   (same fragile-by-design approach as before -- parsing text, not executing the plugin),
   fetches the repo's contributors, computes a SHA-256 `content_digest`, and sets the
   version's `status` to `published` or `changes_requested` (with `error_message`)
   accordingly.
4. On publish, `KohaPluginStore::Signing` builds and signs a small manifest (`slug`,
   `version`, `kpz_url`, `digest`, `published_at`) with the store's Ed25519 key
   (`koha_plugin_store.conf`'s `signing_key_path`, generated via `script/koha_plugin_store
   generate_signing_key`), storing both the exact signed JSON string
   (`plugin_versions.signed_manifest`) and the signature (`signature`) verbatim.
   `certification_tier` is deliberately excluded from the signed content -- it's a
   separate, re-assessable quality claim, exposed alongside the signature rather than
   frozen inside it, so a later re-certification never needs a re-sign.
5. `GET /api/plugins/verify?digest=<sha256hex>` looks up a published version by its
   `content_digest` and returns `{ signed_manifest, signature, certification_tier }` --
   this is how a Koha instance verifies a manually-uploaded `.kpz` (which has no
   `kpz_url` to match against the discovery listing), not just ones fetched via the
   discovery client.
6. `GET /plugins/:slug` is the public page a developer watches while their submission
   processes -- it auto-refreshes every 5 seconds while any version is
   `submitted`/`checks_running`.

**Note:** A Minion worker process must be running for submissions to ever leave `status = 'submitted'`. Locally: `perl script/koha_plugin_store minion worker`. In Docker: the `worker` service in `docker-compose.yml`.

`/api/plugins` (`list_all`) is the public, unauthenticated, CORS-enabled endpoint
the Koha-side Vue client calls; it filters releases by `koha_version_release`
(compatible minimum Koha version) passed as a query param.

### Check pipeline (certification)

`KohaPluginStore::Task::ProcessPluginVersion` runs every class listed in
`KohaPluginStore::Checks::@ALL` (11 checks, see `docs/CERTIFICATION.md`
for what each one verifies) sequentially, in-process, inside the same
Minion job that already unpacked the `.kpz` and parsed metadata — not fanned
out to separate jobs, since the catalogue is small and only one check
(`perl_syntax`) is slow enough to matter.

- Each check is a `KohaPluginStore::Check::Base` subclass exposing
  `check_name`, `required` (gates publish), `gates_certification` (gates the
  `CERTIFIED` tier without blocking publish), and `run($extract_dir,
  $metadata, $context)` returning `{ passed => bool, message => str|undef }`.
  `Base` supplies `find_files($dir, $regex)` for the file-scanning checks.
- `$context` carries `repo_url`/`tag_name`/`github_token` — `gpg_signed_tag`
  uses it to call GitHub's tag-verification API, and `tests_presence` uses it
  to check the tagged commit's tree for a `t/*.t` file, since the `.kpz`
  never packages tests.
- A check `die`-ing with a `check_infrastructure_error` prefix (currently only
  `perl_syntax`, if it can't prepare the sandboxed Koha checkout) is treated
  differently from a normal failure: the job sets `status = 'check_error'`
  and stops immediately, rather than recording it as the plugin's own fault.
- Every result — required checks and gating checks alike — is upserted into
  `review_checks` (`Model::ReviewCheck->record`, unique on
  `(plugin_version_id, check_name)`, so re-running is idempotent) regardless
  of pass/fail, before tier computation happens.
- `certification_tier` (`INCOMPLETE` / `STRUCTURAL` / `CERTIFIED`) is computed
  once, after all 11 have run: any required-check failure → `INCOMPLETE` and
  `status` stays `changes_requested`; otherwise any gating-check failure →
  `STRUCTURAL`; otherwise `CERTIFIED`. Both are set together with `status =>
  'published'` in one `update`.
- `perl_syntax` is the one check that shells out to Docker (`docker run --rm
  --network none --memory 256m --cpus 0.5 --read-only`, wrapped in `timeout
  --signal=KILL 30`) to run `perl -cw` against a cached shallow clone of the
  Koha tag matching the plugin's `minimum_version`. This means the app's own
  container (or host) needs Docker socket access and network egress to
  `git.koha-community.org` the first time each Koha version is needed;
  subsequent checks reuse the cached checkout under `/app/tmp/koha-checkouts`
  (overridable via `$context->{koha_checkout_cache_dir}`). In the Docker
  Compose dev setup, `worker` reaches Docker by bind-mounting the *host's*
  socket (`/var/run/docker.sock`) rather than running a nested `dockerd` --
  which means bind-mount sources it passes to `docker run` (this cache dir,
  and the plugin extraction tempdir in `ProcessPluginVersion`) must be paths
  that resolve identically on the true host and inside `worker`, since the
  host's daemon is what actually resolves them. `/app/...` works because
  `docker-compose.yml` already bind-mounts the whole worktree there; the
  container's own private `/tmp` would not work and would silently bind-mount
  an empty directory instead of the real one.
- `perl_critic` depends on `Koha::QA::PerlCritic`, which — unlike everything
  else in `cpanfile` — isn't on CPAN. See the `cpanfile` comment for the
  exact `cpanm -L local --force <git-url>@<ref>` install command; it must
  land in a project-local `local/` (its `Makefile.PL` pins an exact
  `Perl::Tidy` version that would otherwise get silently upgraded machine-
  wide by `Perl::Critic`'s own dependency resolution), and anything that
  loads it — the app, `minion worker`, and `prove` — needs
  `PERL5LIB=$(pwd)/local/lib/perl5` set first.

### Templates

Server-rendered Mojolicious `.html.ep` templates under `templates/`, Bootstrap-based,
static JS/CSS in `public/assets/`. No frontend build step for this half of the
project — the Vue client is entirely separate (see above).
