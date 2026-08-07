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
`github_user_access_token` (for GitHub API calls), `pg_dsn` (Postgres connection
string), and `oauth_providers` (developer login — see README's "Testing developer
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

1. `new_plugin`/`edit_form` call the GitHub API (latest release / release list)
   using the configured `github_user_access_token`.
2. The release's `.kpz` asset is downloaded and unzipped into `kpz_packages/`
   (`_download_plugin`) — this directory is gitignored and acts as a cache
   (`_download_plugin` short-circuits if the target file already exists).
3. `_get_plugin_class_file_and_name` walks the extracted plugin directory
   looking for a file with `use base`/`use parent ... Koha::Plugins::Base`, then
   extracts the `package` name from it.
4. `_get_plugin_metadata` regex-extracts the `our $metadata = { ... }` hash
   literal out of the plugin's Perl source (resolving `$variable` references
   used inside it) and `eval`s it into a real hashref. This is parsing Perl
   source with regexes, not executing/requiring the plugin module — fragile by
   design, but avoids loading untrusted third-party plugin code into the store
   process.
5. `new_plugin_confirm` persists the `Plugin` + first `Release` rows once a
   logged-in user confirms the parsed metadata.

`/api/plugins` (`list_all`) is the public, unauthenticated, CORS-enabled endpoint
the Koha-side Vue client calls; it filters releases by `koha_version_release`
(compatible minimum Koha version) passed as a query param.

### Templates

Server-rendered Mojolicious `.html.ep` templates under `templates/`, Bootstrap-based,
static JS/CSS in `public/assets/`. No frontend build step for this half of the
project — the Vue client is entirely separate (see above).
