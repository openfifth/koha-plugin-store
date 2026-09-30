# Design: render README/CHANGELOG markdown ourselves instead of trusting GitHub's HTML

## Background

On 2026-09-23 a stored/persistent XSS was found and fixed: README/CHANGELOG HTML was
fetched pre-rendered from GitHub (`Accept: application/vnd.github.html+json`) and
injected raw into `templates/plugins/show.html.ep` with zero local sanitization. The
immediate fix — `KohaPluginStore::Sanitize::html()`, an `HTML::Scrubber` allowlist run
over GitHub's output before storage — landed the same day and stays in place under this
design.

The deferred follow-up, scoped here: stop trusting GitHub's rendering pipeline
entirely. Fetch raw markdown source ourselves and render it locally with a real
CommonMark implementation, so GitHub's renderer is no longer a trust dependency at all.

## Decisions

- **Library: plain `CommonMark`** (CPAN, author NWELLNHOF — a wrapper around the C
  `libcmark` library), not GFM extensions. A spike checked the two plugins currently
  live in the store (`openfifth/koha-plugin-automate-marc-import`,
  `openfifth/koha-plugin-crontab`) for GitHub-Flavored Markdown syntax — tables, task
  lists, strikethrough — and found none in either README or CHANGELOG. Correction to
  the original briefing: `CommonMark::XS` does not exist on CPAN. The real, actively
  maintained module is `CommonMark`, confirmed via its POD to expose
  `CommonMark->markdown_to_html($markdown, $options)` with a real `OPT_UNSAFE` render
  flag (opts into raw-HTML passthrough; CommonMark strips raw HTML by default without
  it) — this matches the "unsafe mode" behavior the original briefing described, just
  under the correct module name.
- **Raw HTML support: kept.** `Markdown::render` runs in unsafe mode
  (`OPT_UNSAFE | OPT_VALIDATE_UTF8`) so raw HTML in source markdown (badges, `<details>`
  blocks, centered images) passes through into CommonMark's output, and
  `Sanitize::html()` scrubs it exactly as it does today. No author-facing behavior
  change versus the current GitHub+Scrubber pipeline. `Sanitize.pm` is not being
  retired — it remains the actual security boundary, just fed CommonMark's output
  instead of GitHub's.
- **Module boundary: new `KohaPluginStore::Markdown` module.** Keeps `GitHub.pm` as
  pure fetch (returns raw markdown strings), `Sanitize.pm` as pure scrub (unchanged),
  and this new module as the single markdown→HTML rendering seam.
- **Backfill: one-off script.** The 2 plugins already in the store have
  `plugin_versions` rows with HTML rendered by the old GitHub pipeline. A one-shot
  script re-runs fetch→render→sanitize for all existing rows post-deploy, rather than
  waiting for their next natural release to pick up the new pipeline.

## Architecture / data flow

```
GitHub API (raw markdown)      KohaPluginStore::Markdown        KohaPluginStore::Sanitize
   README/CHANGELOG.md   -->   render($md) -> unsafe HTML  -->   html($html) -> safe HTML  -->  stored
```

`GitHub.pm` fetches raw `.md` bytes via `Accept: application/vnd.github.raw+json` —
confirmed working against both the `/readme` endpoint (auto-resolves the repo's
default README file/case/extension) and the `/contents/{path}` endpoint used for
CHANGELOG, same URLs as today, only the `Accept` header changes.

## Component changes

- **`cpanfile`**: add `requires "CommonMark"`. Regenerate `cpanfile.snapshot` via
  Carton. Deployment note for `DEPLOYMENT.md`: this is an XS binding against the system
  C library `libcmark` — the target Debian host needs `libcmark-dev` installed (same
  category of system dependency as the existing libsodium/Ed25519 requirement).

- **`lib/KohaPluginStore/GitHub.pm`**: rename `fetch_readme_html` /
  `fetch_changelog_html` to `fetch_readme_markdown` / `fetch_changelog_markdown` (names
  should reflect what they now return). Same endpoints and fallback behavior
  (`/contents/CHANGELOG.md` falling back to `/contents/CHANGES.md`), only the `Accept`
  header changes to `application/vnd.github.raw+json`. The shared `_get_readme`
  private helper's "return raw response body, don't JSON-decode" behavior is unchanged.

- **`lib/KohaPluginStore/Markdown.pm`** (new): one function, `render($markdown) ->
  $html`, wrapping `CommonMark->markdown_to_html($markdown, OPT_UNSAFE |
  OPT_VALIDATE_UTF8)`. `OPT_VALIDATE_UTF8` is a deliberate defensive addition beyond
  what the briefing specified — this module now renders arbitrary community-submitted
  markdown directly (previously GitHub's own pipeline absorbed malformed input), so
  validating UTF-8 at this boundary matches the project's existing convention of
  validating untrusted external input.

- **`lib/KohaPluginStore/Sanitize.pm`**: unchanged. Its existing allowlist (which
  already permits the table/`del`/checkbox-input family) stays as the enforcement
  layer, now scrubbing CommonMark's output instead of GitHub's.

- **`lib/KohaPluginStore/Task/ProcessPluginVersion.pm`**: the fetch→sanitize call site
  becomes fetch→render→sanitize:

  ```perl
  my $readme_md   = GitHub::fetch_readme_markdown(...);
  my $readme_html = defined $readme_md
      ? Sanitize::html(Markdown::render($readme_md))
      : undef;
  ```

  (same shape for changelog). Storage columns (`readme_html` / `changelog_html`) and
  the conditional-update-hash pattern (`defined $x ? (col => $x) : ()`) are unchanged.

- **`lib/KohaPluginStore/Changelog.pm`**: `extract_section`'s heading regex
  (`<h([1-6])[^>]*>(.*?)</h\1>`) and `$VERSION_TEXT_RE` are kept as-is — they only
  depend on generic `<h1-6>` tag structure, which CommonMark's output preserves (and
  simplifies, since it has no GitHub anchor-permalink wrapper around heading text).
  Verified against real fixture data: `koha-plugin-crontab`'s CHANGELOG uses
  Keep-a-Changelog-style `## [1.6.7] - 2026-09-22` headings, which the current
  `$VERSION_TEXT_RE`'s bracket-tolerant pattern already handles (this file was touched
  today, 2026-09-30, for an unrelated regex fix — current behavior confirmed via
  `git log`, commit `fdaae51`). This file needs a **verification pass with a
  CommonMark-rendered fixture**, not a rewrite, unless testing turns up a real
  mismatch.

- **`script/backfill_markdown_rendering.pl`** (new): one-shot, run manually post-deploy
  (not scheduled). Iterates existing `plugin_versions` rows and re-runs
  fetch→render→sanitize in place, so already-stored HTML doesn't lag behind the new
  renderer until each plugin's next release.

## Error handling

No new failure modes on the fetch side — same GitHub API endpoints, same
missing-file/404 behavior `GitHub.pm` already handles (returns `undef`;
`ProcessPluginVersion.pm`'s conditional-update-hash pattern already skips absent
fields). The only deliberate addition is `OPT_VALIDATE_UTF8` in `Markdown::render`,
covered above. `Sanitize::html` downstream is already robust to malformed/arbitrary
HTML input, since it already handles GitHub's (not-guaranteed-well-formed) output
today.

## Testing plan

- `t/github.t` — update for renamed methods and the new `Accept` header; mocked
  responses become raw markdown bytes instead of HTML fixtures.
- `t/markdown.t` (new) — unit tests for `Markdown::render`: core constructs (headings,
  emphasis, links, lists, code fences), raw HTML passthrough under unsafe mode, GFM
  syntax (tables/strikethrough) rendering as literal text rather than being specially
  handled (per the plain-CommonMark decision), UTF-8 edge cases.
- `t/sanitize.t` — add a regression case feeding real CommonMark-rendered output
  (not hand-written HTML) through `Sanitize::html`, to catch any shape mismatch between
  GitHub's old output and CommonMark's.
- `t/changelog.t` — add a fixture built from actual CommonMark output (using the real
  `koha-plugin-crontab` CHANGELOG content as source markdown) to verify
  `extract_section` against the new, simpler heading shape.
- `ProcessPluginVersion`'s existing test file — update mocks from `fetch_*_html` to
  `fetch_*_markdown`.
- Manual validation — before running `script/backfill_markdown_rendering.pl` against
  the shared dev DB, dry-run a diff of old-vs-new rendered HTML for the 2 live plugins
  first (per the project's existing shared-test-DB caution — this DSN is shared live
  state across worktrees, not an isolated test fixture).

## Workflow note

Per today's precedent (co-maintainer model, auto-sync releases, and private-plugins
specs all landed directly on `worktrees/main`/`main`, breaking from the project's older
`planning`-worktree convention), this spec and its implementation follow the same
main-worktree pattern for consistency.
