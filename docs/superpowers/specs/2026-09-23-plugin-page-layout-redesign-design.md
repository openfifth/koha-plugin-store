# MetaCPAN-Style Layout Redesign — Design

**Status:** Proposed
**Relates to:** builds directly on
[`2026-09-22-consumer-discovery-ux-design.md`](2026-09-22-consumer-discovery-ux-design.md), which
introduced `readme_html`, the info-block sidebar, the "Get this plugin" panel, and a tabbed
Details/Releases/Technical-report detail page. This spec **replaces that page's tab structure**
with a single-scroll, MetaCPAN-inspired layout, and — for the first time — reworks the site-wide
navigation chrome and homepage that every page sits inside of.

## Summary

Three things change together, because removing the left sidebar (currently a `col-md-3` nav menu
present on *every* page via `templates/layouts/default.html.ep`) is what makes the other two
possible:

1. **Global nav/layout** — the left sidebar nav (`partial/side_menu.html.ep`,
   `partial/nav_items.html.ep`) is removed. Pages that don't need a sidebar go full-width.
   "Developer login" moves into the navbar, where the account dropdown already lives once logged
   in. "Plugin developers" and "Verification key" move to a new footer partial.
2. **Homepage** (`/`, `plugins#index`) — unchanged functionally, just reflows full-width, plus one
   intro line above search for logged-out visitors.
3. **Plugin detail page** (`/plugins/:slug`) — the tab bar is replaced with a
   `Author / Plugin [Version ▾]` header (MetaCPAN's "Author / Module [Version]" pattern). The
   sidebar, freed up by the nav removal, becomes the info-block stack (compatibility/certification,
   changelog excerpt, links, "get this plugin", contributors). The version selector doubles as the
   releases list and gives every version its own permalink. A new **Technical report** section sits
   below the README, linear rather than tabbed. Logged-in developers with rights on the plugin get
   an owner-only sidebar menu leading to a dedicated **Manage releases** view.

A new small feature rides along because the version-permalink design surfaced it directly: **release
changelogs**. `CHANGELOG.md` support is added now (fetched/stored the same way `readme_html` already
is) so each version's page can show "what's new in this version" without needing to fork
`readme_html` per-version (see "Why README stays single-copy" below).

Also new: a public, unauthenticated **author page** (`/authors/:slug`) grouping every published
plugin by its metadata `author` string — the MetaCPAN-style author link needs *something* to point
at, and this is the smallest useful version of it (see "Author page" below for why it's explicitly
not an identity/account system).

## Why README stays single-copy

The version switcher gives every version a real permalink (`/plugins/:slug/v/:tag`), which raises
the question of whether an older version's page should show the README *as it was* at that tag. It
should not, for this pass:

- `readme_html` today lives on `plugins`, refetched from the default branch on every version
  processing run (see the prior design doc's Schema section) — there is no per-tag copy today.
- Making per-version pages historically accurate would mean fetching README at the tagged
  commit/ref instead of `HEAD`, storing it on `plugin_versions`, and migrating/backfilling. Storage
  itself is a non-issue (markdown/HTML READMEs are typically a few KB to tens of KB; even full
  duplication across every version of every plugin in the catalogue would add tens of MB at most,
  and Postgres TOAST-compresses `TEXT` columns automatically) — but the README rarely changes
  meaningfully release-to-release, and it describes *the current codebase* either way, which is
  what a librarian installing today actually wants to read regardless of which version's page they
  landed on.
- **Decision:** every version's page renders the same `plugins.readme_html` (always latest). What
  *does* vary per version — compatibility range, certification tier, signed status, the technical
  report, and now the changelog excerpt — already lives on `plugin_versions` or is computed
  per-version, so the permalink is still meaningfully different page-to-page.
- Changelogs solve the "what's actually different about this release" need better than a
  duplicated README would anyway (see "Changelog support" below).

## Global navigation & layout

- `templates/layouts/default.html.ep`: the `<div class="row"><div id="sidebar" class="col-md-3">…
  <div id="main" class="col-md-9">` split is removed as the default. Pages with no sidebar content
  (homepage, `/developers`, `/login`, `/my-plugins`, `/new-plugin`, `/new-plugin-step2`, `/profile`,
  `/verification-key`) render `content` directly inside the full-width `container`. The plugin
  detail page (and its new `/manage` sibling) are the only templates that still declare a `sidebar`
  content block — the layout renders the two-column split *only* when that block is non-empty,
  rather than unconditionally.
- Navbar (`templates/layouts/default.html.ep`'s `<nav>`): the logged-out state currently renders
  nothing in the `navbar-header float-right` slot. It now renders a "Log in with GitHub" link there
  (reusing the existing `/auth/github` route and icon), in the same position the account dropdown
  occupies once `logged_in_user` is true. This retires `partial/auth_menu.html.ep`'s
  "Developer login" list-group entry.
- `partial/nav_items.html.ep` is deleted. "Browse Plugins" (which only ever linked to `/`, already
  reachable via the brand link) is dropped, not relocated. "Plugin developers" (`/developers`) and
  "Verification key" (`/verification-key`) move into a new `templates/partial/footer.html.ep`,
  rendered via the layout's existing (currently-unused) `content_for 'footer'` block — plain text
  links, e.g. `For developers · Verification key`.
- `partial/auth_menu.html.ep`'s logged-in items ("New Plugin", "My Plugins", "Log Out") were already
  duplicated in the navbar's account dropdown before this change (see `templates/layouts/
  default.html.ep`'s existing dropdown) — the sidebar-only copies are simply removed as part of
  deleting the sidebar; the dropdown is the sole copy going forward.

## Homepage

- `templates/plugins/index.html.ep` (the `/` route, `plugins#index`) keeps its existing
  search/sort/filter/cards/pagination content unchanged, just reflowing full-width once the sidebar
  is gone.
- One intro line is added above the search form, logged-out-and-logged-in alike (this page has no
  logged-in-specific branch today, and none is being added — dev-facing shortcuts stay in the
  account dropdown and on `/developers`, per the approved design discussion):

  ```html
  <p class="lead">Browse and install community-contributed plugins for your Koha library system.</p>
  ```

## Plugin detail page — header & sidebar

`templates/plugins/show.html.ep`'s tab bar (`#plugin-tabs`) is removed. In its place:

```
[avatar?] <Author, linked to /authors/:author-slug> / <Plugin name> [<tag_name> ▾]
```

- **Author** is `plugin->author` (the free-text metadata string — see "Author page" below for why
  this is deliberately *not* `developer_id`/the submitting GitHub account), slugified with the new
  shared `slugify()` helper (see "Data model & backend changes").
- **`[tag_name ▾]`** is the version switcher — see "Version switcher, routing, and unpublished
  handling" below. It replaces the old Releases tab.

Sidebar (rendered in the freed-up `col-md-3`, `content_for 'sidebar'` on this template only), top
to bottom:

1. **Owner-only menu** (only when `is_owner`): "Overview" (this page, current item highlighted) /
   "Manage releases" (link to the new `/plugins/:slug/manage`, see below).
2. **Compatibility & certification card** — unchanged from today: Koha version range, certification
   tier badge, for the version currently being displayed.
3. **What's new in this version** — the extracted changelog section for the displayed tag, or a
   plain "Full changelog ↗" link if extraction fails or no changelog exists (see "Changelog
   support").
4. **Links card** — repository, `documentation_url`, `issue_tracker_url` (all unchanged from
   today's card).
5. **Get this plugin** card — unchanged (store base URL + slug, copy-to-clipboard).
6. **Contributors** — moved here from its current spot below the README (`@$contributors` loop,
   unchanged content, new location only).

Below the README (main column, not sidebar): a **Technical report** section — the existing check
table (`check_name`/`required`/`passed`/`message`), scoped to whichever version the page is
displaying, same `$is_owner` visibility rule as today (non-owners only ever see a `published`
version's checks — enforced automatically here since non-owners can't reach a non-published
version's URL at all, see below).

## Version switcher, routing, and unpublished handling

- New route: `GET /plugins/:slug/v/:tag_name` — renders the full detail page (header, sidebar,
  README, technical report) for that specific version. `GET /plugins/:slug` (existing route)
  becomes a thin wrapper: resolve `latest_published_version`, redirect to its `/v/:tag_name` URL
  (302), or if the plugin has no published version yet, render the existing
  "still processing"/no-releases state at the bare URL (this is the state an owner watches
  immediately after submitting, before anything is publishable — it can't redirect to a version
  that doesn't exist yet).
- The `[tag_name ▾]` dropdown lists every version for the plugin, newest first:
  - `published` versions: normal links to their `/v/:tag_name` URL.
  - Non-`published` versions (`submitted`/`checks_running`/`changes_requested`/`check_error`):
    rendered as disabled `<span>` rows (not `<a>`) for anonymous/non-owner visitors, with the
    status shown inline (e.g. "v1.5.0 — changes requested") so it's visible but not navigable.
  - When `is_owner`, those same rows render as real links — the owner can view their own in-flight
    or rejected submissions' pages (reusing the existing `still_processing` auto-refresh behavior,
    now scoped to `/v/:tag_name` instead of the bare slug URL).
- `plugins#show_version` (the new controller action backing `/v/:tag_name`) enforces the same rule
  server-side, not just in the dropdown's rendering: a non-owner requesting a non-published tag's
  URL directly gets a 404, matching the protection the current `is_owner` gate already gives the
  technical-report loop.

## Owner-only "Manage releases" view

- New route: `GET /plugins/:slug/manage`, `requires user_authenticated`, further gated to
  `is_owner` in `Controller::Plugins` (404 for a logged-in developer who doesn't own this plugin —
  same posture as the existing per-row `next if !$is_owner` guards, just at the route level here
  since the whole page is owner-only).
- Same layout shell (navbar, sidebar — with the owner menu's "Manage releases" entry now shown
  active) but the main content area swaps README + technical report for today's two owner-only
  tables, moved wholesale from the current Releases tab:
  1. The full `plugin_versions` history for this plugin (every status, not just `published`).
  2. The GitHub-releases-not-yet-added sync table with its existing "Add this release" form
     (`POST /new-release`, unchanged).
- The "Edit plugin" modal stays exactly as-is (triggered from the Overview page's header, next to
  the plugin name) — it's a quick inline edit, not a navigation destination, so it isn't folded into
  the owner menu.

## Public author page

- New route: `GET /authors/:slug`, no auth required.
- `:slug` is `slugify(plugin.author)` (same helper as plugin slugs — see below). The page queries
  every **published** plugin whose `author` slugifies to the same value, and renders them as
  homepage-style cards (name, description, cert badge) under a header showing the raw author string
  (not the slug), the matching plugin count, and a one-line aggregate (e.g. "2 CERTIFIED, 1
  STRUCTURAL").
- **Deliberately not an identity system.** `author` is free-text plugin metadata — per your own
  framing, often a company/individual name for whoever takes overall responsibility, which need not
  be (and often isn't) the same as `developer_id`/the GitHub account that submitted the release, or
  any of the listed contributors. This page is purely a read-only grouping by that string as it
  exists today:
  - No account, no claiming, no login, no bio/avatar.
  - Two unrelated plugins whose authors happen to type an identical name collide onto one page.
    Accepted limitation — real author identity/verification is explicitly the **trusted-author**
    roadmap step's job, not this one's. This page's URL shape (`/authors/:slug`) is chosen so that
    step can later attach a claimable account to a slug without changing any links pointing at it.
  - Distinct from the existing `/profile` page, which is the *logged-in developer's own* self-view
    of their GitHub-linked account — unrelated concept, no overlap.
- Zero matching published plugins (stale link, or an author string that only appears on unpublished
  versions) → plain 404.

## Changelog support

- `CHANGELOG.md`/`CHANGES.md` gets the exact same treatment `readme_html` already has: fetched from
  the repo's default branch, stored as `changelog_html` on `plugins` (not `plugin_versions`),
  refreshed on every version-processing run, best-effort (missing file is fine, not an error).
- A new helper, `KohaPluginStore::Changelog::extract_section($changelog_html, $tag_name)`, pulls out
  just the entry for a given version by matching a `## [x.y.z]` / `## vX.Y.Z`-style heading (the
  "Keep a Changelog" convention) — same "regex over real-world text, expect rough edges" posture the
  project already takes with `Perl` metadata extraction. Returns `undef` on no match (unrecognized
  heading format, or the version predates the changelog's start), in which case the sidebar falls
  back to a plain "Full changelog ↗" link to the rendered `changelog_html` (or the repo's changelog
  file directly, if simplest) instead of an extracted excerpt.

## Data model & backend changes

```sql
ALTER TABLE plugins ADD COLUMN changelog_html TEXT;
```

- `KohaPluginStore::GitHub::fetch_changelog_html($token, $repo_url)` — same shape and same GitHub
  README-style content API usage as the existing `fetch_readme_html`, tried against
  `CHANGELOG.md`/`CHANGES.md` at the default branch.
- `KohaPluginStore::Task::ProcessPluginVersion` fetches and sets `changelog_html` alongside
  `readme_html`, same `eval`-wrapped best-effort call site.
- `slugify($string)` extracted from `Model::Plugin::create_with_unique_slug`'s inline
  lowercase/dash/trim logic into a shared function, used for both plugin slugs (unchanged behavior)
  and the new author-page slugs.
- `Model::Plugin` gains a query for "every published plugin with a given author slug" (author-page
  listing) — likely a `WHERE lower(regexp_replace(author, ...)) = ?` filter, or (simpler, and
  consistent with how the rest of the model layer favors explicit Perl logic over embedding the
  slugify regex twice in SQL) fetch-then-filter-in-Perl if the catalogue size makes that
  acceptable; either is fine as an implementation detail, not a design constraint.
- `Controller::Plugins` gains `show_version` (backing `/plugins/:slug/v/:tag_name`) and `manage`
  (backing `/plugins/:slug/manage`) actions, and a new `Controller::Site` (or `Plugins`) action for
  `/authors/:slug`.

## Non-goals

- No per-version README storage/history — see "Why README stays single-copy" above.
- No author identity, accounts, claiming, or verification — that's the trusted-author roadmap
  step's scope; this pass only reserves the URL shape and ships the read-only grouping view.
- No change to the "Edit plugin" modal's UX (stays a modal, not a page).
- No change to `/profile` (self-view) — unrelated to the new public `/authors/:slug` page.
- No GitLab support (unrelated, separate track per the existing GitLab provider design doc).
- No auto-derivation of changelog structure beyond "Keep a Changelog"-style headings — genuinely
  free-form changelogs just fall back to a plain link, not a design gap to solve here.

## Testing

- **Layout**: a page with no `sidebar` content block renders full-width (no empty `col-md-3`); the
  plugin detail and manage pages still render the two-column split. Footer partial renders
  "Plugin developers"/"Verification key" links; the deleted `nav_items` sidebar partial's routes
  (`/developers`, `/verification-key`) still resolve, just linked from the footer now. Logged-out
  navbar shows a "Log in with GitHub" link where the account dropdown would be.
- **Homepage**: existing search/sort/filter/pagination tests unaffected by the layout reflow; intro
  line present.
- **Version routing**: `/plugins/:slug` redirects to the latest published version's `/v/:tag_name`
  URL; a plugin with zero published versions renders the existing processing/empty state instead of
  redirecting; `/v/:tag_name` for a non-published version 404s for a non-owner and renders for the
  owner; the version dropdown renders non-published rows as disabled for non-owners and as links for
  the owner.
- **Manage releases**: `/plugins/:slug/manage` requires auth, 404s for a logged-in non-owner, renders
  the all-statuses version table and GitHub-sync table for the owner.
- **Author page**: `/authors/:slug` lists only published plugins matching the slug; a slug with zero
  matches 404s; two plugins with differently-cased but equivalent author strings both appear.
- **Changelog**: `Task::ProcessPluginVersion` sets `changelog_html` best-effort (missing file isn't
  fatal, same as README); `extract_section` matches a "Keep a Changelog"-style heading and returns
  `undef` (triggering the fallback link) on an unrecognized format.
