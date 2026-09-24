# Co-maintainer Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a real GitHub collaborator/org-member on an already-submitted plugin repo and
grant them store upload rights automatically, kept live via a periodic reconciliation job — and,
as part of the same fix, stop the app crashing when a second real collaborator tries to submit a
repo someone else already claimed.

**Architecture:** A new `plugin_maintainers` join table (plus an `organizations` table that exists
now but stays unpopulated — schema groundwork for a later, separate org-page feature, not used by
any code in this plan). A new `KohaPluginStore::MaintainerSync` module grants maintainer rows from
data already fetched today (GitHub's `/user/repos` response already includes a `permissions`
object per repo — no new API call needed to grant). A new periodic command,
`reconcile_maintainers`, revokes stale grants using a different GitHub endpoint (the per-repo
collaborator-permission check), since that's the only one that can answer "does an arbitrary
*other* user have access" rather than "what can *this* token do."

**Tech Stack:** Perl (Mojolicious, Mojo::Pg), Postgres, Minion (unaffected by this plan), GitHub
REST API v3.

**Spec:** `docs/superpowers/specs/2026-09-24-co-maintainer-model-design.md`

## Global Constraints

- `granted_via` has exactly three real values used by this plan: `'creator'` (the original
  submitter), `'github_access'` (auto-detected from GitHub's own permission data), and `'manual'`
  (reserved for a future human-granted path — nothing in this plan ever writes `'manual'`, but the
  reconciliation job must never touch a row with it, so the value name exists in comments/docs even
  though no code creates one yet). The spec's draft language floated splitting `'github_access'`
  into `'github_collaborator'`/`'github_org_member'` — settled here as a single value, because
  GitHub's `/user/repos` `permissions` object doesn't expose *why* a permission applies, only the
  resolved booleans.
- **Two different GitHub API response shapes, do not confuse them:**
  - `GET /user/repos` (`KohaPluginStore::GitHub::fetch_all_repos`) returns, per repo, a
    `permissions` object with **boolean** fields: `admin`, `maintain`, `push`, `triage`, `pull`.
    This is the token holder's *own* effective access. Used by the grant side.
  - `GET /repos/{owner}/{repo}/collaborators/{username}/permission` returns a **string** field,
    `permission`, one of `"admin"`, `"write"`, `"read"`, `"none"` (note: `"write"`, not `"push"` —
    different vocabulary from the endpoint above). This answers about an *arbitrary named user*,
    not the token holder. Used only by the revocation side (Phase 2), which can't use the grant
    side's endpoint because the developer being checked isn't the one making the request.
- `plugins.developer_id` is never removed, changed in meaning, or stopped being read by existing
  ownership checks (`manage`, `update_plugin`, `new_release`, `show`). This plan only adds
  `plugin_maintainers` as an additional, broader concept alongside it.
- `plugin_contributors` (existing table, GitHub commit-stats display) is never read or written by
  anything in this plan.
- No DB-level `CHECK` constraint on `role`/`granted_via` — this codebase's existing migrations
  never use `CHECK` for enum-like text columns (see `plugin_versions.status`), so this plan follows
  that convention rather than introducing a new one.
- Follow the shared-test-DB protocol already documented in this project's `CLAUDE.md`/memory before
  running `prove` in any worktree: check whether the worktree's docker stack is live and in active
  manual use, run `docker compose stop worker` before `prove`, `docker compose start worker` after,
  and use `docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l <files>` to run tests inside the container.

---

## Phase 1 — Grant side (independently shippable)

### Task 1: Schema — `organizations`, `plugin_maintainers`, and the owner backfill

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (append migration `10`)
- Create: `lib/KohaPluginStore/Model/PluginMaintainer.pm`
- Test: `t/model_plugin_maintainer.t`

**Interfaces:**
- Produces: `KohaPluginStore::Model::PluginMaintainer->new(pg => $pg)`, with inherited
  `find`/`search`/`create` from `Model::Base`, plus a new `grant($attrs)` method:
  `grant({ plugin_id => $id, developer_id => $id, role => 'owner'|'maintainer', granted_via => 'creator'|'github_access'|'manual' })`
  returns the (possibly pre-existing) row, upserting on `(plugin_id, developer_id)` without ever
  downgrading an existing row's `role`/`granted_via`.

- [ ] **Step 1: Add migration 10 to `lib/KohaPluginStore/Command/migrate.pm`**

Append after the existing `-- 9 down` block (do not renumber anything above it):

```
-- 10 up
CREATE TABLE organizations (
    id               SERIAL PRIMARY KEY,
    provider         TEXT NOT NULL,
    provider_org_id  TEXT NOT NULL,
    login            TEXT NOT NULL,
    avatar_url       TEXT,
    UNIQUE (provider, provider_org_id)
);

ALTER TABLE plugins ADD COLUMN organization_id INTEGER REFERENCES organizations(id);

CREATE TABLE plugin_maintainers (
    id               SERIAL PRIMARY KEY,
    plugin_id        INTEGER NOT NULL REFERENCES plugins(id) ON DELETE CASCADE,
    developer_id     INTEGER NOT NULL REFERENCES developers(id) ON DELETE CASCADE,
    role             TEXT NOT NULL,
    granted_via      TEXT NOT NULL,
    granted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (plugin_id, developer_id)
);

INSERT INTO plugin_maintainers (plugin_id, developer_id, role, granted_via)
SELECT id, developer_id, 'owner', 'creator'
FROM plugins
WHERE developer_id IS NOT NULL;

-- 10 down
DROP TABLE plugin_maintainers;
ALTER TABLE plugins DROP COLUMN organization_id;
DROP TABLE organizations;
```

- [ ] **Step 2: Apply the migration against the running dev stack**

Run (inside the worktree's docker stack, `app` container):
```bash
docker compose exec app script/koha_plugin_store migrate
```
Expected output ends with `Migrated to version 10`.

- [ ] **Step 3: Write the failing test for `Model::PluginMaintainer`**

Create `t/model_plugin_maintainer.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget', { repo_url => 'https://github.com/dev/widget' }
);
my $owner_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'owner', username => 'owner' }
);
my $other_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'other', username => 'other' }
);

subtest 'grant creates a new row' => sub {
    my $row = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $owner_dev->id, role => 'owner', granted_via => 'creator' }
    );
    is( $row->role, 'owner' );
    is( $row->granted_via, 'creator' );
};

subtest 'grant is idempotent and never downgrades an existing role/granted_via' => sub {
    my $model = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() );
    my $first_verified_at = $model->find( { plugin_id => $plugin->id, developer_id => $owner_dev->id } )->last_verified_at;

    sleep 1;    # last_verified_at has second-resolution; make the bump observable
    my $row = $model->grant(
        { plugin_id => $plugin->id, developer_id => $owner_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    is( $row->role, 'owner', 'role was not downgraded from owner to maintainer' );
    is( $row->granted_via, 'creator', 'granted_via was not overwritten' );
    isnt( $row->last_verified_at, $first_verified_at, 'last_verified_at was bumped' );
};

subtest 'a different developer gets their own row' => sub {
    my $row = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $other_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );
    is( $row->developer_id, $other_dev->id );

    my @all = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @all, 2, 'both maintainers are recorded for the plugin' );
};

done_testing();
```

- [ ] **Step 4: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin_maintainer.t
```

Expected: fails with `Can't locate KohaPluginStore/Model/PluginMaintainer.pm`.

- [ ] **Step 5: Write `lib/KohaPluginStore/Model/PluginMaintainer.pm`**

```perl
package KohaPluginStore::Model::PluginMaintainer;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_maintainers';
}

sub _columns {
    return [qw(id plugin_id developer_id role granted_via granted_at last_verified_at)];
}

# Upserts on (plugin_id, developer_id) -- an existing row only ever has its
# last_verified_at bumped, never its role/granted_via overwritten, so a later
# sync pass can never silently downgrade an owner to a plain maintainer.
sub grant {
    my ( $self, $attrs ) = @_;

    my $row = $self->pg->db->query(
        q{
            INSERT INTO plugin_maintainers (plugin_id, developer_id, role, granted_via)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (plugin_id, developer_id)
            DO UPDATE SET last_verified_at = now()
            RETURNING *
        },
        $attrs->{plugin_id}, $attrs->{developer_id}, $attrs->{role}, $attrs->{granted_via}
    )->hash;

    return $self->_new_from_row($row);
}

# Cross-table rows for the reconciliation job (Phase 2) -- plain hashes, not
# blessed Model::PluginMaintainer objects, since the shape spans three tables
# and doesn't correspond to any one of them.
sub for_reconciliation {
    my ($self) = @_;

    return $self->pg->db->query(
        q{
            SELECT pm.id, pm.plugin_id, pm.developer_id, p.repo_url, d.username
            FROM plugin_maintainers pm
            JOIN plugins p ON p.id = pm.plugin_id
            JOIN developers d ON d.id = pm.developer_id
            WHERE pm.granted_via = 'github_access'
        }
    )->hashes;
}

sub revoke {
    my ( $self, $id ) = @_;

    $self->pg->db->delete( 'plugin_maintainers', { id => $id } );
    return;
}

1;
```

- [ ] **Step 6: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin_maintainer.t
```

Expected: `All tests successful.`

- [ ] **Step 7: Verify the backfill with a direct query against the dev DB**

```bash
docker compose exec postgres psql -U koha_plugin_store -d koha_plugin_store -c \
  "SELECT count(*) FROM plugin_maintainers WHERE granted_via = 'creator';"
```

Expected: a count equal to the number of `plugins` rows that had a non-null `developer_id` before
this migration ran (check with `SELECT count(*) FROM plugins WHERE developer_id IS NOT NULL;` for
comparison).

- [ ] **Step 8: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/PluginMaintainer.pm t/model_plugin_maintainer.t
git commit -m "Add plugin_maintainers/organizations schema and the PluginMaintainer model"
```

---

### Task 2: Capture GitHub's per-repo `permissions` in `fetch_all_repos`

**Files:**
- Modify: `lib/KohaPluginStore/GitHub.pm:10-34` (the `fetch_all_repos` sub)
- Modify: `t/github.t`

**Interfaces:**
- Produces: `fetch_all_repos($access_token)` now returns, per repo,
  `{ full_name => $str, html_url => $str, permissions => { admin => $bool, maintain => $bool, push => $bool, triage => $bool, pull => $bool } }`
  (`permissions` may be `undef` if GitHub's response omitted it, e.g. an old cached mock in an
  existing test — callers must not assume it's always present).

- [ ] **Step 1: Write the failing test**

In `t/github.t`, find the existing `subtest 'fetch_all_repos ...'` block(s) (search for
`sub _fake_tx` and its callers) and add:

```perl
subtest 'fetch_all_repos captures each repo\'s permissions object' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body( Mojo::JSON::encode_json( [
            {
                full_name   => 'octocat/Hello-World',
                html_url    => 'https://github.com/octocat/Hello-World',
                permissions => { admin => 0, maintain => 0, push => 1, triage => 1, pull => 1 },
            },
        ] ) );
        return bless { result => $res }, 'FakeTx';
    };

    my $repos = KohaPluginStore::GitHub::fetch_all_repos('token');
    is( scalar @$repos, 1 );
    is_deeply(
        $repos->[0],
        {
            full_name   => 'octocat/Hello-World',
            html_url    => 'https://github.com/octocat/Hello-World',
            permissions => { admin => 0, maintain => 0, push => 1, triage => 1, pull => 1 },
        }
    );
};
```

(If `t/github.t` doesn't already `use Mojo::JSON qw(encode_json)` or similar at the top, use the
fully-qualified `Mojo::JSON::encode_json` form as above so this subtest doesn't depend on the
file's existing imports.)

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/github.t
```

Expected: fails — `is_deeply` mismatch, actual hash has no `permissions` key.

- [ ] **Step 3: Update `fetch_all_repos` in `lib/KohaPluginStore/GitHub.pm`**

Change:
```perl
push @repos, map { { full_name => $_->{full_name}, html_url => $_->{html_url} } } @$batch;
```
to:
```perl
push @repos, map { { full_name => $_->{full_name}, html_url => $_->{html_url}, permissions => $_->{permissions} } } @$batch;
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/github.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm t/github.t
git commit -m "Capture each repo's permissions object in fetch_all_repos"
```

---

### Task 3: `KohaPluginStore::MaintainerSync`

**Files:**
- Create: `lib/KohaPluginStore/MaintainerSync.pm`
- Test: `t/maintainer_sync.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::Plugin` (`find`), `KohaPluginStore::Model::PluginMaintainer`
  (`grant`) from Task 1; the `permissions`-carrying repo shape from Task 2.
- Produces:
  - `KohaPluginStore::MaintainerSync::sync_from_repo_list($pg, $developer, $repos)` — `$developer`
    a `KohaPluginStore::Model::Developer` instance, `$repos` an arrayref shaped like
    `fetch_all_repos`'s return value. No return value; side effect only.
  - `KohaPluginStore::MaintainerSync::maybe_grant_for_repo($pg, $developer, $plugin, $repo)` —
    `$plugin` a `KohaPluginStore::Model::Plugin` instance, `$repo` a single repo hashref (the
    `permissions`-carrying shape). Returns the granted `PluginMaintainer` row on success, or
    `undef` if `$repo`'s permissions don't qualify (no `push`/`admin`).

- [ ] **Step 1: Write the failing test**

Create `t/maintainer_sync.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;
use KohaPluginStore::MaintainerSync;

reset_db();

my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'dev', username => 'dev' }
);

subtest 'maybe_grant_for_repo grants on push permission' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget', permissions => { push => 1, admin => 0, pull => 1 } };

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( $row, 'granted' );
    is( $row->role, 'maintainer' );
    is( $row->granted_via, 'github_access' );
};

subtest 'maybe_grant_for_repo grants on admin permission' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget2', { repo_url => 'https://github.com/dev/widget2' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget2', permissions => { push => 0, admin => 1, pull => 1 } };

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( $row, 'granted' );
};

subtest 'maybe_grant_for_repo does not grant on pull-only permission' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget3', { repo_url => 'https://github.com/dev/widget3' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget3', permissions => { push => 0, admin => 0, pull => 1 } };

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( !$row, 'not granted' );
    ok(
        !KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $plugin->id, developer_id => $developer->id } ),
        'no row was created'
    );
};

subtest 'maybe_grant_for_repo does not grant when permissions is missing entirely' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget4', { repo_url => 'https://github.com/dev/widget4' }
    );
    my $repo = { html_url => 'https://github.com/dev/widget4' };    # no permissions key at all

    my $row = KohaPluginStore::MaintainerSync::maybe_grant_for_repo( test_pg(), $developer, $plugin, $repo );
    ok( !$row, 'not granted, not a crash' );
};

subtest 'sync_from_repo_list grants for every matching repo in the list, skips non-matching ones' => sub {
    reset_db();
    my $dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'dev2', username => 'dev2' }
    );
    my $plugin_a = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'plugin-a', { repo_url => 'https://github.com/someone/plugin-a' }
    );
    # plugin-b (below) is intentionally never submitted to this store -- fetch_all_repos can
    # return repos with no corresponding plugin row at all, and that must be a silent no-op.

    my $repos = [
        { html_url => 'https://github.com/someone/plugin-a', permissions => { push => 1 } },
        { html_url => 'https://github.com/someone/plugin-b', permissions => { push => 1 } },
    ];

    KohaPluginStore::MaintainerSync::sync_from_repo_list( test_pg(), $dev, $repos );

    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $plugin_a->id, developer_id => $dev->id } ),
        'granted for the repo that matches an existing plugin'
    );
};

done_testing();
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/maintainer_sync.t
```

Expected: fails with `Can't locate KohaPluginStore/MaintainerSync.pm`.

- [ ] **Step 3: Write `lib/KohaPluginStore/MaintainerSync.pm`**

```perl
package KohaPluginStore::MaintainerSync;

use Modern::Perl;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginMaintainer;

# Cross-references $repos (the permissions-carrying shape
# KohaPluginStore::GitHub::fetch_all_repos returns) against every
# plugins.repo_url, granting plugin_maintainers rows for $developer where
# GitHub's own data says they have push/admin access. One SELECT per repo --
# fine at this store's current scale; revisit with a single batched query if
# a developer's repo count ever makes this a real cost.
sub sync_from_repo_list {
    my ( $pg, $developer, $repos ) = @_;

    for my $repo (@$repos) {
        my $plugin = KohaPluginStore::Model::Plugin->new( pg => $pg )->find( { repo_url => $repo->{html_url} } );
        next unless $plugin;

        maybe_grant_for_repo( $pg, $developer, $plugin, $repo );
    }

    return;
}

# GitHub's /user/repos response already resolves org/team-based access into
# a plain permissions object for the token holder -- push or admin true is
# enough to trust automatically, no further API call needed. Returns the
# granted row, or undef if this repo's permissions don't qualify.
sub maybe_grant_for_repo {
    my ( $pg, $developer, $plugin, $repo ) = @_;

    my $permissions = $repo->{permissions} || {};
    return unless $permissions->{push} || $permissions->{admin};

    return KohaPluginStore::Model::PluginMaintainer->new( pg => $pg )->grant(
        {
            plugin_id    => $plugin->id,
            developer_id => $developer->id,
            role         => 'maintainer',
            granted_via  => 'github_access',
        }
    );
}

1;
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/maintainer_sync.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/MaintainerSync.pm t/maintainer_sync.t
git commit -m "Add KohaPluginStore::MaintainerSync for automatic co-maintainer grants"
```

---

### Task 4: Wire `MaintainerSync` into the repo-cache refresh points

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`_cached_developer_repos`, `refresh_repos`)
- Modify: `t/plugins_add_form.t`, `t/plugins_new_plugin.t` (the CSRF/refresh subtest)

**Interfaces:**
- Consumes: `KohaPluginStore::MaintainerSync::sync_from_repo_list` from Task 3.

- [ ] **Step 1: Write the failing test**

Add to `t/plugins_add_form.t` (after the existing `use` lines, before the top-level typeglob
override block):

```perl
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginMaintainer;
use KohaPluginStore::Model::Developer;
```

Then add a new subtest at the end, before `done_testing();`:

```perl
subtest 'visiting /new-plugin syncs maintainer status for a repo already listed here' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/octocat/Hello-World', developer_id => $owner->id }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/Hello-World',
            html_url    => 'https://github.com/octocat/Hello-World',
            permissions => { push => 1 },
        } ];
    };

    $t->get_ok('/new-plugin')->status_is(200);

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $plugin->id, developer_id => $mockdev->id } ),
        'visiting the page synced maintainer status for the matching repo'
    );

    $t->get_ok('/logout');
};
```

(`t/plugins_add_form.t` currently imports none of `Model::Plugin`/`Model::PluginMaintainer`/
`Model::Developer` — all three lines above are new additions to this file, not conditional ones.)

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_add_form.t
```

Expected: fails — no `plugin_maintainers` row exists for `$mockdev` on this plugin, since nothing
calls `MaintainerSync` yet.

- [ ] **Step 3: Wire the sync call into `Controller::Plugins.pm`**

Add near the top with the other `use` lines:
```perl
use KohaPluginStore::Model::PluginMaintainer;
use KohaPluginStore::MaintainerSync;
```

Change `_cached_developer_repos`:
```perl
sub _cached_developer_repos {
    my ($c) = @_;

    my $developer = $c->logged_in_user;
    unless ( defined $developer->data->{cached_repos} ) {
        my $repos = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
        $developer->refresh_cached_repos($repos);
        KohaPluginStore::MaintainerSync::sync_from_repo_list( $c->pg, $developer, $repos );
    }

    return ( $developer->cached_repos, $developer->cached_repos_fetched_at );
}
```

Change `refresh_repos`:
```perl
sub refresh_repos {
    my $c = shift;

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    my $developer = $c->logged_in_user;
    my $repos      = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
    $developer->refresh_cached_repos($repos);
    KohaPluginStore::MaintainerSync::sync_from_repo_list( $c->pg, $developer, $repos );

    $c->redirect_to('/new-plugin');
}
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_add_form.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Run the full suite to confirm no regressions**

Per the shared-test-DB protocol: `docker compose stop worker`, then:
```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
```
Expected: `All tests successful.` Then `docker compose start worker`.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/plugins_add_form.t
git commit -m "Sync maintainer status whenever a developer's GitHub repo cache refreshes"
```

---

### Task 5: Fix `new_plugin_confirm` — global repo lookup, grant-or-reject, no more crash

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`new_plugin_confirm`)
- Modify: `t/plugins_new_plugin.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::PluginMaintainer` (`find`, `grant`),
  `KohaPluginStore::MaintainerSync::maybe_grant_for_repo` from Tasks 1/3.

- [ ] **Step 1: Write the failing tests**

Add near the top of `t/plugins_new_plugin.t`, alongside its existing `use` lines:
```perl
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;
```

Then add to `t/plugins_new_plugin.t`, before `done_testing();`:

```perl
subtest 'a second real collaborator submitting an already-claimed repo is folded in as a maintainer, not crashed' => sub {
    reset_db();
    my $original_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'original', username => 'original' }
    );
    my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'hello-world', { repo_url => 'https://github.com/octocat/Hello-World', developer_id => $original_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $existing_plugin->id, developer_id => $original_owner->id, role => 'owner', granted_via => 'creator' }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev -- a different developer than $original_owner
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/Hello-World',
            html_url    => 'https://github.com/octocat/Hello-World',
            permissions => { push => 1 },
        } ];
    };
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v2.0.0', name => 'v2.0.0', published_at => '2026-02-01T00:00:00Z',
            author => { login => 'mockdev', avatar_url => 'https://example.com/a.png' },
            assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };

    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/octocat/Hello-World',
            tag_name    => 'v2.0.0',
            csrf_token  => csrf_token($t),
        }
    )->status_is(302);

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->search( { repo_url => 'https://github.com/octocat/Hello-World' } );
    is( scalar @plugins, 1, 'still only one plugin row -- no duplicate created' );

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $existing_plugin->id, developer_id => $mockdev->id } ),
        'the submitter was granted maintainer status'
    );

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $existing_plugin->id } );
    is( scalar @versions, 1, 'the new release was added to the existing plugin' );

    $t->get_ok('/logout');
};

subtest 'someone with no real GitHub access to an already-claimed repo still gets the existing rejection message' => sub {
    reset_db();
    my $original_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'original2', username => 'original2' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'hello-world2', { repo_url => 'https://github.com/octocat/Hello-World2', developer_id => $original_owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub { return []; };    # not in mockdev's own repo list at all

    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/octocat/Hello-World2',
            tag_name    => 'v1.0.0',
            csrf_token  => csrf_token($t),
        }
    )->status_is(200)
      ->content_like(qr/not in the list of your public GitHub repositories/);

    $t->get_ok('/logout');
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_new_plugin.t
```

Expected: the first new subtest fails with an unhandled exception (500 / non-302 status) from the
`plugins_repo_url_key` unique violation; the second passes already (no behavior change needed for
it, it's here to lock in the existing message stays correct after the rewrite).

- [ ] **Step 3: Rewrite `new_plugin_confirm` in `lib/KohaPluginStore/Controller/Plugins.pm`**

Replace the whole sub with:

```perl
sub new_plugin_confirm ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $tag_name    = $c->param('tag_name');

    unless ( $c->session->{developer} ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    my $developer_repos = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
    my ($repo_entry) = grep { $_->{html_url} eq $plugin_repo } @$developer_repos;
    return $c->_exit_with_error_message(
        'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
    ) unless $repo_entry;

    my $config  = $c->app->plugin('Config');
    my $token   = $config->{github_app_token};
    my $release = KohaPluginStore::GitHub::fetch_release_by_tag( $token, $plugin_repo, $tag_name );
    return $c->_exit_with_error_message('Could not re-fetch that release from GitHub. Please try again.')
        unless $release;

    my @kpz_assets = _kpz_assets($release);
    return $c->_exit_with_error_message(
        'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets )
        unless scalar @kpz_assets == 1;

    my $developer_id = $c->session->{developer}->{id};

    # Global lookup, not scoped to this developer -- someone else may already
    # have submitted this exact repo. If so, this submitter either already has
    # (or, via a real GitHub permission, now gets) maintainer rights on it, or
    # they're rejected with the same message a repo they have no access to at
    # all already gets -- never a duplicate-plugin crash on repo_url's unique
    # constraint.
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { repo_url => $plugin_repo } );

    if ($plugin) {
        my $is_maintainer = KohaPluginStore::Model::PluginMaintainer->new( pg => $c->pg )->find(
            { plugin_id => $plugin->id, developer_id => $developer_id }
        );
        unless ($is_maintainer) {
            my $granted = KohaPluginStore::MaintainerSync::maybe_grant_for_repo(
                $c->pg, $c->logged_in_user, $plugin, $repo_entry
            );
            return $c->_exit_with_error_message(
                'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
            ) unless $granted;
        }
    }
    else {
        my ($repo_name) = $plugin_repo =~ m{([^/]+)/?$};
        $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->create_with_unique_slug(
            $repo_name,
            {
                repo_url     => $plugin_repo,
                developer_id => $developer_id,
            }
        );
        KohaPluginStore::Model::PluginMaintainer->new( pg => $c->pg )->grant(
            { plugin_id => $plugin->id, developer_id => $developer_id, role => 'owner', granted_via => 'creator' }
        );
    }

    my $new_version = eval {
        KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->create(
            {
                plugin_id         => $plugin->id,
                tag_name          => $release->{tag_name},
                name              => $release->{name},
                date_released     => $release->{published_at},
                kpz_url           => $kpz_assets[0]->{browser_download_url},
                author_username   => $release->{author}->{login},
                author_avatar_url => $release->{author}->{avatar_url},
                status            => 'submitted',
            }
        );
    };
    return $c->_exit_with_error_message('That release has already been submitted.')
        if !$new_version && $@ =~ /plugin_versions_plugin_id_tag_name_key/;
    die $@ if !$new_version;

    $c->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_new_plugin.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Run the full suite**

`docker compose stop worker`, then
```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
```
then `docker compose start worker`. Expected: `All tests successful.`

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/plugins_new_plugin.t
git commit -m "Fold real collaborators into an existing plugin instead of crashing on repo_url"
```

---

### Task 6: Fix `bulk_import` — same global lookup, grant-or-reject

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`bulk_import`)
- Modify: `t/plugins_bulk_import.t`

**Interfaces:**
- Consumes: same as Task 5.

- [ ] **Step 1: Write the failing test**

Add near the top of `t/plugins_bulk_import.t`, alongside its existing `use` lines:
```perl
use KohaPluginStore::Model::PluginMaintainer;
```

Then add to `t/plugins_bulk_import.t`, before `done_testing();`:

```perl
subtest 'a repo already submitted by someone else is folded in as a maintainer when GitHub confirms real access' => sub {
    reset_db();
    my $original_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'original3', username => 'original3' }
    );
    my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'koha_plugin_shared', { repo_url => 'https://github.com/octocat/koha_plugin_shared', developer_id => $original_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $existing_plugin->id, developer_id => $original_owner->id, role => 'owner', granted_via => 'creator' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $existing_plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # mockdev -- a different developer than $original_owner
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/koha_plugin_shared',
            html_url    => 'https://github.com/octocat/koha_plugin_shared',
            permissions => { push => 1 },
        } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [ _release( tag_name => 'v2.0.0', name => 'v2.0.0' ) ];
    };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_shared',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Synced new release v2\.0\.0/);

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->search( { repo_url => 'https://github.com/octocat/koha_plugin_shared' } );
    is( scalar @plugins, 1, 'still only one plugin row' );

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    ok(
        KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->find( { plugin_id => $existing_plugin->id, developer_id => $mockdev->id } ),
        'the submitter was granted maintainer status'
    );

    $t->get_ok('/logout');
};

subtest 'a repo already submitted by someone else, with no real GitHub access, is reported as an error' => sub {
    reset_db();
    my $original_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'original4', username => 'original4' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'koha_plugin_locked', { repo_url => 'https://github.com/octocat/koha_plugin_locked', developer_id => $original_owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ {
            full_name   => 'octocat/koha_plugin_locked',
            html_url    => 'https://github.com/octocat/koha_plugin_locked',
            permissions => { pull => 1 },    # read-only -- must not grant
        } ];
    };

    $t->post_ok(
        '/new-plugin/bulk' => form => {
            plugin_repos => 'https://github.com/octocat/koha_plugin_locked',
            csrf_token   => csrf_token($t),
        }
    )
      ->status_is(200)
      ->content_like(qr/Not in your list/);

    $t->get_ok('/logout');
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_bulk_import.t
```

Expected: the first new subtest fails (current code's `find` is scoped to `developer_id`, so it
never sees `$existing_plugin` at all and instead tries to create a duplicate, hitting the
`repo_url` unique violation as an uncaught `die` inside the loop). The second subtest's current
behavior already happens to match (repo not owned at all is already rejected the same way) --
included here to lock it in through the upcoming rewrite, not because it's expected to fail now.

- [ ] **Step 3: Update `bulk_import` in `lib/KohaPluginStore/Controller/Plugins.pm`**

Change the repo-ownership map to keep the full entry, not just a boolean:
```perl
my $developer_repos = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
my %owned_repo = map { $_->{html_url} => $_ } @$developer_repos;
```

Then, inside the `for my $plugin_repo (@selected_repos)` loop, replace:
```perl
        unless ( $owned_repo{$plugin_repo} ) {
            push @results, { repo_url => $plugin_repo, status => 'error', message => 'Not in your list of public GitHub repositories.' };
            next;
        }

        my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find(
            { developer_id => $c->session->{developer}->{id}, repo_url => $plugin_repo }
        );
```
with:
```perl
        my $repo_entry = $owned_repo{$plugin_repo};
        unless ($repo_entry) {
            push @results, { repo_url => $plugin_repo, status => 'error', message => 'Not in your list of public GitHub repositories.' };
            next;
        }

        # Global lookup, not scoped to this developer -- someone else may
        # already have submitted this exact repo (see new_plugin_confirm's
        # identical comment for why).
        my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { repo_url => $plugin_repo } );

        if ($existing_plugin) {
            my $is_maintainer = KohaPluginStore::Model::PluginMaintainer->new( pg => $c->pg )->find(
                { plugin_id => $existing_plugin->id, developer_id => $c->session->{developer}->{id} }
            );
            unless ($is_maintainer) {
                my $granted = KohaPluginStore::MaintainerSync::maybe_grant_for_repo(
                    $c->pg, $c->logged_in_user, $existing_plugin, $repo_entry
                );
                unless ($granted) {
                    push @results, { repo_url => $plugin_repo, status => 'error', message => 'Not in your list of public GitHub repositories.' };
                    next;
                }
            }
        }
```

Further down, where a brand-new plugin gets created:
```perl
        my $plugin = $existing_plugin;
        unless ($plugin) {
            my ($repo_name) = $plugin_repo =~ m{([^/]+)/?$};
            $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->create_with_unique_slug(
                $repo_name,
                { repo_url => $plugin_repo, developer_id => $c->session->{developer}->{id} }
            );
        }
```
becomes:
```perl
        my $plugin = $existing_plugin;
        unless ($plugin) {
            my ($repo_name) = $plugin_repo =~ m{([^/]+)/?$};
            $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->create_with_unique_slug(
                $repo_name,
                { repo_url => $plugin_repo, developer_id => $c->session->{developer}->{id} }
            );
            KohaPluginStore::Model::PluginMaintainer->new( pg => $c->pg )->grant(
                { plugin_id => $plugin->id, developer_id => $c->session->{developer}->{id}, role => 'owner', granted_via => 'creator' }
            );
        }
```

Everything else in the loop (release-fetching, eligibility, version creation, `@results` push)
stays exactly as it is.

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_bulk_import.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Run the full suite**

`docker compose stop worker`, then
```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
```
then `docker compose start worker`. Expected: `All tests successful.`

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/plugins_bulk_import.t
git commit -m "Fold real collaborators into bulk import instead of crashing on repo_url"
```

### Task 7: Authorization — let a maintainer actually use their granted rights

Tasks 1–6 detect and record maintainer status, but nothing yet *checks* `plugin_maintainers`
anywhere — every existing authorization point still only compares `plugin->developer_id` to the
session, and `/my-plugins` still only lists plugins the developer literally created. Without this
task, a freshly-granted maintainer is folded into the DB correctly but can't do anything with it:
`/my-plugins` won't show the plugin, `/plugins/:slug/manage` and `update_plugin` 404/401 them, and
`Controller::Releases::new_release` rejects them. This is the spec's "Maintainer permission scope"
section (full parity except removing another maintainer/deleting the plugin) — those two
owner-only actions aren't built anywhere yet, so there's nothing to restrict; this task is purely
about *not blocking* a maintainer from the actions every existing developer already has.

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (two new methods)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`_plugin_page_stash`, `show`, `show_version`,
  `manage`, `update_plugin`, `my_plugins`)
- Modify: `lib/KohaPluginStore/Controller/Releases.pm` (`new_release`)
- Test: `t/model_plugin.t`, `t/plugins_manage.t`, `t/plugins_update.t`, `t/releases.t`,
  `t/my_plugins.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::PluginMaintainer` (Task 1).
- Produces: `KohaPluginStore::Model::Plugin->is_maintained_by($developer_id)` (instance method,
  returns 1/0) and `KohaPluginStore::Model::Plugin->for_developer($developer_id)` (instance method
  used as `KohaPluginStore::Model::Plugin->new(pg=>$pg)->for_developer($id)`, returns an arrayref of
  `Plugin` instances — owner or maintainer, either counts).

**A deliberate, minimal-diff choice:** the existing `$is_owner` variable name and the
`is_owner => $is_owner` stash key are kept as-is everywhere in `Controller::Plugins.pm`, even though
their meaning broadens to "owner or maintainer" — renaming the stash key would also require
touching every template that reads `stash 'is_owner'` (`templates/plugins/show.html.ep` at minimum)
for no behavioral benefit. Only the *computation* changes.

- [ ] **Step 1: Write the failing tests for the two new `Model::Plugin` methods**

Add to `t/model_plugin.t` (find the existing `use` block and add
`use KohaPluginStore::Model::PluginMaintainer;` and `use KohaPluginStore::Model::Developer;` if not
already present, then add near the end, before `done_testing();`):

```perl
subtest 'is_maintained_by is true for the owner column, without needing a plugin_maintainers row' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner', username => 'owner' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    ok( $plugin->is_maintained_by( $owner->id ) );
};

subtest 'is_maintained_by is true for a plugin_maintainers row, false for anyone else' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner2', username => 'owner2' }
    );
    my $maintainer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'maint', username => 'maint' }
    );
    my $stranger = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'stranger', username => 'stranger' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget2', { repo_url => 'https://github.com/dev/widget2', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $maintainer->id, role => 'maintainer', granted_via => 'github_access' }
    );

    ok( $plugin->is_maintained_by( $maintainer->id ), 'a granted maintainer counts' );
    ok( !$plugin->is_maintained_by( $stranger->id ), 'an unrelated developer does not' );
    ok( !$plugin->is_maintained_by(undef), 'no developer at all does not' );
};

subtest 'for_developer lists plugins owned or maintained, no duplicates' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner3', username => 'owner3' }
    );
    my $maintainer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'maint3', username => 'maint3' }
    );
    my $owned = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'owned-widget', { repo_url => 'https://github.com/dev/owned-widget', developer_id => $owner->id }
    );
    my $maintained = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'maintained-widget', { repo_url => 'https://github.com/dev/maintained-widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $owned->id, developer_id => $owner->id, role => 'owner', granted_via => 'creator' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $maintained->id, developer_id => $maintainer->id, role => 'maintainer', granted_via => 'github_access' }
    );

    my $plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->for_developer( $maintainer->id );
    is( scalar @$plugins, 1, 'only the maintained plugin, not the unrelated owned one' );
    is( $plugins->[0]->slug, 'maintained-widget' );
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t
```

Expected: fails — `is_maintained_by is not a column on plugins` (AUTOLOAD croaking, since the method
doesn't exist yet).

- [ ] **Step 3: Add the two methods to `lib/KohaPluginStore/Model/Plugin.pm`**

Add `use KohaPluginStore::Model::PluginMaintainer;` near the top (alongside the existing
`use KohaPluginStore::Model::PluginVersion;`), and add these two methods (anywhere after
`slugify`/`create_with_unique_slug` is a reasonable spot):

```perl
sub is_maintained_by {
    my ( $self, $developer_id ) = @_;

    return 0 unless $developer_id;
    return 1 if $self->developer_id && $self->developer_id == $developer_id;

    return KohaPluginStore::Model::PluginMaintainer->new( pg => $self->pg )
      ->find( { plugin_id => $self->id, developer_id => $developer_id } ) ? 1 : 0;
}

sub for_developer {
    my ( $self, $developer_id ) = @_;

    my $rows = $self->pg->db->query(
        q{
            SELECT DISTINCT p.*
            FROM plugins p
            LEFT JOIN plugin_maintainers pm ON pm.plugin_id = p.id
            WHERE p.developer_id = ? OR pm.developer_id = ?
            ORDER BY p.name
        },
        $developer_id, $developer_id
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Write the failing controller-level tests**

Add to `t/plugins_manage.t`, before `done_testing();`:

```perl
subtest 'a granted maintainer (not the original owner) can reach the manage page' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner5', username => 'owner5' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget5', { repo_url => 'https://github.com/dev/widget5', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # mockdev
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub { return []; };
    }

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(200);

    $t->get_ok('/logout');
};
```

(If `t/plugins_manage.t` doesn't already `use KohaPluginStore::Model::PluginMaintainer;`, add it.)

Add to `t/plugins_update.t`, before `done_testing();`:

```perl
subtest 'a granted maintainer (not the original owner) can update the plugin' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner6', username => 'owner6' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget6', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget6', author => 'Dev', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' =>
        form => { name => 'Widget', description => 'Updated by maintainer', repo_url => 'https://github.com/dev/widget6', author => 'Dev', csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->description, 'Updated by maintainer' );

    $t->get_ok('/logout');
};
```

(If `t/plugins_update.t` doesn't already `use KohaPluginStore::Model::PluginMaintainer;`, add it.)

Add near the top of `t/releases.t`, alongside its existing `use` lines:
```perl
use KohaPluginStore::Model::PluginMaintainer;
```

Then add to `t/releases.t`, before `done_testing();`:

```perl
subtest 'a granted maintainer (not the original owner) can submit a new release' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner7', username => 'owner7' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget7', { repo_url => 'https://github.com/dev/widget7', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
            return {
                tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
                author => { login => 'mockdev', avatar_url => 'https://example.com/a.png' },
                assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
            };
        };
    }

    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0', csrf_token => csrf_token($t) } )
      ->status_is(302);

    $t->get_ok('/logout');
};
```

(Check `t/releases.t`'s existing subtests for the exact `csrf_token` import and `$t`/fixture setup
convention already used there, and match it — the block above assumes the same
`use CsrfHelper qw(csrf_token);` and `test_app()`-built `$t` already present in that file.)

Add to `t/my_plugins.t`, before `done_testing();`:

```perl
subtest 'lists a plugin the developer maintains but does not own' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $other_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'other-owner', username => 'other-owner' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'shared-widget', { name => 'Shared Widget', repo_url => 'https://github.com/dev/shared-widget', developer_id => $other_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->get_ok('/my-plugins')->status_is(200)->content_like(qr/Shared Widget/);
};
```

(Add `use KohaPluginStore::Model::PluginMaintainer;` to `t/my_plugins.t`'s `use` block.)

- [ ] **Step 6: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_manage.t t/plugins_update.t t/releases.t t/my_plugins.t
```

Expected: each new subtest fails — 404/401 for `manage`/`update_plugin`/`new_release`, and the
maintained plugin missing from `/my-plugins`' output.

- [ ] **Step 7: Update the authorization checks**

In `lib/KohaPluginStore/Controller/Plugins.pm`, change each of these four lines (they're
byte-for-byte identical today, at `_plugin_page_stash`, `show`, `show_version`, and `manage` — since
an editor that requires a unique match won't accept this as one `old_string`, either replace all
four occurrences at once or edit each in place using its surrounding lines for uniqueness):
```perl
my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;
```
to:
```perl
my $is_owner = $c->session->{developer} && $plugin->is_maintained_by( $c->session->{developer}->{id} ) ? 1 : 0;
```

In `update_plugin`, change:
```perl
return $c->render( text => 'Unauthorized', status => 401 )
    unless $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id;
```
to:
```perl
return $c->render( text => 'Unauthorized', status => 401 )
    unless $c->session->{developer} && $plugin->is_maintained_by( $c->session->{developer}->{id} );
```

In `my_plugins`, change:
```perl
my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search( { developer_id => $c->session->{developer}->{id} } );
```
to:
```perl
my @plugins = @{ KohaPluginStore::Model::Plugin->new( pg => $c->pg )->for_developer( $c->session->{developer}->{id} ) };
```

In `lib/KohaPluginStore/Controller/Releases.pm`, change:
```perl
return $c->render( text => 'Unauthorized', status => 401 )
    unless $c->session->{developer}->{id} == $plugin->developer_id;
```
to:
```perl
return $c->render( text => 'Unauthorized', status => 401 )
    unless $c->session->{developer} && $plugin->is_maintained_by( $c->session->{developer}->{id} );
```
(this file's version didn't previously guard `$c->session->{developer}` being defined at all before
dereferencing `->{id}` — adding that guard here is required, not optional, since
`is_maintained_by(undef)` must never be reached from an unauthenticated request; check
`t/releases.t`'s existing anonymous-visitor subtest still passes after this change, since it may
have been relying on the dereference itself dying in a way that happened to produce the right
status code.)

- [ ] **Step 8: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t t/plugins_manage.t t/plugins_update.t t/releases.t t/my_plugins.t
```

Expected: `All tests successful.`

- [ ] **Step 9: Run the full suite**

`docker compose stop worker`, then
```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
```
then `docker compose start worker`. Expected: `All tests successful.`

- [ ] **Step 10: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm lib/KohaPluginStore/Controller/Plugins.pm lib/KohaPluginStore/Controller/Releases.pm t/model_plugin.t t/plugins_manage.t t/plugins_update.t t/releases.t t/my_plugins.t
git commit -m "Let a granted maintainer manage, update, and release like the owner can"
```

---

**Phase 1 complete here.** Everything above is independently shippable: co-maintainers get
detected, folded in, and can actually exercise their rights; the crash is fixed. The only known gap
until Phase 2 lands is that a maintainer who *loses* GitHub access keeps store rights until someone
notices.

---

## Phase 2 — Revocation

### Task 8: `fetch_collaborator_permission` in `KohaPluginStore::GitHub`

**Files:**
- Modify: `lib/KohaPluginStore/GitHub.pm`
- Modify: `t/github.t`

**Interfaces:**
- Produces: `fetch_collaborator_permission($access_token, $owner_repo, $username)` returns:
  - `{ ok => 1, permission => 'admin'|'write'|'read'|'none'|... }` on a 200 response
  - `{ ok => 1, not_found => 1 }` on a 404 response (repo/user no longer resolves)
  - `{ ok => 0 }` on anything else (rate limit, 403, 5xx, network error) — callers must never treat
    this as "revoke," only as "couldn't tell this time."

- [ ] **Step 1: Write the failing test**

Add to `t/github.t`:

```perl
subtest 'fetch_collaborator_permission returns the permission string on success' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body( Mojo::JSON::encode_json( { permission => 'write', user => { login => 'someone' } } ) );
        return bless { result => $res }, 'FakeTx';
    };

    is_deeply(
        KohaPluginStore::GitHub::fetch_collaborator_permission( 'token', 'https://github.com/dev/widget', 'someone' ),
        { ok => 1, permission => 'write' }
    );
};

subtest 'fetch_collaborator_permission reports not_found on a 404 (repo/user gone)' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is_deeply(
        KohaPluginStore::GitHub::fetch_collaborator_permission( 'token', 'https://github.com/dev/widget', 'someone' ),
        { ok => 1, not_found => 1 }
    );
};

subtest 'fetch_collaborator_permission reports not ok on a rate-limit/error response, never guesses' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(403);
        return bless { result => $res }, 'FakeTx';
    };

    is_deeply(
        KohaPluginStore::GitHub::fetch_collaborator_permission( 'token', 'https://github.com/dev/widget', 'someone' ),
        { ok => 0 }
    );
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/github.t
```

Expected: fails — `fetch_collaborator_permission` doesn't exist yet.

- [ ] **Step 3: Add `fetch_collaborator_permission` to `lib/KohaPluginStore/GitHub.pm`**

Add near `fetch_tag_verification` (same "answers about a specific piece of GitHub-side trust"
family):

```perl
# Unlike fetch_all_repos's /user/repos (which answers "what can the token
# holder do"), this answers "what can this specific *other* username do" --
# the only endpoint that can, which is why the revocation job needs it
# instead of reusing the grant side's data source. Note the different
# vocabulary: this returns a *string* permission ('admin'/'write'/'read'/
# 'none'), not the boolean push/admin/pull object /user/repos returns.
sub fetch_collaborator_permission {
    my ( $access_token, $owner_repo, $username ) = @_;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = _get( "$api_repo/collaborators/$username/permission", $access_token );
    my $code = $tx->result->code;

    return { ok => 1, permission => $tx->result->json->{permission} } if $code == 200;
    return { ok => 1, not_found => 1 } if $code == 404;
    return { ok => 0 };
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/github.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm t/github.t
git commit -m "Add fetch_collaborator_permission for the maintainer-reconciliation job"
```

---

### Task 9: `reconcile_maintainers` command

**Files:**
- Create: `lib/KohaPluginStore/Command/reconcile_maintainers.pm`
- Test: `t/command_reconcile_maintainers.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::PluginMaintainer::for_reconciliation`/`revoke` (Task 1),
  `KohaPluginStore::GitHub::fetch_collaborator_permission` (Task 8).

- [ ] **Step 1: Write the failing test**

Create `t/command_reconcile_maintainers.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::reconcile_maintainers;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget', { repo_url => 'https://github.com/dev/widget' }
);

my $still_has_access = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'a', username => 'still-has-access' }
);
my $lost_access = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'b', username => 'lost-access' }
);
my $api_errored = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'c', username => 'api-errored' }
);
my $manually_granted = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'd', username => 'manually-granted' }
);

my $maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $still_has_access->id, role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $lost_access->id,      role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $api_errored->id,      role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $manually_granted->id, role => 'maintainer', granted_via => 'manual' } );

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_collaborator_permission = sub {
        my ( $token, $repo_url, $username ) = @_;
        return { ok => 1, permission => 'write' }  if $username eq 'still-has-access';
        return { ok => 1, permission => 'read' }   if $username eq 'lost-access';
        return { ok => 0 }                         if $username eq 'api-errored';
        die "unexpected username $username (manually-granted should never be checked)";
    };
}

my $app = KohaPluginStore->new;
$app->pg( test_pg() );
$app->config->{github_app_token} = 'irrelevant-because-mocked';

KohaPluginStore::Command::reconcile_maintainers->new( app => $app )->run;

ok(
    $maintainer_model->find( { plugin_id => $plugin->id, developer_id => $still_has_access->id } ),
    'a maintainer who still has write access keeps their row'
);
ok(
    !$maintainer_model->find( { plugin_id => $plugin->id, developer_id => $lost_access->id } ),
    'a maintainer whose permission dropped below write is revoked'
);
ok(
    $maintainer_model->find( { plugin_id => $plugin->id, developer_id => $api_errored->id } ),
    'a maintainer is NOT revoked when the API call itself failed (never guess on uncertainty)'
);
ok(
    $maintainer_model->find( { plugin_id => $plugin->id, developer_id => $manually_granted->id } ),
    'a manually-granted maintainer is never even checked, let alone revoked'
);

done_testing();
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/command_reconcile_maintainers.t
```

Expected: fails — `Can't locate KohaPluginStore/Command/reconcile_maintainers.pm`.

- [ ] **Step 3: Write `lib/KohaPluginStore/Command/reconcile_maintainers.pm`**

```perl
package KohaPluginStore::Command::reconcile_maintainers;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::GitHub;
use KohaPluginStore::Model::PluginMaintainer;

has description => 'Revoke stale github_access-granted plugin_maintainers rows';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg    = $self->app->pg;
    my $token = $self->app->config->{github_app_token};

    my $maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => $pg );
    my $rows             = $maintainer_model->for_reconciliation;

    my ( $kept, $revoked, $skipped ) = ( 0, 0, 0 );
    for my $row (@$rows) {
        my $result = KohaPluginStore::GitHub::fetch_collaborator_permission( $token, $row->{repo_url}, $row->{username} );

        unless ( $result->{ok} ) {
            warn "plugin_maintainers.id=$row->{id}: could not verify '$row->{username}' on $row->{repo_url}, leaving unchanged\n";
            $skipped++;
            next;
        }

        my $permission = $result->{permission} // 'none';
        if ( $permission eq 'admin' || $permission eq 'write' ) {
            $kept++;
            next;
        }

        $maintainer_model->revoke( $row->{id} );
        $revoked++;
    }

    say "Reconciled maintainers: $kept kept, $revoked revoked, $skipped skipped (could not verify).";
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::reconcile_maintainers - Revoke stale plugin_maintainers rows

=head1 SYNOPSIS

  Usage: APPLICATION reconcile_maintainers

  Re-checks every github_access-granted plugin_maintainers row against GitHub's current
  per-repo collaborator permission for that developer, using github_app_token. Below
  write/admin, or the repo/user no longer resolves at all, revokes the row. A row granted
  'creator' or 'manual' is never touched. An API call that fails outright (rate limit,
  network error, insufficient app-token scope) leaves that row unchanged rather than
  guessing.

=cut
```

- [ ] **Step 4: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/command_reconcile_maintainers.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Command/reconcile_maintainers.pm t/command_reconcile_maintainers.t
git commit -m "Add reconcile_maintainers command to revoke stale maintainer grants"
```

---

### Task 10: Deployment — systemd timer and documentation

**Files:**
- Create: `koha_plugin_store-reconcile-maintainers.service.example`
- Create: `koha_plugin_store-reconcile-maintainers.timer.example`
- Modify: `DEPLOYMENT.md`

**Interfaces:** None — this task is deployment/documentation only, no application code.

- [ ] **Step 1: Create `koha_plugin_store-reconcile-maintainers.service.example`**

```
# koha-plugin-store-reconcile-maintainers.service
[Unit]
Description=Koha Plugin Store maintainer-reconciliation run
After=syslog.target network.target koha-plugin-store.service

[Service]
Type=oneshot
## make sure the user & group exist
User=plugin-store
Group=plugin-store
## change the below values to suit your installation
## Carton installs dependencies into a project-local local/, not the
## system/vendor Perl lib -- see DEPLOYMENT.md's Install section.
Environment=PERL5LIB=/opt/plugin-store/local/lib/perl5
WorkingDirectory=/opt/plugin-store
## end of config values
ExecStart=/usr/bin/perl script/koha_plugin_store reconcile_maintainers
SyslogIdentifier=koha-plugin-store-reconcile-maintainers
```

- [ ] **Step 2: Create `koha_plugin_store-reconcile-maintainers.timer.example`**

```
# koha-plugin-store-reconcile-maintainers.timer
[Unit]
Description=Run koha-plugin-store-reconcile-maintainers.service daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Document both in `DEPLOYMENT.md`**

Find the section documenting the existing `worker`/`sandbox-broker` systemd units (search for
`koha_plugin_store-worker.service.example` in `DEPLOYMENT.md`) and add a paragraph immediately
after it:

```markdown
### Maintainer reconciliation

`koha_plugin_store-reconcile-maintainers.service.example` and
`koha_plugin_store-reconcile-maintainers.timer.example` run
`script/koha_plugin_store reconcile_maintainers` once a day — it re-checks every
automatically-granted co-maintainer against GitHub's current permissions and revokes any that no
longer have write access. Copy both to `/etc/systemd/system/` (dropping the `.example` suffix),
adjust the same `User`/`Group`/`PERL5LIB`/`WorkingDirectory` values as the other units, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now koha-plugin-store-reconcile-maintainers.timer
```

This is a `oneshot` service triggered by its timer, not a long-running daemon like `worker` --
there's nothing to `enable --now` on the `.service` itself.
```

- [ ] **Step 4: Commit**

```bash
git add koha_plugin_store-reconcile-maintainers.service.example koha_plugin_store-reconcile-maintainers.timer.example DEPLOYMENT.md
git commit -m "Document the reconcile_maintainers systemd timer for deployment"
```

---

## Self-review notes (for whoever executes this plan)

- Task 1's `Model::PluginMaintainer` test asserts `last_verified_at` changes across a `grant()`
  call one second apart — this is a real `sleep 1` in the test, acceptable here since it's one
  second in one subtest, not a pattern to repeat casually elsewhere.
- Tasks 5 and 6 deliberately do **not** share a helper function despite doing conceptually similar
  work — `new_plugin_confirm` and `bulk_import` have different response shapes (redirect+rendered
  errors vs. an accumulated results table) and different existing, already-tested call sites; unifying
  them would touch more of each file's tested behavior than this plan's actual goal requires. If a
  future task wants to de-duplicate them, that's a separate, explicitly-scoped cleanup — not
  bundled in here.
- `github_app_token`'s scope sufficiency for Task 8/9's collaborator-permission endpoint is a real
  open risk (see the spec) — Task 9's tests mock the GitHub call, so they'll pass regardless; the
  first real run of `reconcile_maintainers` against production is what actually answers this. If it
  turns out the token can't do this, `Command::reconcile_maintainers`'s `warn` output will show every
  row as `skipped`, which is the intended fail-safe behavior (never guess), not a silent failure.
