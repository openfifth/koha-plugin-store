# Plugin Discovery API — OpenAPI Contract Design

**Status:** proposed
**Repos affected:** `koha-plugin-store` (this repo) and Koha core (`bug_35837` branch)

## 1. Problem

The store's plugin discovery endpoint (`GET /api/plugins`, `Controller::Plugins::list_all`)
predates this repo's `/api/v1` OpenAPI setup entirely — it's a bare, undocumented route.
Concretely, today it:

- Accepts exactly one query param, `koha_version_release` (required), and nothing else —
  no text search, no sort, no pagination.
- Forces the Koha-side client (`SearchModal.vue`) to fetch the *entire* catalog on every
  search-modal open and filter name/description/author client-side in JavaScript.
- Runs an N+1 query pattern server-side: one query for all plugins, then one query per
  plugin for its published releases.
- Filters compatibility with a fragile comparison: `next if $release->koha_min_version >
  $koha_version_release` — plain Perl string/numeric `>` over free-text, author-supplied
  version strings, with **no upper bound at all** (`koha_max_version` isn't a stored,
  queryable column — `Check::KohaMaxVersion` only checks whether the manifest *mentions* a
  `maximum_version` key, as a non-blocking recommendation).

None of this is under contract — no OpenAPI spec, no documented shape, nothing validating
requests or responses. `GET /api/plugins/verify` (digest lookup, consumed by
`Koha::Plugins::Store::lookup_by_digest`) has the same problem, just with a narrower surface.

## 2. Scope

**In scope:**
- Move both endpoints under the existing `/api/v1` OpenAPI spec (`lib/KohaPluginStore/OpenAPI/spec.yaml`), as public (unauthenticated) operations.
- Real server-side filtering (`q`), pagination (`_page`/`_per_page`), and sorting (`_order_by`), using Koha core's own REST API conventions rather than inventing new ones.
- Replace the N+1 release-fetch with a two-query batch pattern.
- Make Koha-version compatibility filtering correct: add a real, stored, enforced `koha_max_version`; normalize both bound fields into a safely-comparable canonical form at write time.
- Update both consumers in the same change: `Koha::Plugins::Store` (Perl) and `SearchModal.vue`/`plugin-store-api-client.js` (Vue).

**Out of scope (explicit deferrals, not gaps):**
- The ratings API and install-count ping (§4.2/§7 of the main store spec) — still fully unbuilt on both sides, unrelated to this change.
- A Koha-side proxy controller for discovery. The original spec's rationale for proxying is specifically the ratings API's API key, which must stay server-side — the discovery API is explicitly "no auth needed for reads." Keep the browser calling the store directly via CORS; revisit centralizing everything (including discovery) behind one Koha controller once the ratings proxy gets built, for consistency rather than because CORS itself is a problem.
- `label=` filtering — the community "standard/best-practice" labels feature doesn't exist yet (still an open item in this repo's own `TODO.md`). Documenting a param with no backing data would be premature.
- `Link` response headers (RFC 5988 prev/next/first/last) — real implementation weight, no client need yet. `X-Total-Count` alone is enough for now; addable later without a contract break.
- Pagination UI in `SearchModal.vue` — fetch a generous first page (`_per_page=100`) instead of building page controls, until the catalog actually outgrows that.

## 3. Route contract

Both operations are added to the existing `spec.yaml` under `/api/v1`, with a per-operation
security override (no `session_auth` requirement) since these are public reads — the same
mechanism already available via `Mojolicious::Plugin::OpenAPI`, just applied per-operation
instead of at the route-group level.

The old unversioned `/api/plugins` and `/api/plugins/verify` routes are **deleted outright,
not aliased**. Confirmed there is no consumer of either beyond `SearchModal.vue` and
`Koha::Plugins::Store` (both updated in this same change) — the store's own web UI is
server-rendered and never calls its own discovery API.

### `GET /api/v1/plugins`

| Param | Required | Meaning |
|---|---|---|
| `koha_version` | yes (renamed from `koha_version_release`) | The calling Koha's version string. Only releases compatible with this version are returned. |
| `q` | no | Case-insensitive substring match against plugin `name` OR `description`. |
| `_page` | no, default `1` | Koha REST convention. |
| `_per_page` | no, default `20` | Koha REST convention. `_per_page=-1` means unlimited (used internally by `Koha::Plugins::Store::lookup_by_kpz_url`, which needs the full catalog to scan for a matching `kpz_url`). |
| `_order_by` | no | CSV, `+`/`-` prefix per field (Koha REST convention). Supported fields to start: `name`. |

Response body: unchanged shape — a JSON array of plugin objects, each with a nested
`releases` array (only published, compatible releases). No envelope wrapper.

Response headers: `X-Total-Count` (total matching **plugins**, not release rows, consistent
with pagination being over plugins — see §5). No `Link` header (see §2).

Errors: `400` if `koha_version` is missing (matches today's existing behavior for
`koha_version_release`).

### `GET /api/v1/plugins/verify`

Unchanged request/response shape from today — relocated to `/api/v1` for consistency and
documented in the same spec file, since it's the same "public discovery-family, no auth"
pattern and touches the same controller file.

## 4. Data model changes

**New column:** `plugin_versions.koha_max_version TEXT NULL` (nullable — absent means no
upper bound, so existing submissions that never declared one keep working unmodified).

**Normalization, not just validation.** Koha core already has a battle-tested, generic
version comparator for exactly this shape of problem —
`Koha::Plugins::Base::_version_compare` (splits on `. + : ~ -`, pads missing segments with
`0`, compares segment-by-segment numerically; used today to compare a plugin's own version
across upgrades). This store can't `use Koha::Plugins::Base` directly (separate app), but
mirrors the same algorithm: at write time (`ProcessPluginVersion.pm`), parse
`minimum_version` and, if present, `maximum_version` by splitting on the same delimiter
set, and canonicalize into a fixed zero-padded form (`sprintf("%02d.%02d.%02d.%03d", ...)`,
padding missing trailing segments with `0`). Storing the canonical form means a later plain
`TEXT` comparison in SQL is safe — the normalization work happens once, at write time, not
on every query.

**Validation:** `ProcessPluginVersion.pm`'s existing check (currently: reject with
`changes_requested` if `minimum_version` is missing entirely) extends to also reject if
`minimum_version`, or a *present* `maximum_version`, doesn't parse as a dotted-numeric
version. A missing `maximum_version` stays valid (means "no ceiling"); a present-but-malformed
one does not, since it would silently corrupt every future compatibility query otherwise.

**Backfill:** existing `plugin_versions` rows have unvalidated, un-normalized
`koha_min_version` text. A one-off migration script re-parses and canonicalizes existing
values using the same algorithm. Rows that fail to parse are flagged (logged) for manual
review rather than rejected or deleted — we can't retroactively un-publish an already-live
plugin version over a data-quality issue; whoever runs the migration decides what to do
with any flagged rows.

## 5. Query strategy (fixing the N+1)

The existing nested-response decision (plugin objects with a nested `releases` array,
retained from the earlier discovery-contract discussion) means pagination is **over
plugins**, not over individual releases. A single flattened `JOIN` naturally produces one
row per (plugin, release) pair, which doesn't paginate cleanly against "N plugins per
page" — so the fix is two queries, not one:

1. **Page of matching plugin IDs.** One query against `plugins` JOINed to
   `plugin_versions` (`status = 'published'`, the `koha_min_version`/`koha_max_version`
   range check against the caller's `koha_version`, and the `q` filter against name/
   description), `GROUP BY`/`DISTINCT` on plugin id, ordered and paginated
   (`LIMIT`/`OFFSET` derived from `_page`/`_per_page`). A sibling `COUNT(DISTINCT
   plugin.id)` query (same `WHERE`, no `LIMIT`) produces `X-Total-Count`.
2. **Batch-fetch releases.** One query fetching all published, compatible releases
   `WHERE plugin_id IN (...)` for exactly the plugin IDs from step 1, then assembled
   in Perl into each plugin's `releases` array (replacing today's per-plugin loop).

Two queries total, regardless of page size — down from `1 + N`.

## 6. Store-side implementation

- `KohaPluginStore::Model::Plugin`: `search` gains `q` (name/description `ILIKE`),
  pagination (`limit`/`offset`), and `order_by` support; needs a sibling method (or a
  `count` flag) for the total-count query.
- `KohaPluginStore::Model::PluginVersion`: gains a batch-fetch-by-plugin-ids method and the
  min/max version range condition; `_columns` gains `koha_max_version`.
- `Controller::Plugins::list_all` rewritten around the two-query pattern in §5, parsing
  `_page`/`_per_page`/`_order_by`/`q`/`koha_version` from `$c->req->query_params`, and
  setting `X-Total-Count`.
- `Controller::Plugins::verify` moves under `/api/v1`, otherwise unchanged.
- Existing CORS headers (`Access-Control-Allow-*`) are preserved as-is — this remains a
  publicly, cross-origin-called endpoint regardless of moving under OpenAPI.
- `lib/KohaPluginStore/OpenAPI/spec.yaml` gains both operations, each with a per-operation
  security override removing the `session_auth` requirement.

## 7. Koha-side changes (`bug_35837` branch)

- `Koha/Plugins/Store.pm`: both `lookup_by_kpz_url` and `lookup_by_digest` move to
  `/api/v1/plugins` and `/api/v1/plugins/verify`; `lookup_by_kpz_url` renames
  `koha_version_release` to `koha_version` and adds `_per_page=-1` (it needs the full
  catalog to scan for a matching `kpz_url` — Koha's own "unlimited" idiom, not a special
  case we invent).
- `SearchModal.vue` / `plugin-store-api-client.js`: URL and param rename; the client-side
  JS name/description filter (`filteredPlugins`) is replaced by sending `q` to the server
  (debounced on input) — this is the actual functional improvement the original question
  was about. Fetch `_per_page=100` (or similar) rather than building pagination UI (§2).

## 8. Testing

- **Store:** controller tests for `list_all`/`verify` covering `q`, `koha_version`
  min/max-bound filtering (including the no-`koha_max_version` = no-ceiling case),
  `_page`/`_per_page`/`_order_by`, and the `X-Total-Count` header. Unit tests for the
  version-normalization function (valid/invalid/short-segment/long-segment inputs) and for
  the backfill script's flagging behavior on unparseable input.
- **Koha:** update `t/Koha/Plugins/Store.t`'s mocked URLs/params for both lookup methods
  (existing `Test::MockModule` pattern against `Mojo::UserAgent`, no new test *shape*
  needed). `SearchModal.vue` has no existing test infrastructure (confirmed — no
  `.test.js`/`__tests__` for any Plugin-store Vue file, matching the rest of this feature
  area) — manual verification only: search-as-you-type against `q`, and confirm a plugin
  whose `koha_max_version` is below the dev instance's version is correctly excluded.

## 9. Out of scope

See §2 for the explicit deferral list (ratings/install-ping, Koha-side proxy, `label=`
filtering, `Link` headers, pagination UI). Additionally:

- The store's own web UI listing (server-rendered, doesn't consume this API) is unaffected.
- `Koha::Plugins::Search` (the dead, uncalled Perl class predating the SPA) is being removed
  in a separate, already-committed patch — unrelated to this contract.
