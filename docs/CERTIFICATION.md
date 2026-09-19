# Automated checks (certification pipeline)

Every submitted version runs through 11 automated checks (in
`lib/KohaPluginStore/Check/`) before it can publish, split into three tiers:

- **Required — the actual publish gate.** Fail any one of these and the
  version stays in `changes_requested` forever, regardless of who submitted
  it:
  - `perl_syntax` — runs `perl -cw` against every `.pm` file, inside a
    network-isolated, read-only Docker sandbox, against a Koha checkout
    matching the plugin's declared `minimum_version`
  - `manifest_completeness` — the plugin's `$metadata` hash declares both
    `version` and `license`
  - `dependency_allowlist` — a static analysis (via PPI, so it looks at real
    parsed syntax, not raw text — a mention of `system(` in a comment or
    string doesn't false-positive) for risky code: `system()`/`exec()`/
    backticks/`qx`, `use`ing a networking module (`IO::Socket`, `Net::*`,
    `LWP`/`HTTP::Tiny`), `open()`ing an absolute filesystem path, or a
    string referencing `../` to escape the plugin's own directory

- **Non-required, but gate the certification badge.** These don't block
  publishing, but a version can only reach the `CERTIFIED` tier if all of
  them also pass (short of that, it still publishes, just at `STRUCTURAL`):
  - `perl_critic` — `Koha::QA::PerlCritic` against every `.pm` file
  - `docs_presence` — a `Development.md`, `CONTRIBUTING.md`, `README`/
    `README.md`, or `docs/` exists
  - `tests_presence` — at least one `t/*.t` file exists in the tagged source
    repository (checked via the GitHub API, not the `.kpz`, which never
    packages tests)
  - `translatable_templates` — any `.tt` file rendering visible markup
    (`<h1>`, `<p>`, `<button>`, etc.) also uses the `[% t(...) %]` translation
    marker somewhere in the file (a per-file heuristic, not a per-string check)
  - `plugin_template_wrapper` — every `.tt` file includes the plugin template
    wrapper include (currently `doc-head-close.inc` — a placeholder pending
    confirmation against `Koha::Plugins` conventions, see the code comment)
  - `hardcoded_credentials` — a credential-shaped key or variable name (e.g.
    `api_key`, `password`) assigned a literal string, found via PPI against
    real parsed syntax rather than raw text (so a comment or docstring that
    merely *describes* such an assignment doesn't false-positive), plus a
    plain content scan for PEM private key headers and AWS access key ID
    patterns

- **Recorded, but don't gate anything — informational only:**
  - `koha_max_version` — whether `$metadata` declares a `maximum_version`
  - `gpg_signed_tag` — whether the developer's own release tag was GPG-signed
    on GitHub

Every check's `required`/`passed`/`message` result is written to the
`review_checks` table (one row per check per version, upserted on re-run) by
`KohaPluginStore::Task::ProcessPluginVersion`, which runs all 11 in order once
per submitted version. Once they've all run:

- Any **required** check failing → `status = 'changes_requested'`,
  `certification_tier = 'INCOMPLETE'` — the version never publishes.
- All required checks pass, but at least one certification-gating check
  fails → publishes at `certification_tier = 'STRUCTURAL'`.
- Everything passes → publishes at `certification_tier = 'CERTIFIED'`.
- If a check itself can't run (e.g. the sandboxed Koha checkout for
  `perl_syntax` can't be prepared) → `status = 'check_error'`, distinct from
  a normal check failure, so infrastructure problems aren't mistaken for a
  problem with the plugin.

**What a developer sees on a failed submission:** the plugin's version page
(`templates/plugins/show.html.ep`) shows the version's `status`, a
`certification_tier` badge, a "Signed" badge if applicable, the generic
`error_message`, and a full per-check breakdown (name, required/advisory,
pass/fail, message) from `review_checks` — not just the generic message
alone.

## Publish signing

On publish, `KohaPluginStore::Signing` builds and signs a small manifest
(`slug`, `version`, `kpz_url`, `digest`, `published_at` — deliberately no
`certification_tier`/`level` field, see below) with the
store's Ed25519 key (`koha_plugin_store.conf`'s `signing_key_path`, generated
via `script/koha_plugin_store generate_signing_key`), storing both the exact
signed JSON string (`plugin_versions.signed_manifest`) and the signature
(`signature`) verbatim. `certification_tier` is deliberately excluded from the
signed content — it's a separate, re-assessable quality claim, exposed
alongside the signature rather than frozen inside it, so a later
re-certification never needs a re-sign.

Signing and certification tier are two distinct facts and should never be
presented as a single combined "trust" indicator: signing only confirms the
`.kpz` hasn't been altered since the store inspected it, it is not a safety or
quality judgement — that's what the certification tier is for.

`GET /api/plugins/verify?digest=<sha256hex>` looks up a published version by
its `content_digest` and returns `{ signed_manifest, signature,
certification_tier }` — this is how a Koha instance verifies a
manually-uploaded `.kpz` (which has no `kpz_url` to match against the
discovery listing), not just ones fetched via the discovery client.
