# Koha Plugin Store — Technical Spec (draft v0.1)

## 1. Purpose

A community-run service where developers submit Koha plugins (`.kpz` bundles), submissions
go through automated checks and human review, and Koha instances discover and rate
published plugins from within the staff client.

Two distinct client populations:

- **Developers** — authenticate via GitHub/GitLab/Forgejo OAuth, submit and manage plugins.
- **Koha instances / staff users** — consume a read-mostly discovery API, submit ratings
  and feedback. This is *not* the same identity system as developer login (see §4.2).

## 2. Design decisions

Resolved:

- **Trust is a levelled hierarchy, not a flat badge.** See §6 for the full model:
  automated baseline → static analysis → trusted author → community human review, lowest
  to highest.
- **All submissions run baseline checks regardless of author trust status.** Trust
  attaches to the person for the purposes of level 3, never as a bypass on level 1.
- **Site admins set a minimum installable level** as a Koha system preference. This must
  be enforced server-side (Koha's Perl install code checking against the plugin-store API),
  not merely as a UI filter — a client-side-only filter is trivially bypassed by downloading
  the `.kpz` and installing manually. See §8.
- **Forgejo login is admin-configurable via a config file, not a database table or admin
  UI.** Adding a self-hosted instance (or enabling a preset like Codeberg) means editing
  config and restarting the service. This is a rare, low-frequency operation — it doesn't
  warrant a DB-backed, hot-reloadable admin UI just to avoid a restart. See §4.1.
- **Postgres**, for the non-blocking driver maturity, even though it diverges from Koha's
  own MySQL/MariaDB.
- **This is a single, centralised community store, not a federation of stores.** No
  vendor has asked for their own instance, and there's no concrete driver for it — the
  idea was speculative. Not designing against it: no UUID identifiers, no
  `origin_instance_id` columns, no signed trust claims. If real multi-store demand
  ever shows up, it gets its own design pass then, including an honest look at
  whatever migration that requires — that one-time cost is cheaper than carrying the
  complexity now for a need that may never materialise.
- **The store itself is the signing/certification authority**, not a separate Koha-side
  module and not per-author keys managed locally by each Koha admin. See §4.3.
- **Signing and levels make two different claims, and every surface that shows either
  one must say so explicitly, in plain language, not just imply it via data model
  shape.** "Signed" means authenticity — this file is unmodified since the store
  inspected it. It says nothing about safety or quality, and every published version
  gets signed regardless of level. "Level" means how much scrutiny a version has had,
  independent of signing. A level-1/automated-only version with a valid signature is
  still just level 1; a level-4/community-reviewed version that fails signature
  verification is still refused install. Neither developer-facing copy (§4.3, §12) nor
  the Koha-side install/discovery UI (§8) may collapse these into one combined "trust"
  indicator, and neither may read as a safety guarantee — see §2 open question 3 on
  malware scanning being out of scope, which is exactly the guarantee this distinction
  must not accidentally imply.

Still open:

1. **Human review threshold.** You want a low barrier to entry while still signalling
   quality — those pull against each other, so a straight N-of-M consensus requirement
   probably isn't the answer on its own; it just recreates the QA bottleneck you already
   carry on Koha itself. A workable compromise: single reviewer is sufficient to grant
   level 4, but the reviewer's identity is shown publicly against the grant (accountability
   substitutes for consensus), and any other registered reviewer can raise a dispute that
   forces a second look rather than requiring one up front. Cheap by default, self-correcting
   under scrutiny. Worth trying before building anything more elaborate.
2. **Who authenticates star ratings?** Anonymous per-Koha-instance (one vote per install)
   is what §5 assumes below — easier, but gameable by re-registering an instance. Per-user
   needs Koha to forward some identity, which most libraries' data-protection policies
   won't allow.
3. **Malware/behaviour scanning** is out of scope for v1 — static analysis catches shape,
   not intent. Say so explicitly in the UI rather than implying a guarantee you're not making.

## 3. Tech stack

| Concern | Choice | Notes |
|---|---|---|
| Web framework | Mojolicious | Non-blocking throughout; no blocking DBI calls anywhere in request handlers |
| App server | Hypnotoad | Prefork, `heartbeat_timeout`, graceful hot restart for zero-downtime deploys |
| Reverse proxy | nginx | TLS termination, static asset serving, request buffering in front of Hypnotoad |
| DB driver | `Mojo::Pg` | Non-blocking, connection pooling via `Mojo::Pg::Pool`, migrations built in |
| Background jobs | `Minion` (Pg backend) | Static analysis, OAuth token refresh, webhook delivery, badge recalculation |
| API spec | `Mojolicious::Plugin::OpenAPI` | Gives you request/response validation and a machine-readable spec for the Koha client for free |
| Auth (developers) | `Mojolicious::Plugin::OAuth2` | GitHub, GitLab, and self-hosted Forgejo (OAuth2/OIDC-compatible) as providers |
| Sessions | Signed cookies (Mojo default) for the web UI; short-lived JWTs for API/Koha-client calls | Don't roll your own token format |
| Static analysis | `Perl::Critic`, `perlcompile -c` sandbox check, dependency allowlist check | Run inside Minion workers, not the request cycle |
| Signing | `CryptX` (`Crypt::PK::Ed25519`) | Store's own signing keypair, §4.3 — one key, not a PKI |
| Frontend (submission/review UI) | Vue 3, Options API | Matches your existing stack; served as a separate SPA build, not templated server-side |
| Frontend (Koha client) | Vue 3 component embedded into the Koha staff client | Talks only to the read/rating API, never the review API |
| Testing | `Test::Mojo`, `Test2::V0` | Standard Mojolicious testing idiom |

## 4. Authentication

### 4.1 Developer login (OAuth2, config-file-defined providers)

GitHub and GitLab are single fixed providers and fit `Mojolicious::Plugin::OAuth2` fine.
Forgejo is different: app admins need to register arbitrary self-hosted instances (and
enable presets for known public ones like Codeberg). Adding one is rare — maybe a handful
of times a year — so it doesn't need to be a live, database-backed, no-restart operation.
A config file entry plus a service restart to pick it up is the right amount of
infrastructure for something this infrequent; building a DB table + admin UI + hot-reload
path for it would be solving a problem nobody has.

Recommend a small custom OAuth2/OIDC handler, driven by a section of the app's own config
file (the same `koha_plugin_store.conf`-style file this app already uses for other
secrets) rather than `Mojolicious::Plugin::OAuth2`, whose provider list is also static
config at plugin-registration time but doesn't cover Forgejo/OIDC's URL-derivation needs.
Forgejo's OAuth2 endpoints are Gitea-compatible, so it's a plain authorization-code flow,
nothing exotic to implement by hand:

```
oauth_providers:
  - key: github                    # stable slug, used in routes and the developers table
    kind: github                   # 'github' | 'gitlab' | 'forgejo' | 'oidc_generic'
    display_name: GitHub
    client_id: ...
    client_secret: ...
  - key: gitlab
    kind: gitlab
    display_name: GitLab
    client_id: ...
    client_secret: ...
  - key: codeberg
    kind: forgejo
    display_name: Codeberg
    base_url: https://codeberg.org   # authorize/token/userinfo URLs auto-derived from
                                      # this using the standard Gitea/Forgejo paths
    client_id: ...
    client_secret: ...
  - key: acme-library-forgejo
    kind: forgejo
    display_name: Acme Library Forgejo
    base_url: https://git.acme-library.example
    client_id: ...
    client_secret: ...
```

Loaded once at startup into an in-memory list; there's no runtime "add provider" write
path anywhere in the app. Adding a self-hosted instance, or turning on a preset like
Codeberg, means an admin edits this file (registering an OAuth app on that instance first
to get a `client_id`/`client_secret`, same as today) and restarts the service — Hypnotoad's
graceful hot restart (§9) means that's still zero-downtime for other users, just not
instant for the admin making the change. No admin UI, no `enabled` flag to toggle
independent of a restart, no `created_by_admin_id` audit column — the config file and
normal deploy/ops tooling (version control, config management) already cover "who changed
this and when" for something edited this rarely.

Login flow controller (`GET /auth/:provider_key/start`, `GET /auth/:provider_key/callback`)
looks up the provider by `key` in the loaded config (not a DB query), does the standard
authorization-code exchange with `Mojo::UserAgent` (non-blocking, `->get_p(...)->then(...)`),
and fetches the user's profile from the derived `userinfo_url`.

On first login, create a `developers` row keyed by `(oauth_provider_key, provider_user_id)`
— `oauth_provider_key` is the config's `key` string rather than a foreign key to a DB row,
since providers no longer live in the database. Key on this pair rather than email: emails
aren't guaranteed present or stable across these providers, and you don't want
account-linking bugs from someone's email changing.

Submission is constrained to repos the developer's own OAuth token can see: after login,
`GET /api/v1/developer/repos` lists the repos and orgs the token has access to (via the
provider's own API — GitHub's `/user/repos`, etc.), and plugin submission picks from that
list rather than accepting an arbitrary repo URL. This replaces today's free-text repo URL
field and means a developer can no longer submit a plugin for a repo they don't actually
control.

### 4.2 Koha-instance identity

Recommend a lightweight registration flow: a Koha instance registers once (e.g. via a
Koha system preference or plugin config screen) and receives an API key + instance UUID.
That UUID is what accompanies rating submissions. It's coarser than per-user identity but
avoids libraries having to expose any patron/staff PII to a third-party service — which
most library data-protection policies won't allow anyway.

### 4.3 Store signing authority

The store signs every published plugin version itself, rather than relying on per-author
keys managed locally by each Koha instance (the approach explored and then abandoned in
[bug 24632](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=24632)) or a separate
Koha-side certification module (as independently proposed in
[bug 35837](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=35837) comment #15).
Signing belongs here because the store already reviews and levels each version
individually — a *per-version* signing scope directly answers the objection raised against
the 2020 per-author-key proposal (an author trusted once is not thereby trusted forever): a
later compromise or lapse doesn't retroactively affect anything already issued, and nothing
is signed on reputation alone.

Two distinct claims are involved, and the design keeps them separate:

- **Authenticity** — the file currently at this plugin's origin URL still matches what the
  community store inspected and vouched for. Established by a signature.
- **Quality** — this version passed some set of automated/human checks (§6's levels).
  Established by review, independent of signing.

The store never hosts or re-serves the `.kpz` — that would turn a discovery/rating/
verification service into a bandwidth-heavy file host, which is exactly the operating cost
this design is trying to avoid. It fetches the file from its origin **ephemerally**, the
same fetch the check pipeline (§6) already does to unpack and inspect it, computes a digest,
and discards the bytes. `kpz_url` keeps pointing at the origin (GitHub) throughout, same as
the current app does today.

Mechanism: the store holds an Ed25519 signing keypair. Once it has the digest (from
submission-time or check-pipeline-time fetching, §6 — no dedicated step needed), it signs a
small manifest:

```
{ slug, version, kpz_url, digest (sha256), level, published_at }
```

exposed alongside the version in the discovery API (§7). Every published version is signed
immediately, regardless of level — signing is an authenticity claim, not a quality gate, so
it happens unconditionally rather than being tied to a minimum level. Koha ships with the
store's public key baked in; at install time (§8) it fetches the `.kpz` from `kpz_url`
itself, computes its own digest, and checks that against the signed manifest — replacing any
need for admins to import and manage individual authors' public keys locally.

This does carry forward one tradeoff the current app already has: if the origin (e.g. the
developer's GitHub release) disappears, the plugin becomes uninstallable regardless of what
the store has on record — mirroring the binary would avoid that, at the storage/bandwidth
cost this design deliberately isn't taking on.

This is deliberately not the federation-era "signed trust claims across peers" idea dropped
in §2 — there's exactly one signer (this store), so there's no peer trust policy, no
multi-key verification, no `federation_peers` table. It's a much smaller mechanism: one
keypair, one manifest shape, one verifier.

Separately, whether a developer's own release/tag was itself GPG-signed on GitHub is a
useful *input signal* the check pipeline (§6) can look for and record (a non-required check
contributing to level 2) — that's about trusting what a developer submitted, a different
question from the store's own signature over what it inspected.

**This has to be legible to the people who actually see it, not just correct in the data
model.** A plugin's page in the developer/review UI must state, next to the signature
info, something to the effect of: *"Every published version is signed automatically —
this confirms the file hasn't been altered since the store inspected it. It is not a
safety or quality check; see this version's level for that."* Level and signing status
are shown as two separate labelled facts on that page, never merged into a single score
or badge. This matters most for a first-time developer watching their submission publish
at level 1 with no human reviewer ever having looked at it (§6 point 4) — without this
line, "signed" reads as a stronger endorsement than the store is actually making.

## 5. Data model (core tables)

```
-- oauth_providers is config-file-defined (§4.1), not a DB table — providers are loaded
-- at startup and changed only via a config edit + restart
developers         (id, oauth_provider_key, provider_user_id, username, avatar_url,
                     created_at)
                    -- oauth_provider_key matches a `key` in the config file's provider
                    -- list, not a DB foreign key
plugins            (id, slug, developer_id, name, description, repo_url, documentation_url,
                     created_at)
                    -- documentation_url is recommended, not required, at submission —
                    -- surfaced as a suggestion in the submission flow, never blocks it
plugin_versions    (id, plugin_id, version, kpz_url, changelog, koha_min_version,
                     koha_max_version, status, current_level_id, install_count,
                     content_digest, signature, signed_at, submitted_at, published_at,
                     author_username, author_avatar_url)
                    -- kpz_url points at the origin (GitHub); the store never hosts the
                    -- binary itself (§4.3). content_digest/signature/signed_at are the
                    -- §4.3 authenticity manifest, set unconditionally at publish from a
                    -- digest already computed while fetching for the check pipeline (§6).
                    -- install_count increments on a lightweight ping from the Koha client
                    -- when it actually installs a version (§7) rather than counting bytes
                    -- served, since the store isn't in the download path — a plugin's total
                    -- is SUM() over its versions rather than a separately maintained counter
                    -- author_username/author_avatar_url are a denormalized snapshot of
                    -- whoever GitHub's Release API reports as this specific release's
                    -- author — captured per-version since it can change release to release,
                    -- and deliberately NOT a developer_id FK, since that person may never
                    -- have logged into this store at all. Purely a display/credit field —
                    -- §6's trusted-author check stays keyed to developer_id (the
                    -- store-authenticated submitter), never to this

plugin_contributors (plugin_id, github_username, avatar_url, contributions_count, fetched_at)
                    -- plugin-level (not per-version): the repo's full contributor list from
                    -- GitHub's own Contributors API (one cheap call), re-fetched on each new
                    -- version submission. Deliberately not scoped to commits reachable from
                    -- a specific tag — that would mean cloning full repo history instead of
                    -- just the release tarball, a much bigger operation than anything else
                    -- this store does (§4.3). A credits list, not an authorization concept —
                    -- never checked against trust or ownership

levels             (id, rank, slug, name, description)
                    -- seeded: 1 automated | 2 static-analysis | 3 trusted-author |
                    -- 4 community-reviewed  (rank order = trust order, lowest to highest)
level_history       (id, plugin_version_id, level_id, granted_by, granted_at, reason)
                    -- append-only audit trail; current_level_id is a cache of the
                    -- highest currently-valid level, recalculated by a Minion task

trusted_authors     (id, developer_id, status, added_by_admin_id, added_at, revoked_at, note)
                     -- status: active | revoked — trust attaches to the person, checked
                     -- at submission time, not baked permanently into past versions

review_checks       (id, plugin_version_id, check_name, required, status, output, run_at)
                     -- required=true checks gate publish entirely; required=false checks
                     -- contribute to the "static-analysis" level only
human_reviews        (id, plugin_version_id, reviewer_id, verdict, notes, reviewed_at)
                     -- one approving verdict is sufficient to grant level 4 (see §2.1);
                     -- a later dispute row from a different reviewer forces re-review
                     -- rather than requiring consensus up front

review_comments     (id, plugin_version_id, author_developer_or_reviewer_id, body, created_at)

standard_labels     (id, slug, name, description)
                     -- separate from `levels` — non-exclusive best-practice badges,
                     -- e.g. i18n-ready, translatable-templates, no-external-network-calls
plugin_version_labels (plugin_version_id, standard_label_id, awarded_by, awarded_at)

koha_instances      (id, uuid, api_key_hash, registered_at)
ratings             (id, plugin_id, koha_instance_id, stars, comment, created_at)
```

`status` on `plugin_versions`: `submitted → checks_running → changes_requested → published
→ deprecated`. Model this as an actual enum/state machine, not free-text. A developer
"deleting" a plugin or release (a hackfest-requested capability) is a transition to
`deprecated`, not a hard `DELETE` — it drops out of discovery immediately while the row,
its signature, and its level history stay intact for any Koha instance that already
installed it.

Note the split: **`levels`** is the ordered trust hierarchy from §6 (one active level per
version, computed, not hand-assigned except for the top tier). **`standard_labels`** is the
flat, non-exclusive best-practice badge set from your original brief (i18n, translatable
templates, etc.) — keep these as data an admin can add to without a deploy, they're
orthogonal to trust level.

## 6. Levels model and submission workflow

Four levels, lowest to highest trust:

| Rank | Level | How it's granted |
|---|---|---|
| 1 | Automated | All `required=true` checks pass. This is the *publish gate* — fail one of these and the version never leaves `changes_requested`, regardless of author or reviewers. |
| 2 | Static analysis | All `required=false` checks (the fuller policy/standards set) also pass. Purely computed, no human involved. |
| 3 | Trusted author | Author has an active `trusted_authors` row **at submission time**, and the version has already cleared level 1 (see §2 open question 1 — code still gets checked, trust attaches to the person, not a free pass on the code). |
| 4 | Community reviewed | One or more `human_reviews` rows with verdict `approved`, meeting whatever threshold you land on (§2 open question 2). This can be granted after publish — a version can go live at level 1/2/3 and get promoted to level 4 later as review capacity allows, it doesn't have to block release. |

`current_level_id` is a cache recalculated by a Minion task any time a relevant event
fires (check completes, trusted-author status changes, a human review lands). Recompute
rather than store as monotonically-increasing — if a trusted author is later revoked, a
version that hasn't separately earned level 4 should drop back down, not keep an
inherited rank forever. Keep the full `level_history` regardless, so a plugin's page can
show *why* it holds its current level, not just the badge.

Workflow:

1. Developer points at a tagged release in their repo (§4.1's repo-picker) — there's no
   direct `.kpz` upload path, since accepting one would mean the store hosting that file
   for someone to eventually download, which §4.3 explicitly avoids. Git-tag submission
   also suits CI-driven release workflows better than a manual upload would.
2. Minion job unpacks it, extracts `Koha::Plugin` metadata (name, version, min/max Koha
   version, dependencies), runs the check set:
   - **Required (level 1 gate):** `perl -c` per file (syntax only, no execution),
     manifest completeness (licence, version present), dependency allowlist check
     (flag anything shelling out, opening sockets, or touching the filesystem outside the
     plugin's own directory).
   - **Non-required (level 2):** `Perl::Critic` against a house policy, plus the community's
     [hackfest 2026 CI wishlist](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=35837)
     (comment #13) — presence of a `Development.md`/`Contributing.md`, presence of
     documentation, presence of unit tests, translatable templates, correct use of the
     plugin wrapper on `.tt` pages, no hardcoded credentials, `koha_max_version` present
     (recommended, doesn't block submission), and whether the developer's own release/tag
     was GPG-signed on GitHub (§4.3's "input signal", distinct from the store's own
     signature). Broader automated security-vector scanning was also raised at the same
     hackfest but has no concrete tooling proposed yet — worth revisiting once there is.
3. Results land in `review_checks`; level recalculates automatically once they're all in.
4. If level 1 passed, the version publishes automatically — no human in the loop required
   to go live at all. This is the piece that avoids the QA bottleneck you already know
   about from Koha itself: automated levels don't queue behind human reviewers.
5. Community human review (level 4) is a separate, ongoing queue, decoupled from the
   publish step — reviewers pick up already-published versions and promote them over time.
6. Webhook (optional) notifies the developer's registered URL on level changes, not just
   publish.

## 7. API surface (sketch)

**Developer/review API** (JWT-authenticated, scoped to own plugins + reviewer role):
- `GET /api/v1/developer/repos` — repos/orgs the developer's OAuth token can see (§4.1),
  populates the submission repo-picker
- `POST /api/v1/plugins` / `POST /api/v1/plugins/:slug/versions`
- `DELETE /api/v1/plugins/:slug` / `DELETE /api/v1/plugins/:slug/versions/:version` —
  ownership-checked; transitions to `deprecated` rather than a hard delete (§5)
- `GET /api/v1/plugins/:slug/versions/:version/checks`
- `POST /api/v1/review/:version_id/{approve,request-changes,reject}` (reviewer role only)

**Public discovery API** (consumed by the Koha client, no auth needed for reads):
- `GET /api/v1/discover?q=&label=&koha_version=&page=&per_page=` — text search plus
  pagination, both on the API and mirrored in the web UI's own listing
- `GET /api/v1/plugins/:slug`
- `GET /api/v1/plugins/:slug/versions/latest?koha_version=`
- Version responses include the §4.3 signing manifest (`kpz_url`, `digest`, `signature`,
  `signed_at`) alongside `install_count`, so the Koha client can fetch-and-verify without a
  separate call
- `POST /api/v1/plugins/:slug/versions/:version/installs` — a lightweight ping the Koha
  client fires once it has actually fetched and verified a version, incrementing
  `install_count`. Not a download proxy — the store still never sees the `.kpz` bytes,
  just a signal that an install happened

**Ratings API** (instance API key required):
- `POST /api/v1/plugins/:slug/ratings` `{ stars, comment }`
- Rate-limit and dedupe by `(plugin_id, koha_instance_id)` — upsert, not insert, so an
  instance can revise its own rating rather than stacking duplicates.

Generate this from an OpenAPI YAML up front (`Mojolicious::Plugin::OpenAPI` will validate
against it) — it becomes your contract with the Koha-side client and means the Vue
component can be developed against a mock server before the backend review workflow is
even finished.

## 8. Koha-side client

A small Vue component embedded in the staff client (fits your existing Options API
convention) that:

- Calls the discovery API to list/search plugins, filtered by the instance's own Koha
  version so incompatible plugins don't even show up.
- Renders level/standard labels as badges.
- Posts ratings using the instance API key (stored in a system preference, sent server-side
  from Koha's Perl, not exposed to the browser — the staff client JS should call a Koha
  controller which proxies to the plugin-store API, keeping the API key off the client).
- Does **not** perform installation itself in v1 — recommend keeping "download and install"
  a manual, deliberate action (download `.kpz`, install via existing Koha plugin upload)
  rather than one-click remote install. One-click install of unsandboxed third-party Perl
  is a bigger commitment than a discovery/rating feature needs to make on day one.
- **Minimum-level enforcement is a Perl-side Koha concern, not a JS concern.** A new
  system preference (e.g. `PluginStoreMinimumLevel`) holds the admin's chosen threshold.
  Koha's existing plugin-install code path should call the plugin-store API to check the
  `.kpz`'s current level against that threshold *before* accepting an upload — whether the
  upload came via the discovery client or a manually-downloaded file dragged in by staff.
  Filtering the discovery UI by level is still worth doing for a better browsing
  experience, but it's a convenience, not the enforcement mechanism — anyone can bypass a
  client-side filter, they can't bypass a check in Koha's own install controller.
- **Signature verification replaces per-author key management (§4.3).** Koha ships with
  the store's public key baked in and verifies the `.kpz` digest/signature at install time.
  There's no local key store for admins to maintain, unlike the 2020 approach in bug 24632.
  A signature-verification failure and a below-minimum-level rejection must surface as
  two visibly different errors, not one generic "can't install this" message — the first
  means the file was tampered with, corrupted, or the origin changed unexpectedly under
  a URL the store already vouched for; the second means it hasn't cleared the site's
  chosen review bar yet. Conflating them either hides a tampering event behind a message
  a site admin reads as "just turn the syspref down," or makes a legitimate low-level
  plugin sound like a security incident. Both level badge and signature status render as
  separate, clearly labelled facts in the discovery UI (per §2's design decision above),
  same as on the developer-facing plugin page (§4.3).
- Whether the plugin-store feature is enabled at all, and which staff permissions gate
  viewing/installing store plugins, is an open community discussion on
  [bug 35837](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=35837) (comments
  #6–#11) — a `koha-conf.xml`/syspref toggle plus dedicated permissions, not this store's
  call to make. This spec only needs to expose the API that toggle gates access to.

## 9. Non-blocking / Hypnotoad practicals

- No blocking calls in controllers: `Mojo::Pg` queries via `->db->query_p(...)` chained
  with promises, or `Mojo::IOLoop::Subprocess` for anything CPU-heavy (e.g. don't run
  `Perl::Critic` inline in a worker — always via Minion, which already runs in separate
  processes).
- Hypnotoad config: set `workers` based on core count, `heartbeat_timeout` generous enough
  for slow uploads, and use `hypnotoad.conf`'s `proxy => 1` if nginx sits in front (so
  `X-Forwarded-*` is honoured).
- Fetching a `.kpz` from its origin (submission-time metadata extraction, check-pipeline
  unpacking, §4.3 digest computation) should stream to a temp path rather than buffering
  fully in memory, and the temp file should be discarded once whichever step needed it is
  done — the store never persists the binary (§4.3).
- Minion needs its own worker processes (`minion worker`), run under systemd, separate from
  the Hypnotoad workers.

## 10. Suggested repo layout

```
plugin-store/
  lib/PluginStore.pm              # main app class
  lib/PluginStore/Controller/...
  lib/PluginStore/Model/...       # thin wrappers over Mojo::Pg queries
  lib/PluginStore/Task/...        # Minion task definitions
  lib/PluginStore/OpenAPI/spec.yaml
  migrations/                     # Mojo::Pg migration SQL
  t/                               # Test::Mojo
  frontend/review-ui/             # Vue 3 SPA, developer/reviewer facing
  frontend/koha-client/           # Vue component, built for embedding
  script/plugin_store              # Mojolicious app script
```

## 11. Suggested build order

1. Data model + migrations + OpenAPI spec (contract-first).
2. Developer OAuth login (GitHub + GitLab fixed providers first; config-file-defined
   Forgejo/OIDC providers from §4.1 can follow once the core login flow works).
3. Plugin/version submission, no checks or levels yet.
4. Developer-facing home page rework (§12) — needs login + submission to link to, but
   nothing past that.
5. Minion check pipeline (required + non-required) → levels 1 and 2, fully automated.
6. Publish pipeline — versions go live at level 1/2 with no human step. No object storage:
   `.kpz` stays hosted at its origin throughout (§4.3); this step wires up signing (the
   digest is already available from step 5's fetch) and the install-count ping (§7).
7. Public discovery/ratings API + Koha-side Vue client + Koha controller proxy.
8. Trusted-author admin flow → level 3.
9. Human review queue → level 4.
10. Standard (best-practice) labels — can layer on top of 5–6 once the data's flowing.

## 12. Developer-facing home page

The current home page just duplicates the "All Plugins" listing. Once login (§4.1) and
submission (§6's workflow, `POST /api/v1/plugins`) actually work end-to-end, the home page
should stop being a redundant listing and start being what a first-time visitor actually
needs:

- **What the store is**, in one paragraph — a community-run plugin catalogue for Koha, not
  a general app store.
- **Who this UI is for** — plugin developers submitting and managing their own plugins.
  Koha instances and staff never touch this UI; they consume the discovery API (§7) or the
  embedded Vue client (§8). Say so explicitly, to head off confused librarians/patrons
  landing here expecting a plugin browser.
- **How to join and submit** — a short numbered path (log in via GitHub/GitLab → pick a
  repo → submit a tagged release), linking straight into the actual login/submission
  routes rather than describing them abstractly.
- **What happens to a submission after it's in** — one or two sentences setting
  expectations before a developer's first submission: it gets signed automatically the
  moment it publishes (that's about file integrity, not an endorsement of it), and it
  gets a level reflecting how much automated/human scrutiny it's had so far, which can
  rise after publish as review capacity allows (§6). Worth stating here, not just on the
  plugin's own page (§4.3), since this is where a developer forms their first impression
  of what "signed" and "level" are going to mean for their plugin.

This is server-rendered content in this app's own web UI (not the Koha-embedded Vue client
from §8) — no new backend dependency, so it slots in as soon as login and submission exist
to link to (build order step 4). It doesn't block on the check pipeline, levels, or
discovery API (steps 5–7) — the "join and submit" path reads the same whether or not
automated review is live yet.

---

Flag anything above you'd want to argue with — particularly §2, since those three answers
change quite a bit of what follows.
