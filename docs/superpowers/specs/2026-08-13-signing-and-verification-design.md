# Publish Signing & Digest Verification — Design

**Status:** Approved for planning
**Relates to:** `koha-plugin-store-spec.md` §4.3 ("Store signing authority") and §7 ("API
surface"). This is build-order step 6 (partial — the install-count ping half of step 6 is
explicitly deferred; see "Out of scope" below) plus a small addition to step 7's discovery
API and a small retrofit to step 4's already-shipped home page.

## Summary

`ProcessPluginVersion` already computes a SHA-256 `content_digest` for every version at
check-pipeline time, but nothing signs it, and the discovery API (`GET /api/plugins`)
currently exposes each version as a raw, unfiltered dump of its DB row (`->unblessed`) rather
than a deliberate public shape. This design adds the store's Ed25519 signing scheme from
spec §4.3: sign a small manifest at the exact moment a version is marked `published`, store
the signed artifact verbatim, and expose it through both the existing discovery listing and
a new digest-lookup endpoint that also covers plugins installed by manually uploading a
`.kpz` file rather than fetching one via the discovery client.

## Section 1: Architecture & components

- **New module `KohaPluginStore::Signing`** — pure functions, no file I/O of its own:
  - `build_manifest($plugin, $version)` → hashref `{ slug, version, kpz_url, digest,
    published_at }` — deliberately excludes `certification_tier`; see Section 2.
  - `canonical_json($manifest)` → sorted-key JSON string via `JSON->new->canonical->utf8`
    (`JSON` is already a cpanfile dependency). Deterministic regardless of Perl hash
    iteration order.
  - `sign($json_string, $private_key_pem)` → base64-encoded signature, using
    `Crypt::PK::Ed25519` (new cpanfile dependency, from `CryptX`).
  - `verify($json_string, $signature_b64, $public_key_pem)` → bool. Used by this app's own
    tests; real verification happens in Koha-core, out of scope here.
- **Key management**: a new `script/koha_plugin_store generate_signing_key <path>`
  Mojolicious::Command (same pattern as the existing `migrate`/`reset_test_data` commands)
  writes a fresh Ed25519 keypair to `<path>`, refusing to overwrite an existing file unless
  `--force` is given. `koha_plugin_store.conf` gains a `signing_key_path` entry (a file path,
  not the key material itself — consistent with keeping secrets out of the config file,
  unlike `github_app_token`'s current convention). The key file is read fresh once per
  Minion job run, not cached at app-startup — signing isn't a hot path, and this avoids any
  stale-key-after-rotation concern for free.
- **Trigger point**: `ProcessPluginVersion.pm`'s existing publish-time update — the same
  call that already sets `status => 'published'`, `content_digest`, `version`,
  `koha_min_version`, `certification_tier` in one `$version->update({...})` gains two more
  fields in that same call: `signed_manifest` and `signature`.
- **Data model**: two new columns on `plugin_versions`: `signed_manifest TEXT`,
  `signature TEXT`. Both `NULL` for any version that isn't `published`.

## Section 2: Data flow, signing mechanics, and error handling

**Manifest field mapping** (all already known at the exact moment a version is marked
published):

- `slug` ← `plugins.slug`
- `version` ← `metadata->{version}` (the same value being written to `plugin_versions.version`
  in this same update)
- `kpz_url` ← `plugin_versions.kpz_url`
- `digest` ← the `content_digest` already computed earlier in the same job run
- `published_at` ← computed fresh in Perl at signing time
  (`Mojo::Date->new(time)->to_datetime`), **not** reused from the GitHub release's
  `date_released`. A submission can sit in `changes_requested` for a while before eventually
  passing, so "when the store actually vouched for this" is a distinct, more honest
  timestamp than "when the developer cut the release." No separate DB column is needed for
  it — it only has to exist inside the signed manifest.

**Deliberately excluded: `certification_tier` ("level").** The spec's own §4.3 sketch of the
manifest shape included `level` alongside the authenticity fields, but that couples two
things the same section explicitly says must stay independent: *"Authenticity... established
by a signature. Quality... established by review, independent of signing."* Baking the tier
into the signed content would mean any future re-certification of an already-published
release — adding a new check, or fixing a check bug, exactly as happened today with
`docs_presence` and `perl_syntax` — would either leave the signature attesting to a stale
tier, or force a needless re-sign of content that never actually changed. `certification_tier`
stays exactly what it already is: a plain, independently-updatable column, exposed
alongside the frozen signature (Section 3) rather than frozen inside it. Everything else
above is a fixed fact about this specific already-published row that never changes after
signing, so there's no equivalent tension for `slug`/`version`/`kpz_url`/`digest`/
`published_at`.

**Canonical serialization**: `JSON->new->canonical->utf8->encode($manifest)`. This exact
string is both what gets signed and what gets stored in `signed_manifest` — nothing ever
reconstructs it independently at read time, which is what makes this design robust against
future drift (a renamed tier constant or reordered hash months from now can't retroactively
invalidate a historical signature, since the historical record is frozen verbatim at the
moment it was actually made).

**Signing**: `Crypt::PK::Ed25519->new($private_key_pem)->sign_message($json_bytes)`,
base64-encoded for storage in `signature`.

**Error handling**: a signing key that can't be loaded (missing file, unreadable, malformed
PEM) is an infrastructure problem, not a plugin defect — the same category as the
Docker/checkout failures already handled elsewhere in this task. Rather than inventing a new
caught-error path, let it `die` naturally out of `ProcessPluginVersion::run()`, failing the
whole Minion job so its existing `attempts => 3` retry applies. The version's status simply
stays at `checks_running` until a retry succeeds; three exhausted attempts surfaces as a
stuck job an operator needs to investigate (a real key-configuration problem, not something
a plugin author can fix).

## Section 3: Discovery API changes and the digest-lookup endpoint

**`Controller::Plugins::list_all` (`GET /api/plugins`)** moves from `->unblessed` to an
explicit per-version field list. Kept conservative, since a separate, ongoing effort is
modernizing the Koha-side consumer of this exact endpoint in parallel: everything currently
exposed stays (`name`, `tag_name`, `version`, `koha_min_version`, `kpz_url`, `date_released`,
`content_digest`, `certification_tier`, `author_username`, `author_avatar_url` — notably
including `certification_tier`, since `Koha::Plugins::Store::lookup_by_kpz_url` already
reads it today; dropping it would regress that existing consumer), dropping only
`error_message` and `status` (internal review artifacts — `error_message` is always `NULL`
and `status` is
always `'published'` by the time a version reaches this endpoint, since the published-only
filter added earlier already excludes everything else), and adding `signed_manifest` +
`signature`.

**New: `GET /api/plugins/verify?digest=<sha256hex>`** — public, no auth, same CORS headers
as `list_all`. Answers a question the discovery listing alone can't: given the SHA-256 of
some `.kpz` bytes a Koha instance already has — however it got them, including a `.kpz` a
staff member manually downloaded and uploaded directly, bypassing the discovery client
entirely — did the store ever sign matching content?

- Validates the digest is 64 hex characters; `400` if not.
- Looks up `plugin_versions` where `content_digest = ?` and `status = 'published'` (belt-
  and-braces alongside `signed_manifest IS NOT NULL`, since both are only ever set together
  at publish time).
- Found → `200` with `{ signed_manifest, signature, certification_tier }`. The manifest
  itself carries `slug`/`version`/`kpz_url`/`digest`/`published_at` — the fixed authenticity
  facts. `certification_tier` rides alongside as a plain, current field, not inside the
  signed content (Section 2), so a caller checking minimum-level enforcement always sees
  today's assessment, even if it's been re-run since the version was first signed.
- Not found → `404`. This is the meaningful "no" — the store never signed anything matching
  these exact bytes.
- `content_digest` isn't a unique column. In the practically-near-impossible case of two
  rows sharing a digest, order by most recent (`id DESC`) and return that one — a digest
  match is an identity claim regardless of which specific submission record produced it.

**Not implemented here, flagged for coordination**: Koha-core's `Koha::Plugins::Store`
(`bug_35837`) currently enforces `PluginStoreMinimumLevel` via
`lookup_by_kpz_url($kpz_url)` — an exact-URL match against the discovery listing. That
can never succeed for a manually-uploaded `.kpz`, which has no associated URL at all, only
bytes. Once this endpoint exists, Koha-core's enforcement should move to computing a digest
of whatever bytes it has and calling `GET /api/plugins/verify` instead — strictly more
robust even for the discovery-driven case (a digest match is identity; a URL match could
coincidentally collide or be spoofed), and the only way manual uploads get covered at all.
This endpoint's `certification_tier` field is exactly what that enforcement would check
against the `PluginStoreMinimumLevel` threshold. This is Koha-core work, not this repo's, and
is currently touched by a separate, ongoing effort — raise it there rather than implementing
it as part of this piece of work.

## Section 4: UI legibility

Spec §2 and §4.3 (updated 2026-08-13) require that signing and level never collapse into one
combined "trust" indicator on any surface that shows either — each must be a separately
labelled fact, with signing's meaning stated in plain language, not just implied by badge
placement.

- **`templates/plugins/show.html.ep`** — the Releases tab's versions table already renders a
  bare certification-tier badge per version (`<span class="badge ...">CERTIFIED</span>`).
  Published versions (the only ones with a non-`NULL` `signature`) get a second, visually
  distinct "Signed" badge next to it. Rather than repeating explanatory copy on every row,
  add one clear statement once, below the table, covering what every "Signed" badge in that
  table means: *"Every published version is signed automatically — this confirms the file
  hasn't been altered since the store inspected it. It is not a safety or quality check; see
  each version's certification badge for that."*
- **`templates/site/index.html.ep`** — the logged-out home page's existing "How to join"
  numbered list gets one new short paragraph immediately after it, setting expectations
  before a developer's first submission: it gets signed automatically the moment it
  publishes (file integrity, not an endorsement), and it gets a certification tier reflecting
  how much automated/human scrutiny it's had so far, which can rise later as review capacity
  allows.

Both are template-only changes — no new backend work beyond what Sections 1–3 already
provide (a "signed" boolean is simply "does this version have a non-`NULL` `signature`").

## Section 5: Testing

- **`t/signing.t`** (new) — tests `KohaPluginStore::Signing` directly: `build_manifest`
  produces the right shape; `canonical_json` is deterministic regardless of input hash key
  order; sign→verify round-trips correctly with a freshly-generated ephemeral test keypair,
  and fails against a wrong public key or a tampered JSON string. Crypto runs for real here
  (Ed25519 operations are microseconds) — no mocking, since correctness of the actual
  cryptographic round-trip is the entire point.
- **`t/command_generate_signing_key.t`** (new) — the key-generation command writes a valid
  keypair to a given path, refuses to overwrite an existing file without `--force`, and does
  overwrite with it.
- **`t/task_process_plugin_version.t`** (extend) — a version that reaches `published` gets
  `signed_manifest`/`signature` populated, and verifying them against the test's known public
  key succeeds; a missing/misconfigured signing key causes the job to fail loudly (propagates
  as a real die, not swallowed).
- **`t/api_plugins.t`** (extend) — a published version's response includes
  `signed_manifest`+`signature`; explicitly asserts `error_message`/`status` are no longer
  present (regression test for the curation), while confirming existing fields (`name`,
  `tag_name`, `kpz_url`, etc.) are unchanged.
- **`t/api_plugins_verify.t`** (new) — unknown digest → `404`; malformed digest (not 64 hex
  chars) → `400`; known digest matching a published version → `200` with
  `{signed_manifest, signature, certification_tier}`; a digest belonging to a non-published
  version → `404` (its `signed_manifest` is `NULL`, since signing only ever happens at
  publish time); CORS headers present.
- **`t/plugins_show.t`** (extend) — a published version's row shows the "Signed" badge and
  the explanatory copy; a non-published version (visible only to the owner, per the earlier
  Details/Releases design) does not show a "Signed" badge, since it has no signature yet.

## Out of scope

- **Install-count ping** (`POST /api/plugins/:slug/versions/:version/installs`, spec §7) —
  explicitly deferred. There's no Koha-instance-identity system yet (spec §4.2's API-key +
  instance-UUID registration flow isn't built), so an unauthenticated increment endpoint
  today would be trivially inflatable with no way to dedupe. Revisit once §4.2 exists.
- **Koha-core changes** — neither `Koha::Plugins::Store::lookup_by_kpz_url`'s replacement nor
  any Koha-side signature verification is implemented here (see Section 3's coordination
  note). This repo only needs to expose the API that work will consume.
- **Trusted-author flow / human review queue** (build-order steps 8–9) — unrelated to
  signing, already out of scope per the check-pipeline design's own scope note.
