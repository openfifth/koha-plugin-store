# Private Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a maintainer mark a plugin private so it's excluded from the homepage catalogue, the public discovery API, and public author pages, while its own page, `.kpz` download, and signature verification stay reachable by direct link — no new authentication anywhere.

**Architecture:** One new boolean column (`plugins.is_private`), enforced in exactly two existing query builders that already back every public listing surface. A checkbox at submission time sets it; a manage-page toggle (mirroring the existing `auto_sync_releases` toggle) flips it afterward. The certification/signing pipeline is completely untouched.

**Tech Stack:** Mojolicious, Mojo::Pg (existing stack — no new dependencies).

**Spec:** `docs/superpowers/specs/2026-09-24-private-plugins-design.md`

## Global Constraints

- Any maintainer (owner or co-maintainer, via `Model::Plugin::is_maintained_by`) can toggle `is_private` from the manage page — no owner-only restriction (unlike `update_plugin`'s `repo_url` field).
- Every new controller action follows this codebase's established order: 404 (not found) → 401 (not a maintainer) → 403 (CSRF) → do the work — see `toggle_auto_sync`/`sync_releases_now` in `lib/KohaPluginStore/Controller/Plugins.pm` for the exact pattern to mirror.
- The bulk import flow (`/new-plugin/bulk`) does NOT get a private checkbox — out of scope per the spec. A bulk-imported plugin defaults to public and can be made private afterward via the manage-page toggle.
- The certification pipeline, its 11 checks, and tier computation are completely unmodified by this plan.
- `Model::Base::search()`'s `default_query_params` caps results at `limit => 10` unless overridden — not directly relevant to this plan's own new code (both places this plan touches already use raw `$self->pg->db->query(...)` calls, not `search()`), but keep in mind if any test fixture in this plan ever needs more than 10 rows back from an existing `search()`-based helper.

---

### Task 1: `is_private` column

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (append migration `12`)
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (`_columns`)
- Test: `t/model_plugin.t`

**Interfaces:**
- Produces: `plugins.is_private` (boolean, default `false`), readable/writable via the existing `Model::Plugin` `AUTOLOAD` accessor (`$plugin->is_private`) and `$plugin->update({ is_private => 1 })`, exactly like every other column.

- [ ] **Step 1: Write the failing test**

Add to `t/model_plugin.t` (before `done_testing()` — check the file's exact current ending first):

```perl
subtest 'is_private defaults to false and can be toggled via update' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    ok( !$plugin->is_private, 'defaults to false' );

    $plugin->update( { is_private => 1 } );
    ok( $plugin->is_private, 'update flips it to true' );

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->is_private, 'persisted to the database, not just the in-memory object' );
};
```

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t
```

Expected: fails — `is_private is not a column on plugins` (the `AUTOLOAD` croak from `Model::Base`).

- [ ] **Step 3: Add migration 12**

Append to `lib/KohaPluginStore/Command/migrate.pm`'s `__DATA__` section, after the existing `-- 11 down` block (do not renumber or edit anything above it — confirm `-- 11 down` is genuinely the last block first, in case anything has landed since this plan was written):

```
-- 12 up
ALTER TABLE plugins ADD COLUMN is_private BOOLEAN NOT NULL DEFAULT false;

-- 12 down
ALTER TABLE plugins DROP COLUMN is_private;
```

- [ ] **Step 4: Apply the migration against the running dev stack**

```bash
docker compose exec app script/koha_plugin_store migrate
```

Expected output ends with `Migrated to version 12`.

- [ ] **Step 5: Add the column to `Model::Plugin`'s `_columns`**

In `lib/KohaPluginStore/Model/Plugin.pm`, change:

```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url changelog_html auto_sync_releases)];
}
```

to:

```perl
sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url changelog_html auto_sync_releases is_private)];
}
```

(If the current file doesn't have `auto_sync_releases` in this list yet, add `is_private` to whatever the actual current list is — just append it at the end.)

- [ ] **Step 6: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t
```

Expected: `All tests successful.`

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/Plugin.pm t/model_plugin.t
git commit -m "Add plugins.is_private column"
```

---

### Task 2: Enforce visibility in every public listing query

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (`_compatible_where_and_binds`, `search_by_author_slug`)
- Test: `t/model_plugin.t`, `t/api_plugins.t`, `t/site_author.t`

**Interfaces:**
- Consumes: `plugins.is_private` (Task 1).
- Produces: nothing new — this task changes the behavior of two existing, already-in-use functions (`search_compatible`/`count_compatible`, via their shared `_compatible_where_and_binds` helper, and `search_by_author_slug`), which back `Controller::Plugins::index` (`GET /`), `Controller::Plugins::list_all` (`GET /api/plugins`), and `Controller::Site::author` (`GET /authors/:slug`) respectively.

- [ ] **Step 1: Write the failing tests**

Add to `t/model_plugin.t`, near the existing `search_compatible` subtests (search for `'search_compatible filters by koha_version, q, and paginates'` to find them):

```perl
subtest 'search_compatible and count_compatible exclude private plugins' => sub {
    reset_db();
    my $public = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'PublicWidget', description => 'A public widget' }
    );
    my $private = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'PrivateWidget', description => 'A private widget', is_private => 1 }
    );
    for my $plugin ( $public, $private ) {
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            {
                plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1',
                status => 'published', koha_min_version => '19.05',
            }
        );
    }

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    my $results = $model->search_compatible( { koha_version => '26.00.00.000', limit => 10, offset => 0 } );
    is( scalar @$results, 1, 'only the public plugin is returned' );
    is( $results->[0]->name, 'PublicWidget' );

    is( $model->count_compatible( { koha_version => '26.00.00.000' } ), 1, 'count_compatible agrees' );
};

subtest 'search_by_author_slug excludes private plugins' => sub {
    reset_db();
    my $public = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'public-widget', { name => 'PublicWidget', author => 'Jane Doe', repo_url => 'https://github.com/a/public-widget' }
    );
    my $private = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'private-widget', { name => 'PrivateWidget', author => 'Jane Doe', is_private => 1, repo_url => 'https://github.com/a/private-widget' }
    );
    for my $plugin ( $public, $private ) {
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            { plugin_id => $plugin->id, tag_name => 'v1', status => 'published' }
        );
    }

    my $plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->search_by_author_slug('jane-doe');
    is( scalar @$plugins, 1, 'only the public plugin is returned for this author' );
    is( $plugins->[0]->name, 'PublicWidget' );
};
```

Add to `t/api_plugins.t` (after its existing setup, as a new `subtest`; this file already builds `my $t = test_app();` once after its fixture setup and reuses it across every `subtest` — add this as another `subtest` block using that same `$t`, don't build a second one). Note the real route is `/api/v1/plugins` (not `/api/plugins`), the response body is a bare JSON array (index from `/0/...`), and the total count is sent via the `X-Total-Count` response header, not in the JSON body — confirmed by reading `Controller::Plugins::list_all`'s actual `$c->render(openapi => \@plugin_hashes, status => 200)` call and this file's own existing assertions:

```perl
subtest 'a private plugin never appears in /api/v1/plugins, even when it matches a search term' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'seeder' }
    );
    my $private = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'TelfordERP', description => 'Bespoke integration', developer_id => $developer->id, is_private => 1 }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $private->id, version => '1.0.0', koha_min_version => '19.05',
            status => 'published', content_digest => 'private123',
        }
    );

    $t->get_ok('/api/v1/plugins?koha_version=20.00&q=Telford')
      ->status_is(200)
      ->header_is( 'X-Total-Count' => 0 );
    is_deeply( $t->tx->res->json, [], 'the response body is an empty array, not just an empty count' );

    $t->get_ok( '/plugins/' . $private->slug )
      ->status_is(200)
      ->content_like(qr/TelfordERP/);
};
```

Add to `t/site_author.t` (before `done_testing()`):

```perl
subtest 'a private plugin is excluded from its author\'s public page' => sub {
    reset_db();
    my $public = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', author => 'Octavia Cat', repo_url => 'https://github.com/a/widget' }
    );
    my $private = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'secret-widget', { name => 'SecretWidget', author => 'Octavia Cat', is_private => 1, repo_url => 'https://github.com/a/secret-widget' }
    );
    for my $plugin ( $public, $private ) {
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            { plugin_id => $plugin->id, tag_name => 'v1', status => 'published' }
        );
    }

    $t->get_ok('/authors/octavia-cat')
      ->status_is(200)
      ->content_like(qr/Widget/)
      ->content_unlike(qr/SecretWidget/);
};
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t t/api_plugins.t t/site_author.t
```

Expected: the new subtests fail (private plugins show up where they shouldn't) — everything else in these three files still passes.

- [ ] **Step 3: Add the visibility filter to `_compatible_where_and_binds`**

In `lib/KohaPluginStore/Model/Plugin.pm`, change:

```perl
sub _compatible_where_and_binds {
    my ( $self, $args ) = @_;

    my @clauses = ("v.status = 'published'");
    my @binds;
```

to:

```perl
sub _compatible_where_and_binds {
    my ( $self, $args ) = @_;

    my @clauses = ( "v.status = 'published'", 'p.is_private = false' );
    my @binds;
```

- [ ] **Step 4: Add the visibility filter to `search_by_author_slug`**

In the same file, change:

```perl
sub search_by_author_slug {
    my ( $self, $author_slug ) = @_;

    my $rows = $self->pg->db->query(
        q{
            SELECT DISTINCT p.*
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE v.status = 'published' AND p.author IS NOT NULL AND p.author != ''
            ORDER BY p.name
        }
    )->hashes;
```

to:

```perl
sub search_by_author_slug {
    my ( $self, $author_slug ) = @_;

    my $rows = $self->pg->db->query(
        q{
            SELECT DISTINCT p.*
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE v.status = 'published' AND p.is_private = false AND p.author IS NOT NULL AND p.author != ''
            ORDER BY p.name
        }
    )->hashes;
```

- [ ] **Step 5: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/model_plugin.t t/api_plugins.t t/site_author.t
```

Expected: `All tests successful.` for all three files.

- [ ] **Step 6: Run the full suite**

This change touches two shared, widely-used query functions — confirm nothing else that reads `plugins`/`plugin_versions` compatibility regressed:

```bash
docker compose stop worker
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
docker compose start worker
```

Expected: `All tests successful.`

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm t/model_plugin.t t/api_plugins.t t/site_author.t
git commit -m "Exclude private plugins from every public listing/search/author-page query"
```

---

### Task 3: Private checkbox at submission time

**Files:**
- Modify: `templates/new-plugin-step2.html.ep`
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`new_plugin_confirm`)
- Test: `t/plugins_new_plugin.t`

**Interfaces:**
- Consumes: `plugins.is_private` (Task 1).
- Produces: nothing new for later tasks — this is a leaf change to the single-plugin submission flow only.

- [ ] **Step 1: Write the failing test**

Read `t/plugins_new_plugin.t`'s existing setup first (it already logs in as the mock developer and mocks `KohaPluginStore::GitHub::fetch_all_repos`/`fetch_release_by_tag` — follow its exact existing fixture pattern). Add a new subtest:

```perl
subtest 'checking "keep private" at submission creates the plugin as private' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { html_url => 'https://github.com/dev/widget', full_name => 'dev/widget' } ];
    };
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author   => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
            assets   => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };

    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/dev/widget',
            tag_name    => 'v1.0.0',
            is_private  => 1,
            csrf_token  => csrf_token($t),
        }
    )->status_is(302);

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/dev/widget' } );
    ok( $plugin, 'the plugin was created' );
    ok( $plugin->is_private, 'it was created as private' );

    $t->get_ok('/logout');
};

subtest 'leaving "keep private" unchecked at submission creates the plugin as public' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { html_url => 'https://github.com/dev/widget', full_name => 'dev/widget' } ];
    };
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author   => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
            assets   => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };

    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/dev/widget',
            tag_name    => 'v1.0.0',
            csrf_token  => csrf_token($t),
        }
    )->status_is(302);

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/dev/widget' } );
    ok( $plugin, 'the plugin was created' );
    ok( !$plugin->is_private, 'it defaults to public when the checkbox is not sent (true unchecked-checkbox behavior)' );

    $t->get_ok('/logout');
};
```

(`t/plugins_new_plugin.t` already has `use CsrfHelper qw(csrf_token);` — no new import needed.)

- [ ] **Step 2: Run the test to confirm it fails**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_new_plugin.t
```

Expected: fails — the created plugin's `is_private` is always false regardless of the submitted param, since nothing reads it yet.

- [ ] **Step 3: Add the checkbox to `templates/new-plugin-step2.html.ep`**

Find:
```
    <button type="submit" class="btn btn-primary">Continue</button>
  % end
% }
```

Change to:
```
    <div class="form-check mb-3">
      <input class="form-check-input" type="checkbox" name="is_private" value="1" id="is-private-checkbox">
      <label class="form-check-label" for="is-private-checkbox">
        Keep this plugin private -- don't list it publicly
      </label>
    </div>
    <button type="submit" class="btn btn-primary">Continue</button>
  % end
% }
```

- [ ] **Step 4: Read `is_private` in `new_plugin_confirm`**

In `lib/KohaPluginStore/Controller/Plugins.pm`, find the plugin-creation branch (the `else` branch of the `if ($plugin) { ... } else { ... }` block inside `new_plugin_confirm`):

```perl
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
```

Change to:

```perl
    else {
        my ($repo_name) = $plugin_repo =~ m{([^/]+)/?$};
        $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->create_with_unique_slug(
            $repo_name,
            {
                repo_url     => $plugin_repo,
                developer_id => $developer_id,
                is_private   => $c->param('is_private') ? 1 : 0,
            }
        );
        KohaPluginStore::Model::PluginMaintainer->new( pg => $c->pg )->grant(
            { plugin_id => $plugin->id, developer_id => $developer_id, role => 'owner', granted_via => 'creator' }
        );
    }
```

Note: this only applies to the branch that creates a brand-new plugin. The other branch (someone submitting a repo that's already been submitted by someone else, becoming a maintainer of an existing plugin) correctly leaves that plugin's existing `is_private` value untouched — a later submitter's checkbox choice must never silently change an already-established plugin's visibility.

- [ ] **Step 5: Run the test to confirm it passes**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_new_plugin.t
```

Expected: `All tests successful.`

- [ ] **Step 6: Run the full suite**

```bash
docker compose stop worker
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
docker compose start worker
```

Expected: `All tests successful.`

- [ ] **Step 7: Commit**

```bash
git add templates/new-plugin-step2.html.ep lib/KohaPluginStore/Controller/Plugins.pm t/plugins_new_plugin.t
git commit -m "Add a 'keep private' checkbox to the single-plugin submission flow"
```

---

### Task 4: Manage-page toggle and my-plugins badge

**Files:**
- Modify: `lib/KohaPluginStore.pm` (1 new route)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (1 new action: `toggle_private`)
- Modify: `templates/plugins/manage.html.ep` (checkbox)
- Modify: `templates/partial/table/plugins.html.ep` (private badge)
- Test: `t/plugins_manage.t`, `t/my_plugins.t`

**Interfaces:**
- Consumes: `Model::Plugin::is_maintained_by` (existing), `plugins.is_private` (Task 1).
- Produces: `POST /plugins/:slug/private`, maintainer-gated the same way `toggle_auto_sync` is.

- [ ] **Step 1: Write the failing tests**

Add to `t/plugins_manage.t` (it already has `use CsrfHelper qw(csrf_token);` from earlier work — confirm this first):

```perl
subtest 'a maintainer can toggle a plugin private' => sub {
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

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { is_private => 1, csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->is_private, 'the plugin is now private' );

    $t->get_ok('/logout');
};

subtest 'a maintainer can toggle a plugin back to public' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id, is_private => 1 }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->is_private, 'the plugin is now public -- no is_private param sent matches true unchecked-checkbox behavior' );

    $t->get_ok('/logout');
};

subtest 'a non-maintainer cannot toggle a plugin private' => sub {
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

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { is_private => 1, csrf_token => csrf_token($t) } )
      ->status_is(401);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( !$reloaded->is_private, 'unchanged' );

    $t->get_ok('/logout');
};

subtest 'a co-maintainer (not the owner) can toggle a plugin private' => sub {
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

    $t->post_ok( '/plugins/' . $plugin->slug . '/private' => form => { is_private => 1, csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    ok( $reloaded->is_private, 'the co-maintainer successfully made it private' );

    $t->get_ok('/logout');
};
```

Add to `t/my_plugins.t` (before `done_testing()`):

```perl
subtest 'a private plugin is badged as private in the my-plugins list' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'secret-widget', { name => 'SecretWidget', repo_url => 'https://github.com/dev/secret-widget', developer_id => $owner->id, is_private => 1 }
    );

    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/SecretWidget/)
      ->content_like(qr/Private/);

    $t->get_ok('/logout');
};
```

(Check `t/my_plugins.t`'s exact current login/fixture pattern first — it may already be logged in from earlier in the file; follow whatever's already established there rather than assuming this exact login block is needed.)

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_manage.t t/my_plugins.t
```

Expected: fails — no route matches `POST /plugins/:slug/private` (404s), and the my-plugins table has no "Private" text.

- [ ] **Step 3: Add the route to `lib/KohaPluginStore.pm`**

Find:
```perl
    $r->post('/plugins/:slug/auto-sync')->requires( user_authenticated => 1 )->to('plugins#toggle_auto_sync');
```
Add immediately after:
```perl
    $r->post('/plugins/:slug/private')->requires( user_authenticated => 1 )->to('plugins#toggle_private');
```

- [ ] **Step 4: Add the `toggle_private` action to `lib/KohaPluginStore/Controller/Plugins.pm`**

Add near `toggle_auto_sync`:

```perl
sub toggle_private ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer} && $plugin->is_maintained_by( $c->session->{developer}->{id} );

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    $plugin->update( { is_private => $c->param('is_private') ? 1 : 0 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug . '/manage' );
}
```

- [ ] **Step 5: Add the checkbox to `templates/plugins/manage.html.ep`**

Find:
```
<h2>Manage releases &mdash; <%= $plugin->name %></h2>

<%= form_for '/plugins/'.$plugin->slug.'/auto-sync' => (method => 'POST') => begin %>
```

Add immediately before that `form_for` line:
```
<%= form_for '/plugins/'.$plugin->slug.'/private' => (method => 'POST') => begin %>
  %= csrf_field
  <div class="form-check mb-2">
    <input class="form-check-input" type="checkbox" name="is_private" value="1"
           id="is-private-checkbox" onchange="this.form.submit()"
           <%= $plugin->is_private ? 'checked' : '' %>>
    <label class="form-check-label" for="is-private-checkbox">
      Keep this plugin private -- don't list it publicly
    </label>
  </div>
<% end %>

```

- [ ] **Step 6: Add the private badge to `templates/partial/table/plugins.html.ep`**

Find:
```
      <td>
        %= link_to $plugin->name => '/plugins/'.$plugin->slug
      </td>
```

Change to:
```
      <td>
        %= link_to $plugin->name => '/plugins/'.$plugin->slug
        % if ($plugin->is_private) {
        <span class="badge bg-secondary">Private</span>
        % }
      </td>
```

- [ ] **Step 7: Run the tests to confirm they pass**

```bash
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/plugins_manage.t t/my_plugins.t
```

Expected: `All tests successful.`

- [ ] **Step 8: Run the full suite**

```bash
docker compose stop worker
docker compose exec -e KOHA_PLUGIN_STORE_TEST_DSN='postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store' app prove -l t/
docker compose start worker
```

Expected: `All tests successful.`

- [ ] **Step 9: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Plugins.pm templates/plugins/manage.html.ep templates/partial/table/plugins.html.ep t/plugins_manage.t t/my_plugins.t
git commit -m "Add a manage-page toggle and my-plugins badge for private plugins"
```

---

## Self-review notes (for whoever executes this plan)

- Task 2's `t/api_plugins.t` addition initially assumed a `/api/plugins` route returning `{total, plugins}` JSON -- caught during this plan's own self-review by reading `Controller::Plugins::list_all`'s actual code, which showed the real route is `/api/v1/plugins`, the body is a bare array, and the count travels in the `X-Total-Count` header. Corrected before this plan was finalized; the snippet above is the corrected, source-verified version.
- Task 3 and Task 4 both touch `is_private`'s "true unchecked-checkbox" semantics (`$c->param('is_private') ? 1 : 0`) independently, matching the exact pattern already proven correct for `auto_sync_releases` in an earlier, unrelated feature (verified under a real `Test::Mojo` POST in that feature's own fix round) — no new risk here, same well-tested idiom reused twice.
- No task changes anything about the certification/signing pipeline, `process_plugin_version`, or `Signing.pm` — confirmed by re-reading the spec's Non-goals section, which explicitly rules this out.
