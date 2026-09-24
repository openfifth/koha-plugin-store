# Auto-Sync Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any maintainer opt a plugin into automatic ingestion of its new GitHub releases, checked nightly (and on demand via a manual button), using exactly the same eligibility rule a manual submission already enforces.

**Architecture:** A new `auto_sync_releases` boolean on `plugins`. A nightly `sync_plugin_releases` command fans out one `sync_plugin_release` Minion job per opted-in plugin (Approach B from the design spec: the command itself makes no GitHub calls and touches no data, so one plugin's failure can't affect any other). Each per-plugin job reuses the store's existing release-eligibility rule (relocated into a small shared `KohaPluginStore::GitHub` helper) and the same create-version-then-enqueue-`process_plugin_version` pattern `new_release`/`bulk_import` already use. A manual "check now" button and the opt-in toggle live on the existing maintainer-only `/plugins/:slug/manage` page.

**Tech Stack:** Mojolicious, Mojo::Pg, Minion (existing stack — no new dependencies).

**Spec:** `docs/superpowers/specs/2026-09-24-auto-sync-releases-design.md`

## Global Constraints

- Any maintainer (owner or co-maintainer, via `Model::Plugin::is_maintained_by`) can use both new controller actions — no owner-only restriction (unlike `update_plugin`'s `repo_url` field).
- No new notification system: an ineligible/failed release during auto-sync is skipped with a `warn` to the job's own log, exactly like `reconcile_maintainers`'s established precedent. No new `plugin_versions` row is created for it.
- `Model::Base::search`'s `default_query_params` caps every unqualified `search()` call at **10 rows** (`sub default_query_params { return { limit => 10 } }` in `lib/KohaPluginStore/Model/Base.pm`). Any query in this plan that must return "every matching row, not a paginated page" uses a raw `$self->pg->db->query(...)` call instead of `search()`, matching the precedent already set by `Model::Plugin::for_developer` and `Model::PluginMaintainer::for_reconciliation` — never pass an ad-hoc large `limit` as a workaround.
- Every new controller action follows the existing order already used by `update_plugin`/`new_release`: 404 (not found) → 401 (not a maintainer) → 403 (CSRF) → do the work.
- Minion job tests in this codebase enqueue the job and call `$t->app->minion->perform_jobs_in_foreground` to run it synchronously, then assert on database state — not `$t->app->minion->jobs(...)->total` alone (that pattern is used only to assert *that* a job was enqueued, not to run it).
- Any test that touches `$app->minion` for **any** reason (enqueueing, inspecting `->jobs`, running jobs) must build its app via `test_app()` from `t/lib/TestDB.pm`, never a bare `KohaPluginStore->new` — `test_app()` is the only helper that also repoints Minion's own backend connection at the test database; a bare `->new` plus `->pg(test_pg())` leaves Minion silently talking to the real dev database (see `TestDB.pm`'s own comment on `test_app`). A command test that never touches Minion (like the existing `reconcile_maintainers` one) is fine with a bare `->new` — that precedent does not extend to any task in this plan, since every one of them uses Minion.

---

### Task 1: `auto_sync_releases` column

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (append migration `11`)
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (`_columns`)
- Test: `t/model_plugin.t`

**Interfaces:**
- Produces: `plugins.auto_sync_releases` (boolean, default `false`), readable/writable via the existing `Model::Plugin` `AUTOLOAD` accessor (`$plugin->auto_sync_releases`) and `$plugin->update({ auto_sync_releases => 1 })`, exactly like every other column.

- [ ] **Step 1: Write the failing test**

Add to `t/model_plugin.t` (after the existing `subtest`s, before `done_testing()` — check the file's exact current ending first):

```perl
subtest 'auto_sync_releases defaults to false and can be toggled via update' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    ok( !$plugin->auto_sync_releases, 'defaults to false' );

    $plugin->update( { auto_sync_releases => 1 } );
    ok( $plugin->auto_sync_releases, 'update flips it to true' );

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->auto_sync_releases, 'persisted to the database, not just the in-memory object' );
};
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t
```

Expected: fails — `auto_sync_releases is not a column on plugins` (the `AUTOLOAD` croak from `Model::Base`).

- [ ] **Step 3: Add migration 11**

Append to `lib/KohaPluginStore/Command/migrate.pm`'s `__DATA__` section, after the existing `-- 10 down` block (do not renumber or edit anything above it):

```
-- 11 up
ALTER TABLE plugins ADD COLUMN auto_sync_releases BOOLEAN NOT NULL DEFAULT false;

-- 11 down
ALTER TABLE plugins DROP COLUMN auto_sync_releases;
```

- [ ] **Step 4: Apply the migration against the running dev stack**

```bash
docker compose exec app script/koha_plugin_store migrate
```

Expected output ends with `Migrated to version 11`.

- [ ] **Step 5: Add the column to `Model::Plugin`'s `_columns`**

In `lib/KohaPluginStore/Model/Plugin.pm`, change:

```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url changelog_html)];
}
```

to:

```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url changelog_html auto_sync_releases)];
}
```

- [ ] **Step 6: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t
```

Expected: `All tests successful.`

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/Plugin.pm t/model_plugin.t
git commit -m "Add plugins.auto_sync_releases column"
```

---

### Task 2: Shared GitHub release-eligibility helper

**Files:**
- Modify: `lib/KohaPluginStore/GitHub.pm` (add `kpz_assets`, `new_releases`)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (remove `_kpz_assets`, update its 4 call sites)
- Test: `t/github.t`

**Interfaces:**
- Produces: `KohaPluginStore::GitHub::kpz_assets($release)` — same dual-context contract as the helper it replaces (scalar context: count of assets whose name matches `/\.kpz$/`; list context: the matching asset hashrefs themselves, each shaped `{ name => ..., browser_download_url => ... }` as returned by `fetch_releases`/`fetch_release_by_tag`).
- Produces: `KohaPluginStore::GitHub::new_releases($releases, $existing_tags)` — `$releases` is an arrayref as returned by `fetch_releases`; `$existing_tags` is a hashref of `{ tag_name => 1, ... }`; returns an arrayref of the entries in `$releases` whose `tag_name` is not a key in `$existing_tags` AND have exactly one `.kpz` asset.

- [ ] **Step 1: Write the failing tests**

Add to `t/github.t` (before `done_testing()`):

```perl
subtest 'kpz_assets counts in scalar context, returns the matching assets in list context' => sub {
    my $release = {
        assets => [
            { name => 'README.md',  browser_download_url => 'https://example.com/README.md' },
            { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' },
        ],
    };
    is( scalar KohaPluginStore::GitHub::kpz_assets($release), 1, 'scalar context returns a count' );

    my @assets = KohaPluginStore::GitHub::kpz_assets($release);
    is( scalar @assets, 1, 'list context returns the matching assets' );
    is( $assets[0]->{browser_download_url}, 'https://example.com/plugin.kpz' );
};

subtest 'new_releases excludes already-submitted tags and releases without exactly one .kpz asset' => sub {
    my $releases = [
        { tag_name => 'v1.0.0', assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/v1.kpz' } ] },
        { tag_name => 'v2.0.0', assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/v2.kpz' } ] },
        { tag_name => 'v3.0.0', assets => [] },
        { tag_name => 'v4.0.0', assets => [
            { name => 'plugin.kpz', browser_download_url => 'https://example.com/v4a.kpz' },
            { name => 'plugin2.kpz', browser_download_url => 'https://example.com/v4b.kpz' },
        ] },
    ];
    my $existing_tags = { 'v1.0.0' => 1 };

    my $eligible = KohaPluginStore::GitHub::new_releases( $releases, $existing_tags );

    is( scalar @$eligible, 1, 'only one release is both new and has exactly one .kpz asset' );
    is( $eligible->[0]->{tag_name}, 'v2.0.0' );
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/github.t
```

Expected: fails — `Undefined subroutine &KohaPluginStore::GitHub::kpz_assets called`.

- [ ] **Step 3: Add `kpz_assets` and `new_releases` to `lib/KohaPluginStore/GitHub.pm`**

Add near `fetch_releases`:

```perl
# The store only accepts a release packaged as exactly one file -- callers
# decide what "exactly one" vs "zero or several" means for them (a Perl
# grep, so scalar context returns a count, list context the matching assets).
sub kpz_assets {
    my ($release) = @_;
    return grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
}

# Returns the subset of $releases (as returned by fetch_releases) that are
# both new (tag not in $existing_tags) and carry exactly one '.kpz' asset --
# the same eligibility rule a manual submission already enforces.
sub new_releases {
    my ( $releases, $existing_tags ) = @_;
    return [ grep { !$existing_tags->{ $_->{tag_name} } && kpz_assets($_) == 1 } @$releases ];
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/github.t
```

Expected: `All tests successful.`

- [ ] **Step 5: Remove `_kpz_assets` from `Controller::Plugins.pm` and redirect its 4 call sites**

In `lib/KohaPluginStore/Controller/Plugins.pm`, delete this sub entirely (it now lives in `GitHub.pm`, unchanged):

```perl
# The store only accepts a release packaged as exactly one file -- callers
# decide what "exactly one" vs "zero or several" means for them (a Perl
# grep, so scalar context returns a count, list context the matching assets).
sub _kpz_assets {
    my ($release) = @_;
    return grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
}
```

Then update its 4 call sites, matching by surrounding content (their line numbers will have shifted):

In `manage()`, change:
```perl
        if ( _kpz_assets($release) != 1 ) {
```
to:
```perl
        if ( KohaPluginStore::GitHub::kpz_assets($release) != 1 ) {
```

In `new_plugin()` (the POST handler that renders `new-plugin-step2`, not `add_form`), change:
```perl
    for my $release (@$releases) {
        my $kpz_count = _kpz_assets($release);
```
to:
```perl
    for my $release (@$releases) {
        my $kpz_count = KohaPluginStore::GitHub::kpz_assets($release);
```

In `new_plugin_confirm()`, change:
```perl
    my @kpz_assets = _kpz_assets($release);
    return $c->_exit_with_error_message(
        'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets )
        unless scalar @kpz_assets == 1;
```
to:
```perl
    my @kpz_assets = KohaPluginStore::GitHub::kpz_assets($release);
    return $c->_exit_with_error_message(
        'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets )
        unless scalar @kpz_assets == 1;
```

In `bulk_import()`, change:
```perl
        my ($release) = grep { !$existing_tags{ $_->{tag_name} } && _kpz_assets($_) == 1 } @$releases;
```
to:
```perl
        my ($release) = @{ KohaPluginStore::GitHub::new_releases( $releases, \%existing_tags ) };
```

and change:
```perl
        my @kpz_assets = _kpz_assets($release);
```
to:
```perl
        my @kpz_assets = KohaPluginStore::GitHub::kpz_assets($release);
```

- [ ] **Step 6: Run the full suite to confirm nothing else broke**

This is a behavior-preserving rename plus one substitution of an inline `grep` for the equivalent `GitHub::new_releases` call in `bulk_import` — `t/plugins_manage.t`, `t/plugins_new_plugin.t`, `t/plugins_bulk_import.t` all exercise these call sites already and must still pass unmodified.

```bash
docker compose stop worker
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
docker compose start worker
```

Expected: `All tests successful.`

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm lib/KohaPluginStore/Controller/Plugins.pm t/github.t
git commit -m "Relocate the .kpz-asset eligibility helper to GitHub.pm, add new_releases"
```

---

### Task 3: `SyncPluginRelease` Minion task

**Files:**
- Create: `lib/KohaPluginStore/Task/SyncPluginRelease.pm`
- Modify: `lib/KohaPluginStore.pm` (register the task)
- Modify: `lib/KohaPluginStore/Model/PluginVersion.pm` (add `existing_tags`)
- Test: `t/task_sync_plugin_release.t`

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_releases($token, $repo_url)` (existing), `KohaPluginStore::GitHub::new_releases($releases, $existing_tags)` and `KohaPluginStore::GitHub::kpz_assets($release)` (Task 2).
- Produces: a registered Minion job named `sync_plugin_release`, taking one argument (`$plugin_id`) — this is the exact job name Tasks 4 and 5 enqueue.
- Produces: `KohaPluginStore::Model::PluginVersion::existing_tags($plugin_id)` — returns a hashref `{ tag_name => 1, ... }` of every `plugin_versions` row for that plugin, via a raw query (not `search()`, which caps at 10 rows — see Global Constraints).

- [ ] **Step 1: Write the failing test**

Create `t/task_sync_plugin_release.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

sub _release {
    my (%overrides) = @_;
    return {
        tag_name     => 'v1.0.0',
        name         => 'v1.0.0',
        published_at => '2026-01-01T00:00:00Z',
        author       => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
        assets       => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        %overrides,
    };
}

reset_db();

my $t = test_app();

subtest 'a new eligible release creates a version and enqueues process_plugin_version' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release() ] };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 1, 'one version was created' );
    is( $versions[0]->tag_name, 'v1.0.0' );
    is( $versions[0]->status, 'submitted' );

    is( $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total, 1, 'process_plugin_version was enqueued for it' );
};

subtest 'an already-submitted tag is skipped, not re-created' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release() ] };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 1, 'still only the one pre-existing version -- nothing duplicated' );
};

subtest 'a release with no valid .kpz asset is skipped' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return [ _release( assets => [] ) ] };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 0, 'no version was created for a release with no .kpz asset' );
};

subtest 'one release failing to create does not stop a second, genuinely eligible release in the same run' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    # Pre-existing version with the same tag as one of the two "new" releases
    # below -- its create() will hit plugin_versions_plugin_id_tag_name_key
    # and die, simulating the create-time failure this subtest is about.
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [ _release( tag_name => 'v1.0.0' ), _release( tag_name => 'v2.0.0', name => 'v2.0.0' ) ];
    };
    # existing_tags() only knows about the real pre-existing row, so
    # new_releases() will (correctly) treat v1.0.0 as new too -- the actual
    # unique-constraint clash is only discovered at create() time, which is
    # exactly the race this subtest exercises.
    *KohaPluginStore::Model::PluginVersion::existing_tags = sub { return {}; };

    $t->app->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @versions, 2, 'the original v1.0.0 plus the newly-created v2.0.0 -- the v1.0.0 create failure did not stop v2.0.0' );
    ok( ( grep { $_->tag_name eq 'v2.0.0' } @versions ), 'v2.0.0 was created despite v1.0.0 failing in the same run' );
};

done_testing();
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/task_sync_plugin_release.t
```

Expected: fails — `sync_plugin_release` is not a registered Minion task.

- [ ] **Step 3: Add `existing_tags` to `Model::PluginVersion`**

In `lib/KohaPluginStore/Model/PluginVersion.pm`, add:

```perl
# Every tag_name already recorded for a plugin, as a { tag_name => 1 }
# lookup hash -- a raw query, not search(), since search()'s default
# limit of 10 rows would silently miss tags on a plugin with more than
# 10 versions.
sub existing_tags {
    my ( $self, $plugin_id ) = @_;

    my $rows = $self->pg->db->query(
        q{SELECT tag_name FROM plugin_versions WHERE plugin_id = ?}, $plugin_id
    )->hashes;

    return { map { $_->{tag_name} => 1 } @$rows };
}
```

- [ ] **Step 4: Create `lib/KohaPluginStore/Task/SyncPluginRelease.pm`**

```perl
package KohaPluginStore::Task::SyncPluginRelease;

use Modern::Perl;

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::GitHub;

sub register {
    my ($app) = @_;
    $app->minion->add_task( sync_plugin_release => \&run );
}

sub run {
    my ( $job, $plugin_id ) = @_;

    my $app    = $job->app;
    my $pg     = $app->pg;
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $pg )->find( { id => $plugin_id } );
    return $job->fail("plugin_id=$plugin_id not found") unless $plugin;

    my $token    = $app->config->{github_app_token};
    my $releases = KohaPluginStore::GitHub::fetch_releases( $token, $plugin->repo_url );

    my $existing_tags = KohaPluginStore::Model::PluginVersion->new( pg => $pg )->existing_tags( $plugin->id );
    my $eligible       = KohaPluginStore::GitHub::new_releases( $releases, $existing_tags );

    for my $release (@$eligible) {
        my @kpz_assets  = KohaPluginStore::GitHub::kpz_assets($release);
        my $new_version = eval {
            KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
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
        unless ($new_version) {
            warn "sync_plugin_release: plugin_id=$plugin_id tag=$release->{tag_name}: $@";
            next;
        }
        $app->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );
    }
}

1;
```

- [ ] **Step 5: Register the task in `lib/KohaPluginStore.pm`**

Find:
```perl
use KohaPluginStore::Task::ProcessPluginVersion;
```
Add immediately after:
```perl
use KohaPluginStore::Task::SyncPluginRelease;
```

Find:
```perl
    KohaPluginStore::Task::ProcessPluginVersion::register($self);
```
Add immediately after:
```perl
    KohaPluginStore::Task::SyncPluginRelease::register($self);
```

- [ ] **Step 6: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/task_sync_plugin_release.t
```

Expected: `All tests successful.`

- [ ] **Step 7: Run the full suite**

```bash
docker compose stop worker
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
docker compose start worker
```

Expected: `All tests successful.`

- [ ] **Step 8: Commit**

```bash
git add lib/KohaPluginStore/Task/SyncPluginRelease.pm lib/KohaPluginStore.pm lib/KohaPluginStore/Model/PluginVersion.pm t/task_sync_plugin_release.t
git commit -m "Add the sync_plugin_release Minion task"
```

---

### Task 4: `sync_plugin_releases` nightly command

**Files:**
- Create: `lib/KohaPluginStore/Command/sync_plugin_releases.pm`
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (add `auto_sync_enabled`)
- Test: `t/command_sync_plugin_releases.t`

**Interfaces:**
- Consumes: the `sync_plugin_release` Minion job (Task 3) — enqueued by plugin id only, never run inline.
- Produces: `KohaPluginStore::Model::Plugin::auto_sync_enabled()` — returns an arrayref of every `Plugin` instance with `auto_sync_releases = true`, via a raw query (not `search()` — see Global Constraints).

- [ ] **Step 1: Write the failing test**

Create `t/command_sync_plugin_releases.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Command::sync_plugin_releases;
use KohaPluginStore::Model::Plugin;

reset_db();

# test_app() (not a bare KohaPluginStore->new) is required here, not just for
# convenience -- it's the only helper that also repoints Minion's own backend
# connection at the test database (see TestDB.pm's own comment on test_app).
# A bare KohaPluginStore->new + ->pg(test_pg()) leaves $app->minion silently
# talking to the real dev database, since Minion's backend is a separate
# connection registered at startup(), independent of $app->pg.
my $t = test_app();

my $opted_in_a = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget-a', { repo_url => 'https://github.com/dev/widget-a', auto_sync_releases => 1 }
);
my $opted_in_b = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget-b', { repo_url => 'https://github.com/dev/widget-b', auto_sync_releases => 1 }
);
my $opted_out = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget-c', { repo_url => 'https://github.com/dev/widget-c' }
);

KohaPluginStore::Command::sync_plugin_releases->new( app => $t->app )->run;

is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'], args => [ $opted_in_a->id ] } )->total, 1, 'a job was enqueued for opted-in plugin A' );
is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'], args => [ $opted_in_b->id ] } )->total, 1, 'a job was enqueued for opted-in plugin B' );
is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'], args => [ $opted_out->id ] } )->total, 0, 'no job was enqueued for the opted-out plugin' );
is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } )->total, 2, 'exactly two jobs total -- one per opted-in plugin, not one per plugin in the catalog' );

done_testing();
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/command_sync_plugin_releases.t
```

Expected: fails — `Can't locate KohaPluginStore/Command/sync_plugin_releases.pm`.

- [ ] **Step 3: Add `auto_sync_enabled` to `Model::Plugin`**

In `lib/KohaPluginStore/Model/Plugin.pm`, add (near `for_developer`):

```perl
# Every plugin with auto_sync_releases enabled, for the nightly sync
# command -- a raw query, not search(), since search()'s default limit
# of 10 rows would silently only ever process the first 10 opted-in
# plugins.
sub auto_sync_enabled {
    my ($self) = @_;

    my $rows = $self->pg->db->query(
        q{SELECT * FROM plugins WHERE auto_sync_releases = true}
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}
```

- [ ] **Step 4: Create `lib/KohaPluginStore/Command/sync_plugin_releases.pm`**

```perl
package KohaPluginStore::Command::sync_plugin_releases;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::Plugin;

has description => 'Enqueue a release-sync job for every auto_sync_releases-enabled plugin';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $plugins = KohaPluginStore::Model::Plugin->new( pg => $self->app->pg )->auto_sync_enabled;

    $self->app->minion->enqueue( sync_plugin_release => [ $_->id ] ) for @$plugins;

    say 'Enqueued release sync for ' . scalar(@$plugins) . ' opted-in plugin(s).';
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::sync_plugin_releases - Enqueue release-sync jobs for opted-in plugins

=head1 SYNOPSIS

  Usage: APPLICATION sync_plugin_releases

  Enqueues one sync_plugin_release job per plugin with auto_sync_releases enabled. Makes no
  GitHub calls and touches no plugin_versions rows itself -- each plugin's actual check and
  submission happens in its own Minion job, so one plugin's failure can't affect any other.

=cut
```

- [ ] **Step 5: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/command_sync_plugin_releases.t
```

Expected: `All tests successful.`

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Command/sync_plugin_releases.pm lib/KohaPluginStore/Model/Plugin.pm t/command_sync_plugin_releases.t
git commit -m "Add the sync_plugin_releases nightly fan-out command"
```

---

### Task 5: Manual trigger, opt-in toggle, and manage-page UI

**Files:**
- Modify: `lib/KohaPluginStore.pm` (2 new routes)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (2 new actions: `sync_releases_now`, `toggle_auto_sync`)
- Modify: `templates/plugins/manage.html.ep` (checkbox + button)
- Test: `t/plugins_manage.t`

**Interfaces:**
- Consumes: `Model::Plugin::is_maintained_by` (existing), the `sync_plugin_release` job name (Task 3).
- Produces: `POST /plugins/:slug/sync-releases` and `POST /plugins/:slug/auto-sync`, both maintainer-gated the same way `update_plugin` is.

- [ ] **Step 1: Write the failing tests**

`t/plugins_manage.t` does not yet import the CSRF test helper (it has no POST routes to test today). Add this import alongside its existing `use` lines, near `use KohaPluginStore::Model::PluginMaintainer;`:

```perl
use CsrfHelper qw(csrf_token);
```

Then add the following subtests to `t/plugins_manage.t` (before `done_testing()`):

```perl
subtest 'a maintainer can trigger an immediate release sync' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/sync-releases' => form => { csrf_token => csrf_token($t) } )
      ->status_is(302);

    is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'], args => [ $plugin->id ] } )->total, 1, 'a sync job was enqueued for this plugin' );

    $t->get_ok('/logout');
};

subtest 'a non-maintainer cannot trigger a sync' => sub {
    reset_db();
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev, NOT $real_owner
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/sync-releases' => form => { csrf_token => csrf_token($t) } )
      ->status_is(401);

    is( $t->app->minion->jobs( { tasks => ['sync_plugin_release'] } )->total, 0, 'no job was enqueued' );

    $t->get_ok('/logout');
};

subtest 'a co-maintainer (not the owner) can toggle auto-sync on' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $maintainer_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $maintainer_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/auto-sync' => form => { auto_sync_releases => 1, csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->auto_sync_releases, 'the co-maintainer successfully enabled auto-sync' );

    $t->get_ok('/logout');
};

subtest 'the manage page shows the auto-sync checkbox and sync-now button' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub { return []; };

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )
      ->status_is(200)
      ->element_exists('input[name="auto_sync_releases"]')
      ->element_exists('form[action="/plugins/' . $plugin->slug . '/sync-releases"]');

    $t->get_ok('/logout');
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_manage.t
```

Expected: fails — no route matches `POST /plugins/:slug/sync-releases` (404), and the manage page has no such elements yet.

- [ ] **Step 3: Add the two routes to `lib/KohaPluginStore.pm`**

Find:
```perl
    $r->post('/plugins/:slug/edit')->to('plugins#update_plugin');
```
Add immediately after:
```perl
    $r->post('/plugins/:slug/sync-releases')->requires( user_authenticated => 1 )->to('plugins#sync_releases_now');
    $r->post('/plugins/:slug/auto-sync')->requires( user_authenticated => 1 )->to('plugins#toggle_auto_sync');
```

- [ ] **Step 4: Add the two controller actions to `lib/KohaPluginStore/Controller/Plugins.pm`**

Add near `update_plugin`:

```perl
sub sync_releases_now ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer} && $plugin->is_maintained_by( $c->session->{developer}->{id} );

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    $c->minion->enqueue( sync_plugin_release => [ $plugin->id ] );

    return $c->redirect_to( '/plugins/' . $plugin->slug . '/manage' );
}

sub toggle_auto_sync ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer} && $plugin->is_maintained_by( $c->session->{developer}->{id} );

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    $plugin->update( { auto_sync_releases => $c->param('auto_sync_releases') ? 1 : 0 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug . '/manage' );
}
```

Note: `Controller::Plugins.pm` uses `-signatures` (`sub name ($c) {...}`) throughout — confirm this by checking its `use Mojo::Base` line before adding these, and match whatever calling convention the file already uses if it differs.

- [ ] **Step 5: Add the checkbox and button to `templates/plugins/manage.html.ep`**

Find:
```
<h2>Manage releases &mdash; <%= $plugin->name %></h2>
```

Add immediately after it:
```
<%= form_for '/plugins/'.$plugin->slug.'/auto-sync' => (method => 'POST') => begin %>
  %= csrf_field
  <div class="form-check mb-2">
    <input class="form-check-input" type="checkbox" name="auto_sync_releases" value="1"
           id="auto-sync-checkbox" onchange="this.form.submit()"
           <%= $plugin->auto_sync_releases ? 'checked' : '' %>>
    <label class="form-check-label" for="auto-sync-checkbox">
      Automatically submit new GitHub releases (checked nightly)
    </label>
  </div>
<% end %>

<%= form_for '/plugins/'.$plugin->slug.'/sync-releases' => (method => 'POST') => begin %>
  %= csrf_field
  <button type="submit" class="btn btn-outline-secondary btn-sm mb-3">Check for new releases now</button>
<% end %>
```

- [ ] **Step 6: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_manage.t
```

Expected: `All tests successful.`

- [ ] **Step 7: Run the full suite**

```bash
docker compose stop worker
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
docker compose start worker
```

Expected: `All tests successful.`

- [ ] **Step 8: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Plugins.pm templates/plugins/manage.html.ep t/plugins_manage.t
git commit -m "Add manual release-sync trigger and auto-sync opt-in toggle to the manage page"
```

---

### Task 6: Deployment — systemd timer and documentation

**Files:**
- Create: `koha_plugin_store-sync-plugin-releases.service.example`
- Create: `koha_plugin_store-sync-plugin-releases.timer.example`
- Modify: `DEPLOYMENT.md`

**Interfaces:** None — deployment/documentation only, no application code.

- [ ] **Step 1: Create `koha_plugin_store-sync-plugin-releases.service.example`**

```
# koha-plugin-store-sync-plugin-releases.service
[Unit]
Description=Koha Plugin Store auto-sync release check
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
ExecStart=/usr/bin/perl script/koha_plugin_store sync_plugin_releases
SyslogIdentifier=koha-plugin-store-sync-plugin-releases
```

- [ ] **Step 2: Create `koha_plugin_store-sync-plugin-releases.timer.example`**

```
# koha-plugin-store-sync-plugin-releases.timer
[Unit]
Description=Run koha-plugin-store-sync-plugin-releases.service daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Document both in `DEPLOYMENT.md`**

Find the existing "### Maintainer reconciliation" section (search for
`koha_plugin_store-reconcile-maintainers.service.example` in `DEPLOYMENT.md`) and add a new
section immediately after it:

```markdown
### Auto-sync release checks

`koha_plugin_store-sync-plugin-releases.service.example` and
`koha_plugin_store-sync-plugin-releases.timer.example` run
`script/koha_plugin_store sync_plugin_releases` once a day — it enqueues a release-check job
for every plugin whose maintainer has opted into auto-sync from that plugin's manage page. Each
plugin's own job runs independently, so one plugin's GitHub API failure can't affect any other.
Copy both to `/etc/systemd/system/`, adjust the same `User`/`Group`/`PERL5LIB`/`WorkingDirectory`
values as the other units, then:

```bash
sudo cp koha_plugin_store-sync-plugin-releases.service.example /etc/systemd/system/koha-plugin-store-sync-plugin-releases.service
sudo cp koha_plugin_store-sync-plugin-releases.timer.example /etc/systemd/system/koha-plugin-store-sync-plugin-releases.timer
sudo systemctl daemon-reload
sudo systemctl enable --now koha-plugin-store-sync-plugin-releases.timer
```

This is a `oneshot` service triggered by its timer, not a long-running daemon like `worker` --
there's nothing to `enable --now` on the `.service` itself. A running `worker` service is still
required for the jobs this enqueues (`sync_plugin_release`, and any `process_plugin_version` jobs
it in turn enqueues) to actually be picked up and run.
```

- [ ] **Step 4: Commit**

```bash
git add koha_plugin_store-sync-plugin-releases.service.example koha_plugin_store-sync-plugin-releases.timer.example DEPLOYMENT.md
git commit -m "Document the sync_plugin_releases systemd timer for deployment"
```

---

## Self-review notes (for whoever executes this plan)

- Task 2 is a behavior-preserving relocation of an existing helper plus one straightforward
  substitution in `bulk_import` (replacing an inline `grep` with the new `GitHub::new_releases`,
  which computes the identical result) — its own test additions are new, but its real risk is
  regressing the *other three* call sites it touches without adding new tests for them. That's
  why Task 2's Step 6 explicitly runs the full suite rather than just the new test file: the
  existing coverage in `t/plugins_manage.t`, `t/plugins_new_plugin.t`, and `t/plugins_bulk_import.t`
  is what actually protects those call sites, not anything Task 2 adds.
- `search()`'s default 10-row limit (see Global Constraints) is a pre-existing latent gap in
  `manage()`'s own `@versions` query and `bulk_import()`'s existing-tags lookup — a plugin with
  more than 10 versions could already, today, have a manual submission or bulk-import wrongly
  treat an old release as new. This plan does not fix that (out of scope — it predates this
  feature and affects manual flows this plan doesn't touch), but it does make sure the new code
  this plan adds (`existing_tags`, `auto_sync_enabled`) doesn't inherit it.
- Task 3's fourth subtest (concurrent-create-failure isolation) monkey-patches
  `PluginVersion::existing_tags` directly rather than crafting real pre-existing data that would
  make `new_releases` disagree with `existing_tags`'s real return value — this is intentional:
  it's the simplest way to deterministically force the exact "eligibility said yes, create()
  still failed" race this subtest needs, without relying on real concurrency.
