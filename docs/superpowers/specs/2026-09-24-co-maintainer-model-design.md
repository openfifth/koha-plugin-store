# Co-maintainer model — Design

**Status:** Proposed
**Relates to:** "GitLab as a second repo provider" (commit `ae63245`, "Add design spec for GitLab
as a second repo provider" — not currently a file in this repo; recovered via `git show ae63245`
for this design). That spec's `developer_identities` table isn't implemented yet, so this design
must not assume it exists — but `organizations` is keyed the same way that table is,
`(provider, provider_org_id)`, so it slots in cleanly whenever GitLab support actually lands.

## Summary

Today, a plugin has exactly one owner: `plugins.developer_id`, set once at submission and never
changed. `repo_url` is globally `UNIQUE` in the database. That means a real GitHub collaborator on
an already-submitted repo — someone with genuine push/admin rights, just not the person who
happened to submit it first — currently has no way to get store upload rights for it: they aren't
shown it on their own `/my-plugins` (which is a plain `WHERE developer_id = you` query), and if
they try to submit it themselves (single-plugin flow or bulk import), they hit an *unhandled*
Postgres unique-violation on `repo_url` — a raw 500, not a clear message, since only the
`plugin_versions` tag-collision case is caught with a friendly one today.

This design adds a real co-maintainer concept, detected automatically from GitHub's own access
control (no request/approval step), kept live (revoked automatically if GitHub access is later
removed), and deliberately **not** tied to `plugin_contributors` (the existing, purely cosmetic
GitHub commit-stats list shown on a plugin's page) — that stays exactly as it is.

Deliberately out of scope for this design: an organization profile/listing page, proactively
notifying an *other* developer the instant a new plugin is submitted (they discover their
maintainer status lazily, at their own next login/repo-refresh), self-hosted GitLab, and GitLab
groups (the data model doesn't block adding them later, but nothing here implements them).

## Data model

```sql
CREATE TABLE organizations (
    id               SERIAL PRIMARY KEY,
    provider         TEXT NOT NULL,           -- 'github' today; 'gitlab' once that provider lands
    provider_org_id  TEXT NOT NULL,
    login            TEXT NOT NULL,           -- GitHub org slug, e.g. 'PTFS-Europe'
    avatar_url       TEXT,
    UNIQUE (provider, provider_org_id)
);

ALTER TABLE plugins ADD COLUMN organization_id INTEGER REFERENCES organizations(id);

CREATE TABLE plugin_maintainers (
    id               SERIAL PRIMARY KEY,
    plugin_id        INTEGER NOT NULL REFERENCES plugins(id) ON DELETE CASCADE,
    developer_id     INTEGER NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
    role             TEXT NOT NULL,           -- 'owner' | 'maintainer'
    granted_via      TEXT NOT NULL,           -- 'creator' | 'github_collaborator' | 'github_org_member' | 'manual'
    granted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (plugin_id, developer_id)
);
```

- **`plugins.developer_id` is not removed or repurposed.** It stays the "who owns this" tie-breaker
  without a join, and every existing `$plugin->developer_id == $c->session->{developer}->{id}`
  ownership check (`manage`, `update_plugin`, `new_release`, `show`'s draft-visibility check)
  keeps working completely unchanged. A migration backfills one `plugin_maintainers` row per
  existing plugin: `role='owner', granted_via='creator', developer_id = plugins.developer_id`.
- **`plugin_contributors` is untouched.** It stays a display-only, GitHub-commit-stats list with no
  bearing on permissions, exactly as today — this table exists purely so the two concepts (who
  contributed commits vs. who can manage the listing) are never conflated in code that reads either
  one.
- **No `developer_organization_memberships` table.** "Is developer X a member of org Y" isn't
  needed as a standalone, persisted fact — the only thing that matters is, per matched repo, what
  *effective permission* GitHub already reports for that developer on that specific repo (see
  below), which already correctly resolves org/team inheritance without us tracking membership
  ourselves. Adding a membership table would be tracking a fact this design never actually queries;
  if a genuine need for it shows up in the org-page follow-up, add it then.
- **`organizations` is minimal on purpose, and unpopulated by this design.** The table and
  `plugins.organization_id` exist now so the deferred org-page follow-up doesn't need a schema
  migration when it happens, but nothing in this design writes to either — populating them (from
  the repo owner's `type` field, `User` vs `Organization`) is explicitly part of that later
  follow-up, not this one. Shipping the empty column now costs nothing and avoids a migration
  later; that's the entire justification for including it at this stage.

## New module: `KohaPluginStore::MaintainerSync`

```perl
# Cross-references $repos (a freshly-fetched-or-cached repo list, the same
# shape KohaPluginStore::GitHub::fetch_all_repos returns, extended to carry
# each repo's `permissions` object -- see below) against every
# plugins.repo_url, granting plugin_maintainers rows for $developer where
# warranted. No access token needed here: the permission signal already
# rode along in $repos itself, from whenever it was fetched.
sub sync_from_repo_list {
    my ( $pg, $developer, $repos ) = @_;
    ...
}

# One repo's worth of the same logic, split out for the "someone else's
# plugin already exists for this exact repo_url" case hit during submission
# (new_plugin_confirm / bulk_import) -- there, we already have the single
# matched repo (permissions included) in hand and don't want to re-fetch or
# re-scan the developer's entire repo list just to re-derive it.
sub maybe_grant_for_repo {
    my ( $pg, $developer, $plugin, $repo ) = @_;
    ...
}
```

GitHub's `GET /user/repos` — the exact call `KohaPluginStore::GitHub::fetch_all_repos` already
makes — returns a `permissions` object per repository (`{admin, maintain, push, triage, pull}`)
reflecting the *token holder's own effective permission* on that repo, already correctly resolving
organization/team-based access internally. That means the grant side needs **no extra API call at
all**, regardless of whether the access came from being a direct collaborator or from org/team
membership — GitHub has already done that resolution for us, in the same response.

- `fetch_all_repos` gains `permissions => $_->{permissions}` in the hash it already builds per repo
  (today: `{ full_name, html_url }` only) — a one-line change, no new request.
- A matched repo with `permissions.push` or `permissions.admin` true → grant
  (`granted_via='github_collaborator'` if `permissions.admin` came from being the direct owner or
  an explicit collaborator, `'github_org_member'` if it came via an organization — **this
  distinction needs confirming against a real API response at implementation time**: does the
  `/user/repos` payload expose *why* a permission applies anywhere, or only the resolved boolean?
  If only the boolean, `granted_via` collapses to a single value, e.g. `'github_access'`, and the
  two-value enum in the schema above shrinks accordingly — a naming detail to settle then, not a
  reason to block this design now.
- `pull`-only (or no) access on a matched repo → no grant, not an error.
- A repo matching a plugin the developer already owns/maintains is a no-op beyond bumping
  `last_verified_at` (see revocation, which relies on this timestamp only for observability, not
  as its own revocation trigger — the reconciliation job re-checks live state every run regardless
  of how recently a row was touched).

**Where it's called from:** `Controller::Plugins::_cached_developer_repos` (the shared helper
`add_form`/`bulk_form` already call whenever the repo cache is refreshed) gains a call to
`sync_from_repo_list` right after `refresh_cached_repos` — covering login, the explicit "Refresh my
GitHub repos" button, and visiting `/new-plugin` or `/new-plugin/bulk`. No new touchpoint needed for
granting.

## Revocation: a new periodic job

`plugin_maintainers` rows don't stay correct on their own — GitHub access can be revoked at any
time, and this store should reflect that, not just the moment-of-grant snapshot.

New Mojolicious command: `script/koha_plugin_store reconcile_maintainers`. For every
`plugin_maintainers` row with `granted_via IN ('github_collaborator', 'github_org_member')` —
**never** `'creator'` or `'manual'`, which are permanent, human-decided facts this job must not
touch — re-check that developer's current permission on the plugin's `repo_url`. Unlike the grant
side, this can't reuse a developer's own `/user/repos` response (the developer isn't necessarily
logged in when this runs, and `/user/repos` only ever reflects the *token holder's own* access, not
an arbitrary third party's) — it needs GitHub's per-repo collaborator-permission endpoint instead,
`GET /repos/{owner}/{repo}/collaborators/{username}/permission`, using the store's own
`github_app_token` to ask about that specific developer's username. Below `push`, or the repo/user
no longer resolves at
all (deleted account, repo made private and no longer visible to the app token, transferred away) →
delete the `plugin_maintainers` row. A transient failure (rate limit, network error, GitHub outage)
must **never** revoke — only a confirmed "this permission level is below push" or "this resource
is confirmed gone" response does. This mirrors the existing `check_infrastructure_error` vs.
genuine-failure distinction `KohaPluginStore::Task::ProcessPluginVersion`'s check pipeline already
makes for `perl_syntax`.

**Scheduling:** a new systemd timer unit (this app has no periodic-job mechanism today — this is
new infrastructure, not reusing something that exists), proposed daily, documented in
`DEPLOYMENT.md` alongside the existing `worker`/`sandbox-broker` service units. Exact cadence is a
detail to confirm at implementation time against real GitHub rate-limit headroom, not fixed here.

**Open risk, not glossed over:** `github_app_token` is documented (`cpanfile`'s comment, and
`CLAUDE.md`) as "a fine-grained, public-repos-read-only PAT." GitHub's per-repo
collaborator-permission endpoint may need a broader scope than that to answer for an arbitrary
username — unlike the grant side, which only ever asks GitHub "what can *this already-authenticated
token holder* do," a scope question that token's own `/user/repos` call answers for free. **Needs
confirming against real GitHub API behavior at implementation time** — if the current app token
can't do this, the fix is widening its fine-grained permissions (still read-only, just a broader
read scope), not a design change here.

## Submission-flow integration (also fixes the crash)

`new_plugin_confirm` and `Controller::Plugins::bulk_import`'s "does a plugin already exist for this
repo" check currently scopes to `{ developer_id => <submitter>, repo_url => ... }` — meaning it
only ever recognizes *the submitter's own* prior submissions. Both change to a global lookup,
`{ repo_url => ... }` alone:

- **No existing plugin** → today's behavior, unchanged (create a new plugin, submitter becomes
  `role='owner', granted_via='creator'`).
- **Existing plugin, submitter is already a maintainer of it** (owner or otherwise) → today's
  "sync" behavior `bulk_import` already has: add the release as a new version on the existing
  plugin.
- **Existing plugin, submitter is *not* yet a maintainer** → call `maybe_grant_for_repo` inline,
  passing the matched repo entry (permissions included) that `fetch_all_repos` already returned for
  this exact repo earlier in this same request. Granted → proceed as the sync case above, and the
  developer is now a maintainer going forward. Not granted (`pull`-only permission, or the repo
  genuinely isn't in their list at all — someone hand-crafting a request for a repo_url they have no
  access to) → the existing friendly error, "That repository is not in the list of your public
  GitHub repositories," not a duplicate-row crash.

This is also the fix for the reported bug: a second real collaborator submitting an
already-claimed repo no longer hits an unhandled `plugins_repo_url_key` violation — they either get
folded in as a maintainer (if GitHub confirms their rights) or get the same clear rejection message
someone with no real access already gets today.

## Maintainer permission scope

`plugin_maintainers.role`: `'owner'` (the original creator, exactly one per plugin, never
auto-assigned to anyone else) vs `'maintainer'` (everyone else, however granted). Full parity for
everything that matters day-to-day — submitting/syncing releases, editing plugin metadata
(`update_plugin`'s `name`/`description`/`author`/`repo_url`/`issue_tracker_url` fields), triggering
a GitHub re-fetch from `/plugins/:slug/manage`. The only owner-only actions (not built by this
design, but the role split exists so they have somewhere to hang later): removing another
maintainer, deleting the plugin outright, or transferring ownership.

## Suggested phasing

This is real scope for one implementation plan to take on at once — two new tables, a new module, a
submission-flow change, and a new periodic job with its own deployment infrastructure. It splits
cleanly in two, and the first half is independently useful even if the second is scheduled
separately:

- **Phase 1 — grant side.** Schema (both tables, the backfill migration), `MaintainerSync`, the
  `_cached_developer_repos` hook, and the submission-flow integration (which is also the crash fix).
  Ships real value on its own: co-maintainers get recognized and folded in correctly; the only gap
  is that a maintainer who *loses* GitHub access keeps store rights until someone notices.
- **Phase 2 — revocation.** The `reconcile_maintainers` command and its systemd timer. Depends on
  Phase 1's schema existing, nothing else does.

## Testing approach

- `MaintainerSync` unit tests: a fabricated `fetch_all_repos`-shaped list (each entry carrying a
  `permissions` hash), asserting a `push`/`admin` match grants, a `pull`-only match doesn't, and a
  repo the developer already owns/maintains is a no-op beyond the timestamp bump.
- `reconcile_maintainers` command tests: a `github_collaborator`-granted row surviving a mocked
  `push` response, being revoked on a mocked `read` response, and surviving (not revoked) a mocked
  API error — plus asserting a `granted_via='creator'`/`'manual'` row is never touched regardless of
  the mocked response.
- Controller-level tests (extending `t/plugins_new_plugin.t`, `t/plugins_bulk_import.t`): a second
  developer with real collaborator/org-member access to an already-submitted repo gets folded in as
  a maintainer, not a duplicate-plugin crash; a developer with no real access still gets the
  existing rejection message.
- A migration test confirming the one-time backfill produces exactly one `role='owner'` row per
  existing plugin, matching its current `developer_id`.
