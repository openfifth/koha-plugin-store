# MetaCPAN-Style Layout Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the site-wide left sidebar nav, widen the homepage, and replace the plugin detail
page's tab bar with a MetaCPAN-style `Author / Plugin [Version ▾]` header backed by per-version
pages, a relocated info-block sidebar, a linear Technical report section, an owner-only Manage
releases view, changelog support, and a public author-grouping page.

**Architecture:** Server-rendered Mojolicious `.html.ep` templates (no build step, no framework
change). One new backend module (`KohaPluginStore::Changelog`), one schema column
(`plugins.changelog_html`), two new routes on the existing `Controller::Plugins`
(`show_version`, `manage`), one new route on `Controller::Site` (`author`), and a reshaped
`_plugin_page_stash` that now scopes version-specific data (checks, changelog excerpt,
still-processing flag) to a single "current version" instead of the whole plugin's history.

**Tech Stack:** Perl (Modern::Perl, Mojolicious `-signatures`), Mojo::Pg, Test::More/Test::Mojo,
Bootstrap 5 + vanilla JS (unchanged — no new frontend tooling).

**Spec:** [`docs/superpowers/specs/2026-09-23-plugin-page-layout-redesign-design.md`](../specs/2026-09-23-plugin-page-layout-redesign-design.md)

## Global Constraints

- No Vue, no frontend build step — plain Bootstrap 5 + vanilla JS only, matching the rest of this
  store's templates.
- Every migration is a `-- N up` / `-- N down` pair appended to
  `lib/KohaPluginStore/Command/migrate.pm`'s `__DATA__` section (Mojo::Pg's built-in format) —
  never edit an existing numbered block.
- `t/lib/TestDB.pm`'s `reset_db()`/`test_app()` helpers are mandatory for every new test file (see
  any existing `t/*.t` for the pattern) — never construct `Test::Mojo` or `Mojo::Pg` directly.
- A GitHub API call added to `KohaPluginStore::GitHub` must go through the module's existing
  `_get`/`_get_readme` test seams (never call `Mojo::UserAgent` directly from a new function) so
  it can be stubbed in tests the same way every existing fetch function already is.
- **Deviation from the spec, decided during planning:** the spec describes `GET /plugins/:slug`
  redirecting (302) to the latest published version's `/v/:tag_name` URL. This plan instead has it
  render that version's content directly, in place, with no redirect — every existing test in
  `t/plugins_show.t` calls `$t->get_ok('/plugins/:slug')->status_is(200)`, and `Test::Mojo` does
  not auto-follow redirects; a 302 would break the entire existing suite for no behavioral gain
  the spec actually needs (the bare URL already isn't meant to be the "canonical" link — `/v/:tag`
  is). Every version still gets its own stable, linkable, directly-fetchable URL via
  `show_version`; the bare URL is simply an alias that happens to render the latest one without
  changing the address bar.

---

## File Structure

New files:
- `lib/KohaPluginStore/Changelog.pm` — pure function, extracts one version's section from a
  stored changelog HTML blob.
- `templates/site/author.html.ep` — public author-grouping page.
- `templates/partial/footer.html.ep` — site-wide footer (dev links).
- `templates/plugins/manage.html.ep` — owner-only release-management view.
- `t/changelog.t`, `t/plugins_manage.t` — new test files.

Modified files (existing responsibilities, no restructuring beyond what each task needs):
- `lib/KohaPluginStore/Command/migrate.pm` — new migration.
- `lib/KohaPluginStore/GitHub.pm` — new `fetch_changelog_html`.
- `lib/KohaPluginStore/Task/ProcessPluginVersion.pm` — fetch+store changelog alongside README.
- `lib/KohaPluginStore/Model/Plugin.pm` — `slugify`, `search_by_author_slug`, `changelog_html`
  column.
- `lib/KohaPluginStore/Controller/Site.pm` — new `author` action.
- `lib/KohaPluginStore/Controller/Plugins.pm` — `_plugin_page_stash` rescoped to one version;
  `show`/`show_version`/`manage` actions.
- `lib/KohaPluginStore.pm` — new routes.
- `templates/layouts/default.html.ep` — conditional sidebar column, navbar login link, footer
  include.
- `templates/plugins/show.html.ep` — full rewrite (header, sidebar, linear technical report).
- `templates/plugins/index.html.ep`, `templates/site/{index,profile,verification_key}.html.ep`,
  `templates/{login,my-plugins,new-plugin,new-plugin-step2,unauthorized}.html.ep` — sidebar block
  removed.
- `t/site.t`, `t/plugins_index.t`, `t/plugins_show.t`, `t/github.t`,
  `t/task_process_plugin_version.t`, `t/model_plugin.t` — updated/new assertions.

Deleted files (Task 7, once nothing references them):
- `templates/partial/side_menu.html.ep`, `templates/partial/nav_items.html.ep`,
  `templates/partial/auth_menu.html.ep`.

---

### Task 1: Shared `slugify()` helper

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm:42-54`
- Test: `t/model_plugin.t`

**Interfaces:**
- Produces: `KohaPluginStore::Model::Plugin::slugify($string)` — a plain function (not a method),
  returns a lowercase-alphanumeric-hyphenated string, `''` for `undef`/empty input. Used by Task 4
  (author slugs) and unchanged by `create_with_unique_slug` (plugin slugs).

- [ ] **Step 1: Write the failing test**

Add to `t/model_plugin.t` (after the existing `subtest 'create_with_unique_slug normalizes the
source string'` block):

```perl
subtest 'slugify normalizes a string the same way create_with_unique_slug does' => sub {
    is( KohaPluginStore::Model::Plugin::slugify('Koha_Plugin!! Coverflow'), 'koha-plugin-coverflow' );
    is( KohaPluginStore::Model::Plugin::slugify('  Jane Doe  '), 'jane-doe' );
    is( KohaPluginStore::Model::Plugin::slugify(undef), '', 'undef input returns empty string, not a die' );
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/model_plugin.t`
Expected: FAIL — `Undefined subroutine &KohaPluginStore::Model::Plugin::slugify called`

- [ ] **Step 3: Extract the helper**

In `lib/KohaPluginStore/Model/Plugin.pm`, replace:

```perl
sub create_with_unique_slug {
    my ( $self, $slug_source, $attrs ) = @_;

    my $base = lc($slug_source);
    $base =~ s/[^a-z0-9]+/-/g;
    $base =~ s/^-+|-+$//g;

    for my $attempt ( 1 .. 10 ) {
```

with:

```perl
sub slugify {
    my ($string) = @_;

    my $slug = lc( $string // '' );
    $slug =~ s/[^a-z0-9]+/-/g;
    $slug =~ s/^-+|-+$//g;
    return $slug;
}

sub create_with_unique_slug {
    my ( $self, $slug_source, $attrs ) = @_;

    my $base = slugify($slug_source);

    for my $attempt ( 1 .. 10 ) {
```

(the rest of `create_with_unique_slug` — the retry loop and `die` — is unchanged)

- [ ] **Step 4: Run test to verify it passes**

Run: `koha-prove t/model_plugin.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm t/model_plugin.t
git commit -m "Extract slugify() from create_with_unique_slug as a reusable helper"
```

---

### Task 2: Changelog fetch & storage

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (append migration 9)
- Modify: `lib/KohaPluginStore/Model/Plugin.pm:14` (`_columns`)
- Modify: `lib/KohaPluginStore/GitHub.pm` (new `fetch_changelog_html`)
- Modify: `lib/KohaPluginStore/Task/ProcessPluginVersion.pm:158-168`
- Test: `t/github.t`, `t/task_process_plugin_version.t`

**Interfaces:**
- Consumes: nothing new.
- Produces: `KohaPluginStore::GitHub::fetch_changelog_html($access_token, $owner_repo)` — returns
  the raw HTML body string on a 200 from `CHANGELOG.md` or (fallback) `CHANGES.md`, `undef`
  otherwise. `plugins.changelog_html` column, populated the same best-effort way `readme_html`
  already is. Task 3 and Task 7 read `$plugin->changelog_html`.

- [ ] **Step 1: Write the failing tests**

Add to `t/github.t`, right after the three existing `fetch_readme_html` subtests:

```perl
subtest 'fetch_changelog_html tries CHANGELOG.md first and returns its HTML body on success' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_paths;
    *KohaPluginStore::GitHub::_get_readme = sub {
        my ($url) = @_;
        push @seen_paths, $url;
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body('<h2>1.0.0</h2><p>Initial release.</p>');
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_changelog_html( 'token', 'https://github.com/dev/widget' ),
        '<h2>1.0.0</h2><p>Initial release.</p>',
        'raw pre-rendered HTML returned as-is'
    );
    is( $seen_paths[0], 'https://api.github.com/repos/dev/widget/contents/CHANGELOG.md', 'CHANGELOG.md tried first' );
    is( scalar @seen_paths, 1, 'stops after the first successful path' );
};

subtest 'fetch_changelog_html falls back to CHANGES.md when CHANGELOG.md is missing' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_paths;
    *KohaPluginStore::GitHub::_get_readme = sub {
        my ($url) = @_;
        push @seen_paths, $url;
        my $res = Mojo::Message::Response->new;
        $res->code( $url =~ /CHANGES\.md/ ? 200 : 404 );
        $res->body('<h2>1.0.0</h2>') if $url =~ /CHANGES\.md/;
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_changelog_html( 'token', 'https://github.com/dev/widget' ),
        '<h2>1.0.0</h2>'
    );
    is_deeply(
        \@seen_paths,
        [
            'https://api.github.com/repos/dev/widget/contents/CHANGELOG.md',
            'https://api.github.com/repos/dev/widget/contents/CHANGES.md',
        ],
        'both paths tried, in order'
    );
};

subtest 'fetch_changelog_html returns undef when neither file exists' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_readme = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_changelog_html( 'token', 'https://github.com/dev/widget' ), undef );
};
```

Add to `t/task_process_plugin_version.t`, right after the existing `'a failed README fetch does
not fail processing...'` subtest:

```perl
subtest 'successful processing fetches and stores the changelog HTML' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $developer->id }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_kpz($valid_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors       = sub { return []; };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_readme_html        = sub { return undef };
    *KohaPluginStore::GitHub::fetch_changelog_html     = sub { return '<h2>1.0.0</h2><p>Initial release.</p>'; };
    *KohaPluginStore::Check::PerlSyntax::_call_broker  = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->changelog_html, '<h2>1.0.0</h2><p>Initial release.</p>', 'changelog_html populated from the fetch' );
};

subtest 'a failed changelog fetch does not fail processing and leaves any existing changelog_html untouched' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $developer->id, changelog_html => '<p>Old changelog</p>' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_kpz($valid_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors       = sub { return []; };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_readme_html        = sub { return undef };
    *KohaPluginStore::GitHub::fetch_changelog_html     = sub { die "network error\n" };
    *KohaPluginStore::Check::PerlSyntax::_call_broker  = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded_version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded_version->status, 'published', 'processing still succeeds despite the changelog fetch dying' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->changelog_html, '<p>Old changelog</p>', 'prior changelog_html is left untouched, not wiped' );
};
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `koha-prove t/github.t t/task_process_plugin_version.t`
Expected: FAIL — `fetch_changelog_html` undefined; `changelog_html` not a column on `plugins`.

- [ ] **Step 3: Add the migration**

Append to `lib/KohaPluginStore/Command/migrate.pm`'s `__DATA__` section, after the existing `-- 8
down` block:

```sql

-- 9 up
ALTER TABLE plugins ADD COLUMN changelog_html TEXT;

-- 9 down
ALTER TABLE plugins DROP COLUMN changelog_html;
```

- [ ] **Step 4: Add the column to the model**

In `lib/KohaPluginStore/Model/Plugin.pm:14`, change:

```perl
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url)];
```

to:

```perl
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url changelog_html)];
```

- [ ] **Step 5: Implement `fetch_changelog_html`**

In `lib/KohaPluginStore/GitHub.pm`, add immediately after the `fetch_readme_html`/`_get_readme`
pair (after line 129/140):

```perl
# Tries CHANGELOG.md first (the more common convention), then CHANGES.md. Reuses
# _get_readme's pre-rendered-HTML Accept header via GitHub's Contents API, which
# (unlike the README-specific /readme endpoint) renders *any* markdown file at a
# given path to HTML when asked for the same media type.
sub fetch_changelog_html {
    my ( $access_token, $owner_repo ) = @_;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;

    for my $filename (qw(CHANGELOG.md CHANGES.md)) {
        my $tx = _get_readme( "$api_repo/contents/$filename", $access_token );
        return $tx->result->body if $tx->result->code == 200;
    }

    return;
}
```

- [ ] **Step 6: Wire it into version processing**

In `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`, change:

```perl
    my $readme_html = eval { KohaPluginStore::GitHub::fetch_readme_html( $token, $plugin->repo_url ) };

    $plugin->update(
        {
            name        => $metadata->{name},
            description => $metadata->{description},
            author      => $metadata->{author},
            class_name  => $plugin_class_name,
            ( defined $readme_html ? ( readme_html => $readme_html ) : () ),
        }
    );
```

to:

```perl
    my $readme_html    = eval { KohaPluginStore::GitHub::fetch_readme_html( $token, $plugin->repo_url ) };
    my $changelog_html = eval { KohaPluginStore::GitHub::fetch_changelog_html( $token, $plugin->repo_url ) };

    $plugin->update(
        {
            name        => $metadata->{name},
            description => $metadata->{description},
            author      => $metadata->{author},
            class_name  => $plugin_class_name,
            ( defined $readme_html    ? ( readme_html    => $readme_html )    : () ),
            ( defined $changelog_html ? ( changelog_html => $changelog_html ) : () ),
        }
    );
```

- [ ] **Step 7: Apply the migration to the dev/test database**

Run: `koha-prove --migrate` if your workflow has a wrapper, otherwise:
`script/koha_plugin_store migrate` (against your dev DB) — the test DB picks up new columns
automatically since `TestDB` truncates rather than recreating the schema; if the test DB was
created before this migration existed, run `script/koha_plugin_store migrate` against
`$ENV{KOHA_PLUGIN_STORE_TEST_DSN}` (or whatever `t/lib/TestDB.pm`'s default DSN points at) once.

- [ ] **Step 8: Run tests to verify they pass**

Run: `koha-prove t/github.t t/task_process_plugin_version.t`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/Plugin.pm \
        lib/KohaPluginStore/GitHub.pm lib/KohaPluginStore/Task/ProcessPluginVersion.pm \
        t/github.t t/task_process_plugin_version.t
git commit -m "Fetch and store a plugin's CHANGELOG.md/CHANGES.md HTML on every version processing"
```

---

### Task 3: Changelog section extraction

**Files:**
- Create: `lib/KohaPluginStore/Changelog.pm`
- Test: `t/changelog.t`

**Interfaces:**
- Consumes: nothing (pure function over a string).
- Produces: `KohaPluginStore::Changelog::extract_section($changelog_html, $tag_name)` — returns
  the matched heading + body as a raw HTML string, or `undef` if no matching heading is found.
  Task 7's sidebar "What's new in this version" card calls this with `$plugin->changelog_html` and
  `$current_version->tag_name`.

- [ ] **Step 1: Write the failing test**

Create `t/changelog.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Changelog;

subtest 'extracts a "Keep a Changelog"-style [x.y.z] heading, stopping before the next heading' => sub {
    my $html = '<h2>[1.1.0] - 2026-02-01</h2><p>Added a widget.</p><h2>[1.0.0] - 2026-01-01</h2><p>Initial release.</p>';

    my $section = KohaPluginStore::Changelog::extract_section( $html, 'v1.1.0' );
    like( $section, qr/Added a widget\./, 'matched entry included' );
    unlike( $section, qr/Initial release\./, 'older entry not included' );
};

subtest 'matches a bare vX.Y.Z heading with no brackets' => sub {
    my $html = '<h2>v2.0.0</h2><p>Rewrote the thing.</p>';

    my $section = KohaPluginStore::Changelog::extract_section( $html, 'v2.0.0' );
    like( $section, qr/Rewrote the thing\./ );
};

subtest 'matches when the tag has no leading v but the heading does, and vice versa' => sub {
    my $html = '<h2>1.2.0</h2><p>No leading v anywhere.</p>';

    is( KohaPluginStore::Changelog::extract_section( $html, 'v1.2.0' ), '<h2>1.2.0</h2><p>No leading v anywhere.</p>' );
};

subtest 'returns undef, not a die, when no heading matches (non-standard changelog format)' => sub {
    my $html = '<p>Just a paragraph, no version headings at all.</p>';

    is( KohaPluginStore::Changelog::extract_section( $html, 'v1.0.0' ), undef );
};

subtest 'returns undef on missing inputs' => sub {
    is( KohaPluginStore::Changelog::extract_section( undef, 'v1.0.0' ), undef );
    is( KohaPluginStore::Changelog::extract_section( '<h2>1.0.0</h2>', undef ), undef );
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/changelog.t`
Expected: FAIL — `Can't locate KohaPluginStore/Changelog.pm`

- [ ] **Step 3: Implement the module**

Create `lib/KohaPluginStore/Changelog.pm`:

```perl
package KohaPluginStore::Changelog;

use Modern::Perl;

# Matches a "Keep a Changelog"-style version heading -- tolerant of an optional
# leading 'v' and optional surrounding brackets, e.g. "## [1.2.0] - 2026-01-01",
# "## v1.2.0", or "## 1.2.0" (rendered as <h1>-<h6> by GitHub's markdown-to-HTML
# conversion). A changelog that doesn't follow this convention simply won't
# match -- callers fall back to a plain link to the full changelog, same
# "regex over real-world text, expect rough edges" posture the rest of this
# store already takes with plugin metadata parsing.
sub extract_section {
    my ( $changelog_html, $tag_name ) = @_;

    return unless $changelog_html && $tag_name;

    ( my $version = $tag_name ) =~ s/^v//i;
    my $version_re = quotemeta($version);

    if ( $changelog_html =~ m{
            (<h[1-6][^>]*>\s*\[?v?$version_re\]?\b.*?</h[1-6]>)
            (.*?)
            (?=<h[1-6][^>]*>|\z)
        }isx
    ) {
        return $1 . $2;
    }

    return;
}

1;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `koha-prove t/changelog.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Changelog.pm t/changelog.t
git commit -m "Add KohaPluginStore::Changelog::extract_section for per-version changelog excerpts"
```

---

### Task 4: Public author page

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (add `search_by_author_slug`)
- Modify: `lib/KohaPluginStore/Controller/Site.pm` (add `author`)
- Modify: `lib/KohaPluginStore.pm` (add route)
- Create: `templates/site/author.html.ep`
- Test: `t/model_plugin.t`, new `t/site_author.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Model::Plugin::slugify` (Task 1).
- Produces: `Model::Plugin->search_by_author_slug($author_slug)` → arrayref of `Model::Plugin`
  objects (published only). Route `GET /authors/:author_slug` → `site#author`.

- [ ] **Step 1: Write the failing model test**

Add to `t/model_plugin.t`:

```perl
subtest 'search_by_author_slug groups published plugins by their author string' => sub {
    reset_db();
    my $p1 = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-a', { name => 'WidgetA', author => 'Octavia Cat', repo_url => 'https://github.com/a/a' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $p1->id, tag_name => 'v1', status => 'published' }
    );
    my $p2 = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-b', { name => 'WidgetB', author => 'octavia cat', repo_url => 'https://github.com/a/b' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $p2->id, tag_name => 'v1', status => 'published' }
    );
    my $unpublished = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-c', { name => 'WidgetC', author => 'Octavia Cat', repo_url => 'https://github.com/a/c' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $unpublished->id, tag_name => 'v1', status => 'submitted' }
    );
    my $other = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-d', { name => 'WidgetD', author => 'Someone Else', repo_url => 'https://github.com/a/d' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $other->id, tag_name => 'v1', status => 'published' }
    );

    my $plugins = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->search_by_author_slug('octavia-cat');
    is( scalar @$plugins, 2, 'both differently-cased matches included, unpublished one excluded' );
    is_deeply( [ sort map { $_->name } @$plugins ], [ 'WidgetA', 'WidgetB' ] );
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/model_plugin.t`
Expected: FAIL — `search_by_author_slug is not a column on plugins` (AUTOLOAD trying to treat it as
a column accessor) or "Can't locate object method"

- [ ] **Step 3: Implement `search_by_author_slug`**

In `lib/KohaPluginStore/Model/Plugin.pm`, add after `create_with_unique_slug`:

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

    my @plugins = map { $self->_new_from_row($_) } @$rows;
    return [ grep { slugify( $_->author ) eq $author_slug } @plugins ];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `koha-prove t/model_plugin.t`
Expected: PASS

- [ ] **Step 5: Write the failing controller/route test**

Create `t/site_author.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $t = test_app();

subtest 'author page lists only that author\'s published plugins' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', author => 'Octavia Cat', description => 'A fine widget', repo_url => 'https://github.com/a/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1', status => 'published', certification_tier => 'CERTIFIED' }
    );

    $t->get_ok('/authors/octavia-cat')
      ->status_is(200)
      ->content_like(qr/Octavia Cat/)
      ->content_like(qr/Widget/)
      ->content_like(qr/A fine widget/)
      ->element_exists('a[href="/plugins/widget"]');
};

subtest 'a slug with zero matching published plugins 404s' => sub {
    $t->get_ok('/authors/nobody-here')->status_is(404);
};

done_testing();
```

- [ ] **Step 6: Run test to verify it fails**

Run: `koha-prove t/site_author.t`
Expected: FAIL — 404/`Not Found` for the route (no matching `/authors/:author_slug` route yet)

- [ ] **Step 7: Add the route**

In `lib/KohaPluginStore.pm`, add after `$r->get('/verification-key')->to('site#verification_key');`:

```perl
    $r->get('/authors/:author_slug')->to('site#author');
```

- [ ] **Step 8: Implement the controller action**

In `lib/KohaPluginStore/Controller/Site.pm`, add `use KohaPluginStore::Model::Plugin;` to the top
imports, and add this action after `verification_key`:

```perl
sub author ($c) {
    my $author_slug = $c->param('author_slug');

    my $plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search_by_author_slug($author_slug);
    return $c->render( text => 'Author not found', status => 404 ) unless @$plugins;

    $c->stash( author_name => $plugins->[0]->author, plugins => $plugins );
    $c->render('site/author');
}
```

(this controller already uses `-signatures` via `Mojo::Base 'Mojolicious::Controller',
-signatures`, matching `profile`/`verification_key`'s `($c)` style)

- [ ] **Step 9: Create the template**

Create `templates/site/author.html.ep`:

```html
% my $author_name = stash 'author_name';
% my $plugins     = stash 'plugins';
% my %tier_badge = ( CERTIFIED => 'text-bg-success', STRUCTURAL => 'text-bg-warning', INCOMPLETE => 'text-bg-danger' );
% title $author_name;
% layout 'default';

<h2><%= $author_name %></h2>
<p class="text-muted"><%= scalar(@$plugins) %> plugin<%= @$plugins == 1 ? '' : 's' %></p>

<div class="row row-cols-1 row-cols-md-3 g-4">
  % for my $plugin (@$plugins) {
  % my $latest = $plugin->latest_published_version;
  <div class="col">
    <div class="card h-100">
      <div class="card-body">
        <h5 class="card-title">
          %= link_to $plugin->name => '/plugins/'.$plugin->slug
        </h5>
        % if ($latest && $latest->certification_tier) {
        <p><span class="badge <%= $tier_badge{$latest->certification_tier} || 'text-bg-secondary' %>"><%= $latest->certification_tier %></span></p>
        % }
        % if ($plugin->description) {
        <p class="card-text text-muted"><%= $plugin->description %></p>
        % }
      </div>
    </div>
  </div>
  % }
</div>
```

This template declares no `content_for 'sidebar'` block, so it renders full-width once Task 5's
conditional layout lands. Until Task 5 is merged, it will render inside the (still unconditional,
empty-left-column) two-column layout — harmless, and self-corrects the moment Task 5 lands.

- [ ] **Step 10: Run tests to verify they pass**

Run: `koha-prove t/model_plugin.t t/site_author.t`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm lib/KohaPluginStore/Controller/Site.pm \
        lib/KohaPluginStore.pm templates/site/author.html.ep \
        t/model_plugin.t t/site_author.t
git commit -m "Add a public /authors/:slug page grouping published plugins by metadata author string"
```

---

### Task 5: Global nav/layout rework

**Files:**
- Modify: `templates/layouts/default.html.ep`
- Create: `templates/partial/footer.html.ep`
- Modify: `templates/plugins/index.html.ep:4-6` (remove sidebar block)
- Modify: `templates/site/index.html.ep:4-6`, `templates/site/profile.html.ep:6-8`,
  `templates/site/verification_key.html.ep:4-6`, `templates/login.html.ep:4-6`,
  `templates/my-plugins.html.ep:4-6`, `templates/new-plugin.html.ep:4-6`,
  `templates/new-plugin-step2.html.ep:7-9`, `templates/unauthorized.html.ep:4-6` (remove sidebar
  block — identical 3-line removal in each)
- Modify: `t/site.t:41-45`

**Interfaces:**
- Produces: layout renders a single full-width column when a template declares no `sidebar`
  content block, and the existing two-column split when one is declared (still used by
  `templates/plugins/show.html.ep` — untouched until Task 7).

- [ ] **Step 1: Write the failing tests**

Replace the `subtest 'sidebar nav links to Browse Plugins and Plugin developers'` block in
`t/site.t:41-45` with:

```perl
subtest 'footer links to Plugin developers and Verification key; the old Browse Plugins link is gone' => sub {
    $t->get_ok('/')
      ->element_exists('footer a[href="/developers"]')
      ->element_exists('footer a[href="/verification-key"]')
      ->content_unlike(qr/Browse Plugins/);
};

subtest 'a page with no sidebar content renders full-width, with no empty #sidebar column' => sub {
    $t->get_ok('/')->element_exists_not('#sidebar');
};
```

(the existing `subtest 'developer login link is labeled for developers, not librarians'` right
below stays unchanged — it will still pass once the link moves into the navbar, since it only
checks for the text "Developer login" appearing anywhere on the page)

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/site.t`
Expected: FAIL — `#sidebar` still present on `/` (unconditional layout); no `footer` element yet.

- [ ] **Step 3: Add the footer partial**

Create `templates/partial/footer.html.ep`:

```html
<footer class="mt-5 py-4 border-top text-center text-muted small">
  <div class="container">
    <a href="/developers">For developers</a> &middot; <a href="/verification-key">Verification key</a>
  </div>
</footer>
```

- [ ] **Step 4: Make the layout's sidebar column conditional and include the footer**

In `templates/layouts/default.html.ep`, replace:

```html
    <div class="container">
      <div class="row">
        <div id="sidebar" class="col-md-3 mt-4">
          %= content 'sidebar'
        </div>
        <div id="main" class="col-md-9 mt-4">
          %= content
        </div>
      </div>
    </div>
    %= content 'footer'
    %= content 'end'
```

with:

```html
    <div class="container">
    % if (content('sidebar')) {
      <div class="row">
        <div id="sidebar" class="col-md-3 mt-4">
          %= content 'sidebar'
        </div>
        <div id="main" class="col-md-9 mt-4">
          %= content
        </div>
      </div>
    % } else {
      <div id="main" class="mt-4">
        %= content
      </div>
    % }
    </div>
    %= include 'partial/footer'
    %= content 'end'
```

(`content('sidebar')` called as a plain expression — not `%=`-printed — returns the captured
block's string, or an empty string if no child template ever defined it; Mojolicious renders the
child template's body, populating `content_for` blocks, before the layout runs, so this check sees
the final state correctly)

- [ ] **Step 5: Add the navbar login link**

In `templates/layouts/default.html.ep`, replace:

```html
        <div class="navbar-header float-right text-white">
        % if ( logged_in_user ) {
          <div class="dropdown">
```

with:

```html
        <div class="navbar-header float-right text-white">
        % if ( logged_in_user ) {
          <div class="dropdown">
```

...and replace the closing of that same `if` block:

```html
          </div>
        % }
        </div>
```

with:

```html
          </div>
        % } else {
          %= link_to '/login' => (class => 'link-underline link-underline-opacity-0 text-white') => begin
            <i class='bx bx-log-in'></i> Developer login
          % end
        % }
        </div>
```

- [ ] **Step 6: Remove the sidebar block from the nine standalone-page templates**

In each of the following files, delete the 3-line block (blank line before/after left as-is):

```html
% content_for 'sidebar' => begin
  %= include 'partial/side_menu'
% end
```

Files: `templates/plugins/index.html.ep:4-6`, `templates/site/index.html.ep:4-6`,
`templates/site/verification_key.html.ep:4-6`, `templates/login.html.ep:4-6`,
`templates/my-plugins.html.ep:4-6`, `templates/new-plugin.html.ep:4-6`,
`templates/unauthorized.html.ep:4-6`.

In `templates/site/profile.html.ep:6-8`, the block reads identically — delete the same 3 lines.

In `templates/new-plugin-step2.html.ep:7-9`, delete the same 3 lines (offset by a couple of lines
due to that template's extra leading stash lines — locate by the literal
`content_for 'sidebar'` text, not the line numbers).

`templates/plugins/show.html.ep` is **not** touched in this task — it keeps its existing
`content_for 'sidebar'` block (still including `partial/side_menu`) until Task 7 replaces it
wholesale. `partial/side_menu.html.ep`, `partial/nav_items.html.ep`, and `partial/auth_menu.html.ep`
are therefore **not** deleted yet either — Task 7 deletes all three once nothing references them.

- [ ] **Step 7: Run tests to verify they pass**

Run: `koha-prove t/site.t t/plugins_index.t t/profile.t t/verification_key.t`
Expected: PASS. (`t/plugins_show.t` is expected to still pass unchanged here too, since that
template wasn't touched.)

- [ ] **Step 8: Commit**

```bash
git add templates/layouts/default.html.ep templates/partial/footer.html.ep \
        templates/plugins/index.html.ep templates/site/index.html.ep \
        templates/site/profile.html.ep templates/site/verification_key.html.ep \
        templates/login.html.ep templates/my-plugins.html.ep templates/new-plugin.html.ep \
        templates/new-plugin-step2.html.ep templates/unauthorized.html.ep t/site.t
git commit -m "Remove the site-wide sidebar nav: full-width pages, navbar login link, footer dev links"
```

---

### Task 6: Homepage intro line

**Files:**
- Modify: `templates/plugins/index.html.ep`
- Test: `t/plugins_index.t`

- [ ] **Step 1: Write the failing test**

Add to `t/plugins_index.t`:

```perl
subtest 'homepage shows a one-line intro above the search form' => sub {
    $t->get_ok('/')->content_like(qr/Browse and install community-contributed plugins for your Koha library system\./);
};
```

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/plugins_index.t`
Expected: FAIL — text not present

- [ ] **Step 3: Add the intro line**

In `templates/plugins/index.html.ep`, replace:

```html
<h2><%= title %></h2>

%= form_for '/' => (method => 'GET', class => 'row g-2 mb-4') => begin
```

with:

```html
<h2><%= title %></h2>
<p class="lead">Browse and install community-contributed plugins for your Koha library system.</p>

%= form_for '/' => (method => 'GET', class => 'row g-2 mb-4') => begin
```

- [ ] **Step 4: Run test to verify it passes**

Run: `koha-prove t/plugins_index.t`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add templates/plugins/index.html.ep t/plugins_index.t
git commit -m "Add a one-line intro to the homepage above search"
```

---

### Task 7: Version-scoped plugin detail page

This is the largest task: it replaces the tab bar with the MetaCPAN-style header, moves the
info-block cards into the sidebar, adds the version-permalink route, and turns the technical
report into a linear section scoped to whichever version is being displayed. It also deletes the
three now-fully-unused sidebar partials.

**Files:**
- Modify: `lib/KohaPluginStore.pm` (add `show_version` route)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`_plugin_page_stash`, `show`, new
  `show_version`, `update_plugin`'s stash call)
- Modify: `templates/plugins/show.html.ep` (full rewrite)
- Delete: `templates/partial/side_menu.html.ep`, `templates/partial/nav_items.html.ep`,
  `templates/partial/auth_menu.html.ep`
- Modify: `t/plugins_show.t` (rewrite to match the new contract)

**Interfaces:**
- Consumes: `KohaPluginStore::Changelog::extract_section` (Task 3), `Model::Plugin::slugify`
  (Task 1).
- Produces: `_plugin_page_stash($c, $plugin, $current_version)` — `$current_version` is a single
  `Model::PluginVersion` object or `undef`, not the old "all versions" list. Route
  `GET /plugins/:slug/v/:tag_name` → `plugins#show_version`. Task 8's `manage` action/template are
  siblings of this page (linked from the sidebar's owner-only menu) but built independently.

- [ ] **Step 1: Write the failing controller-level tests (redirect/404/visibility semantics)**

Rewrite `t/plugins_show.t` in full:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::ReviewCheck;
use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

subtest 'unknown slug is a 404' => sub {
    $t->get_ok('/plugins/does-not-exist')->status_is(404);
};

subtest 'a published version shows no auto-refresh' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', version => '1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->text_is( '#plugin-title' => 'Widget' )
      ->element_exists_not('meta[http-equiv="refresh"]');
};

subtest 'the same version is also reachable at its own permalink' => sub {
    $t->get_ok( '/plugins/widget/v/v1.0.0' )
      ->status_is(200)
      ->text_is( '#plugin-title' => 'Widget' );
};

subtest 'a submitted version (no published version exists yet) shows the auto-refresh meta tag to its owner' => sub {
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
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('meta[http-equiv="refresh"]');

    $t->get_ok('/logout');
};

subtest 'a public visitor sees no processing state and no auto-refresh when nothing is published yet' => sub {
    $t->get_ok('/plugins/widget')
      ->status_is(200)
      ->element_exists_not('meta[http-equiv="refresh"]')
      ->content_like(qr/No published release yet/);
};

subtest 'a checks_running version shows the auto-refresh meta tag to its owner' => sub {
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
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'checks_running' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('meta[http-equiv="refresh"]');

    $t->get_ok('/logout');
};

subtest 'a changes_requested version (owner, nothing published yet) shows its own per-check results' => sub {
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
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id          => $plugin->id,
            tag_name           => 'v1.0.0',
            status             => 'changes_requested',
            certification_tier => 'INCOMPLETE',
            error_message      => 'One or more required checks failed -- see the version page for details.',
        }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $version->id, check_name => 'perl_syntax', required => 1, passed => 0, message => 'lib/Foo.pm: syntax error at line 12' }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $version->id, check_name => 'docs_presence', required => 0, passed => 1, message => undef }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/perl_syntax/)
      ->content_like(qr/lib\/Foo\.pm: syntax error at line 12/)
      ->content_like(qr/docs_presence/)
      ->content_like(qr/INCOMPLETE/);

    $t->get_ok('/logout');
};

subtest 'a single version\'s full 11-check report is not truncated by search()\'s default row limit of 10' => sub {
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
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );
    for my $letter ( 'a' .. 'k' ) {    # 11 checks, one over the default limit of 10
        KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
            { plugin_version_id => $version->id, check_name => "check_$letter", required => 0, passed => 1, message => undef }
        );
    }

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/check_a/)
      ->content_like(qr/check_k/);

    $t->get_ok('/logout');
};

subtest 'public visitor: dropdown links the published tag but only shows (does not link) a non-published one' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('a[href="/plugins/widget/v/v1.0.0"]')
      ->element_exists_not('a[href="/plugins/widget/v/v0.9.0"]')
      ->content_like(qr/v0\.9\.0/, 'the draft tag is still shown, just not linked')
      ->element_exists_not('#edit-plugin-modal');

    $t->get_ok('/plugins/widget/v/v0.9.0')->status_is(404);
};

subtest 'owner: dropdown links every version, including drafts; edit control is present' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('a[href="/plugins/widget/v/v1.0.0"]')
      ->element_exists('a[href="/plugins/widget/v/v0.9.0"]')
      ->element_exists('#edit-plugin-modal');

    $t->get_ok('/plugins/widget/v/v0.9.0')->status_is(200);

    $t->get_ok('/logout');
};

subtest 'a plugin with zero published versions renders inline at the bare URL and hides its draft from the public' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id          => $plugin->id,
            tag_name           => 'v1.0.0',
            status             => 'changes_requested',
            certification_tier => 'INCOMPLETE',
            error_message      => 'One or more required checks failed',
        }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => ( $plugin->latest_version->id ), check_name => 'perl_syntax', required => 1, passed => 0, message => 'Syntax error' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_unlike(qr/v1\.0\.0/)
      ->content_unlike(qr/INCOMPLETE/)
      ->content_unlike(qr/perl_syntax/)
      ->content_unlike(qr/Syntax error/)
      ->content_like(qr/No published release yet/);
};

subtest 'a published version shows a Signed badge; the same plugin\'s draft version does not' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published', signed_manifest => '{"slug":"widget"}', signature => 'fakesignature==' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.1.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok('/plugins/widget/v/v1.0.0')
      ->status_is(200)
      ->element_exists('.badge.text-bg-info');

    $t->get_ok('/plugins/widget/v/v1.1.0')
      ->status_is(200)
      ->element_exists_not('.badge.text-bg-info');

    $t->get_ok('/logout');
};

subtest 'readme_html renders as the primary content when present' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', readme_html => '<h1>Widget README</h1>' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/<h1>Widget README<\/h1>/, 'readme_html rendered unescaped');
};

subtest 'a plugin with no readme_html falls back gracefully' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/No README is available/);
};

subtest 'issue_tracker_url link appears only when set' => sub {
    reset_db();
    my $with_tracker = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-a', { name => 'WidgetA', repo_url => 'https://github.com/dev/widget-a', issue_tracker_url => 'https://github.com/dev/widget-a/issues' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $with_tracker->id, tag_name => 'v1.0.0', status => 'published' }
    );
    my $without_tracker = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-b', { name => 'WidgetB', repo_url => 'https://github.com/dev/widget-b' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $without_tracker->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $with_tracker->slug )
      ->status_is(200)
      ->element_exists('a[href="https://github.com/dev/widget-a/issues"]');

    $t->get_ok( '/plugins/' . $without_tracker->slug )
      ->status_is(200)
      ->content_unlike(qr/Issue tracker/);
};

subtest 'a non-owner cannot reach a non-published version\'s page at all (not just hidden content -- a 404)' => sub {
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
    my $draft = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v2.0.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $draft->id, check_name => 'perl_syntax', required => 1, passed => 0, message => 'boom' }
    );

    $t->get_ok('/plugins/widget/v/v2.0.0')
      ->status_is(200)
      ->content_like(qr/perl_syntax/);

    $t->get_ok('/logout');
    $t->get_ok('/plugins/widget/v/v2.0.0')->status_is(404);
};

subtest 'author name links to the public author page' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', author => 'Jane Doe', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('a[href="/authors/jane-doe"]')
      ->text_is('a[href="/authors/jane-doe"]' => 'Jane Doe');
};

subtest 'a changelog excerpt for the current version renders when it matches; falls back to a full-changelog link otherwise' => sub {
    reset_db();
    my $matching = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-a', { name => 'WidgetA', repo_url => 'https://github.com/dev/widget-a', changelog_html => '<h2>1.0.0</h2><p>Added sparkle.</p>' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $matching->id, tag_name => 'v1.0.0', status => 'published' }
    );
    my $nonmatching = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-b', { name => 'WidgetB', repo_url => 'https://github.com/dev/widget-b', changelog_html => '<p>Freeform notes, no headings.</p>' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $nonmatching->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $matching->slug )
      ->status_is(200)
      ->content_like(qr/Added sparkle\./);

    $t->get_ok( '/plugins/' . $nonmatching->slug )
      ->status_is(200)
      ->content_like(qr/Full changelog/)
      ->content_unlike(qr/Freeform notes/);
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/plugins_show.t`
Expected: FAIL — `/plugins/widget/v/v1.0.0` 404s (no route yet), `#plugin-title` doesn't exist,
`search_by_author_slug`/author link not wired into this template yet, etc.

- [ ] **Step 3: Add the version-permalink route**

In `lib/KohaPluginStore.pm`, add immediately after `$r->get('/plugins/:slug')->to('plugins#show');`:

```perl
    $r->get('/plugins/:slug/v/:tag_name')->to('plugins#show_version');
```

- [ ] **Step 4: Rewrite `_plugin_page_stash` and `show`; add `show_version`**

In `lib/KohaPluginStore/Controller/Plugins.pm`, add `use KohaPluginStore::Changelog;` to the top
imports, then replace the whole block from `sub _plugin_page_stash` through the end of `sub show
($c) { ... }` with:

```perl
sub _plugin_page_stash {
    my ( $c, $plugin, $current_version ) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'id' } }
    );
    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'contributions_count' } }
    );

    my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;

    my $still_processing = $current_version
        && ( $current_version->status eq 'submitted' || $current_version->status eq 'checks_running' );

    my @checks;
    if ($current_version) {
        # search()'s default_query_params applies a limit => 10 unless overridden -- a single
        # version can have as many checks as the pipeline runs (currently 11), so a generous
        # fixed limit avoids truncating that one version's own report.
        @checks = KohaPluginStore::Model::ReviewCheck->new( pg => $c->pg )->search(
            { plugin_version_id => $current_version->id }, { order_by => 'check_name', limit => 1000 }
        );
    }

    my $changelog_excerpt;
    if ( $current_version && $plugin->changelog_html ) {
        $changelog_excerpt = KohaPluginStore::Changelog::extract_section( $plugin->changelog_html, $current_version->tag_name );
    }

    return {
        plugin            => $plugin,
        versions          => \@versions,
        contributors      => \@contributors,
        current_version   => $current_version,
        still_processing  => $still_processing,
        checks            => \@checks,
        is_owner          => $is_owner,
        changelog_excerpt => $changelog_excerpt,
    };
}

sub show ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;
    my $current_version = $plugin->latest_published_version // ( $is_owner ? $plugin->latest_version : undef );

    $c->stash( %{ $c->_plugin_page_stash( $plugin, $current_version ) } );
    $c->render('plugins/show');
}

sub show_version ($c) {
    my $slug     = $c->param('slug');
    my $tag_name = $c->param('tag_name');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->find(
        { plugin_id => $plugin->id, tag_name => $tag_name }
    );
    return $c->render( text => 'Version not found', status => 404 ) unless $version;

    my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;
    return $c->render( text => 'Version not found', status => 404 )
        if $version->status ne 'published' && !$is_owner;

    $c->stash( %{ $c->_plugin_page_stash( $plugin, $version ) } );
    $c->render('plugins/show');
}
```

- [ ] **Step 5: Update `update_plugin`'s stash call**

In `lib/KohaPluginStore/Controller/Plugins.pm`, in `update_plugin`, change:

```perl
        $c->stash( %{ $c->_plugin_page_stash($plugin) } );
```

to:

```perl
        $c->stash( %{ $c->_plugin_page_stash( $plugin, $plugin->latest_published_version // $plugin->latest_version ) } );
```

- [ ] **Step 6: Rewrite the template**

Replace the entire contents of `templates/plugins/show.html.ep` with:

```html
% my $plugin            = stash 'plugin';
% my $versions          = stash 'versions';
% my $contributors      = stash 'contributors';
% my $current_version   = stash 'current_version';
% my $still_processing  = stash 'still_processing';
% my $checks            = stash('checks') || [];
% my $is_owner          = stash 'is_owner';
% my $changelog_excerpt = stash 'changelog_excerpt';
% my $errors            = stash('errors') || [];
% my $form_values       = stash('form_values') || {};
% my %tier_badge = ( CERTIFIED => 'text-bg-success', STRUCTURAL => 'text-bg-warning', INCOMPLETE => 'text-bg-danger' );
% my $author_slug = KohaPluginStore::Model::Plugin::slugify( $plugin->author // '' );
% title $plugin->name || 'Processing submission...';
% layout 'default';
% if ($still_processing) {
  %= content_for 'head' => begin
<meta http-equiv="refresh" content="5">
  %= end
% }

% content_for 'sidebar' => begin
  % if ($is_owner) {
  <ul class="list-group mb-3">
    <li class="list-group-item active">Overview</li>
    %= link_to '/plugins/'.$plugin->slug.'/manage' => (class => 'list-group-item list-group-item-action') => begin
      Manage releases
    % end
  </ul>
  % }

  <div class="card">
    <div class="card-body">
      % if ($current_version) {
      % if ($current_version->certification_tier) {
      <p><span class="badge <%= $tier_badge{$current_version->certification_tier} || 'text-bg-secondary' %>"><%= $current_version->certification_tier %></span></p>
      % }
      % if ($current_version->signature) {
      <p><span class="badge text-bg-info">Signed</span></p>
      % }
      <dl class="row mb-0">
        <dt class="col-sm-5">Koha version</dt>
        <dd class="col-sm-7"><%= $current_version->koha_min_version %><% if ($current_version->koha_max_version) { %> &ndash; <%= $current_version->koha_max_version %><% } else { %>+<% } %></dd>
      </dl>
      % if ($current_version->signature) {
      <p class="small text-muted mb-0 mt-2">Signing confirms the file hasn't been altered since the store inspected it -- not a safety or quality check; see the technical report below for that.</p>
      % }
      % } else {
      <p class="text-muted mb-0">No published release yet.</p>
      % }
    </div>
  </div>

  % if ($changelog_excerpt) {
  <div class="card mt-3">
    <div class="card-body">
      <h6 class="card-title">What's new in this version</h6>
      <%== $changelog_excerpt %>
    </div>
  </div>
  % } elsif ($plugin->changelog_html) {
  <div class="card mt-3">
    <div class="card-body">
      <a href="<%= $plugin->repo_url %>" target="_blank" rel="noopener">Full changelog &#8599;</a>
    </div>
  </div>
  % }

  <div class="card mt-3">
    <div class="card-body">
      <h6 class="card-title">Links</h6>
      <ul class="list-unstyled mb-0">
        <li><i class='bx bxl-github'></i> <a href="<%= $plugin->repo_url %>" target="_blank" rel="noopener"><%= $plugin->repo_url %></a></li>
        % if ($plugin->documentation_url) {
        <li><i class='bx bx-book'></i> <a href="<%= $plugin->documentation_url %>" target="_blank" rel="noopener">Documentation</a></li>
        % }
        % if ($plugin->issue_tracker_url) {
        <li><i class='bx bx-bug'></i> <a href="<%= $plugin->issue_tracker_url %>" target="_blank" rel="noopener">Issue tracker</a></li>
        % }
      </ul>
    </div>
  </div>

  <div class="card mt-3">
    <div class="card-body">
      <h6 class="card-title">Get this plugin</h6>
      <p class="small text-muted">Point your Koha instance's Plugin store at this store's base URL and search for this plugin's slug.</p>
      <label class="form-label small mb-0">Store base URL</label>
      <div class="input-group input-group-sm mb-2">
        <input type="text" class="form-control" readonly id="store-base-url-value" value="<%= url_for('/')->to_abs %>">
        <button type="button" class="btn btn-outline-secondary" id="copy-store-base-url">Copy</button>
      </div>
      <label class="form-label small mb-0">Plugin slug</label>
      <div class="input-group input-group-sm">
        <input type="text" class="form-control" readonly id="plugin-slug-value" value="<%= $plugin->slug %>">
        <button type="button" class="btn btn-outline-secondary" id="copy-plugin-slug">Copy</button>
      </div>
    </div>
  </div>

  % if (@$contributors) {
  <div class="card mt-3">
    <div class="card-body">
      <h6 class="card-title">Contributors</h6>
      <ul class="list-unstyled mb-0">
        % for my $contributor (@$contributors) {
        <li><img src="<%= $contributor->avatar_url %>" width="24" height="24"> <%= $contributor->github_username %></li>
        % }
      </ul>
    </div>
  </div>
  % }
% end

<div id="plugin-header" class="d-flex align-items-baseline flex-wrap gap-2 mb-3">
  % if ($plugin->author) {
  <a href="/authors/<%= $author_slug %>"><%= $plugin->author %></a>
  <span class="text-muted">/</span>
  % }
  <h1 id="plugin-title" class="mb-0 h3"><%= $plugin->name %></h1>
  % if (@$versions) {
  <div class="dropdown">
    <button class="btn btn-sm btn-outline-secondary dropdown-toggle" type="button" id="version-switcher-toggle" data-bs-toggle="dropdown" aria-expanded="false">
      <%= $current_version ? $current_version->tag_name : 'select version' %>
    </button>
    <ul class="dropdown-menu" aria-labelledby="version-switcher-toggle">
      % for my $version (@$versions) {
      <li>
        % if ($version->status eq 'published' || $is_owner) {
        %= link_to '/plugins/'.$plugin->slug.'/v/'.$version->tag_name => (class => 'dropdown-item') => begin
          <%= $version->tag_name %><% if ($version->status ne 'published') { %> &mdash; <%= $version->status =~ s/_/ /gr %><% } %>
        % end
        % } else {
        <span class="dropdown-item disabled"><%= $version->tag_name %> &mdash; <%= $version->status =~ s/_/ /gr %></span>
        % }
      </li>
      % }
    </ul>
  </div>
  % }
  % if ($is_owner) {
  <button type="button" class="btn btn-sm btn-outline-secondary" data-bs-toggle="modal" data-bs-target="#edit-plugin-modal">Edit</button>
  % }
</div>

% if ($plugin->description) {
<p class="lead"><%= $plugin->description %></p>
% }

% if (@$errors) {
<div class="alert alert-danger">
  <ul class="mb-0">
    % for my $error (@$errors) {
    <li><%= $error %></li>
    % }
  </ul>
</div>
% }

% if ($plugin->readme_html) {
<%== $plugin->readme_html %>
% } else {
<p class="text-muted">No README is available for this plugin yet.</p>
% }

% if ($current_version && (@$checks || $current_version->error_message)) {
<h2 class="h4 mt-5">Technical report &mdash; <%= $current_version->tag_name %></h2>
% if ($current_version->error_message) {
<div class="alert alert-warning py-2 mb-2"><%= $current_version->error_message %></div>
% }
% if (@$checks) {
<table class="table table-sm mb-4">
  <thead>
    <tr>
      <th>Check</th>
      <th>Required</th>
      <th>Result</th>
      <th>Message</th>
    </tr>
  </thead>
  <tbody>
    % for my $check (@$checks) {
    <tr class="<%= $check->passed ? 'text-success' : 'text-danger' %>">
      %= t td => $check->check_name
      %= t td => ($check->required ? 'Required' : 'Advisory')
      %= t td => ($check->passed ? 'Passed' : 'Failed')
      %= t td => ($check->message || '')
    </tr>
    % }
  </tbody>
</table>
% }
% }

% if ($is_owner) {
<div class="modal fade" id="edit-plugin-modal" tabindex="-1" aria-labelledby="edit-plugin-modal-label" aria-hidden="true">
  <div class="modal-dialog">
    <div class="modal-content">
      %= form_for '/plugins/'.$plugin->slug.'/edit' => (method => 'POST') => begin
        %= csrf_field
        <div class="modal-header">
          <h5 class="modal-title" id="edit-plugin-modal-label">Edit plugin</h5>
          <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
        </div>
        <div class="modal-body">
          <div class="mb-3">
            <label for="name">Name:</label>
            <input required type="text" class="form-control" name="name" id="name" value="<%= $form_values->{name} // $plugin->name %>">
          </div>
          <div class="mb-3">
            <label for="description">Description:</label>
            <input required type="text" class="form-control" name="description" id="description" value="<%= $form_values->{description} // $plugin->description %>">
          </div>
          <div class="mb-3">
            <label for="repo_url">Repository URL:</label>
            <input required type="text" class="form-control" name="repo_url" id="repo_url" value="<%= $form_values->{repo_url} // $plugin->repo_url %>">
          </div>
          <div class="mb-3">
            <label for="author">Author:</label>
            <input required type="text" class="form-control" name="author" id="author" value="<%= $form_values->{author} // $plugin->author %>">
          </div>
          <div class="mb-3">
            <label for="issue_tracker_url">Issue tracker URL (optional):</label>
            <input type="url" class="form-control" name="issue_tracker_url" id="issue_tracker_url" value="<%= $form_values->{issue_tracker_url} // $plugin->issue_tracker_url %>">
          </div>
        </div>
        <div class="modal-footer">
          <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Cancel</button>
          <button type="submit" class="btn btn-primary">Save changes</button>
        </div>
      % end
    </div>
  </div>
</div>
% }

% if (@$errors) {
<script>
document.addEventListener('DOMContentLoaded', function () {
  new bootstrap.Modal(document.getElementById('edit-plugin-modal')).show();
});
</script>
% }

<script>
(function () {
  function wireCopyButton(buttonId, valueId) {
    var button = document.getElementById(buttonId);
    var input = document.getElementById(valueId);
    if (!button || !input) return;
    button.addEventListener('click', function () {
      var original = button.textContent;
      var showCopied = function () {
        button.textContent = 'Copied!';
        setTimeout(function () { button.textContent = original; }, 2000);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(input.value).then(showCopied);
      } else {
        input.select();
        document.execCommand('copy');
        showCopied();
      }
    });
  }
  document.addEventListener('DOMContentLoaded', function () {
    wireCopyButton('copy-store-base-url', 'store-base-url-value');
    wireCopyButton('copy-plugin-slug', 'plugin-slug-value');
  });
})();
</script>
```

Notable removals from the old template: the `#plugin-tabs` nav, the tab-restoring
`shown.bs.tab`/location-hash script (no tabs left to restore), the combined all-versions Releases
table, and the owner's GitHub-sync table (both now live on `templates/plugins/manage.html.ep`,
Task 8).

- [ ] **Step 7: Delete the now-fully-unused sidebar partials**

```bash
git rm templates/partial/side_menu.html.ep templates/partial/nav_items.html.ep templates/partial/auth_menu.html.ep
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `koha-prove t/plugins_show.t t/plugins_update.t t/site.t`
Expected: PASS. (`t/plugins_update.t` covers `update_plugin`'s validation-failure re-render path
touched in Step 5 — re-run it explicitly since that code path isn't exercised by
`t/plugins_show.t`.)

- [ ] **Step 9: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Plugins.pm \
        templates/plugins/show.html.ep t/plugins_show.t
git rm templates/partial/side_menu.html.ep templates/partial/nav_items.html.ep templates/partial/auth_menu.html.ep
git commit -m "Replace the plugin detail page's tab bar with a MetaCPAN-style header and per-version pages"
```

---

### Task 8: Owner-only "Manage releases" view

**Files:**
- Modify: `lib/KohaPluginStore.pm` (add `manage` route)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (add `manage` action)
- Create: `templates/plugins/manage.html.ep`
- Create: `t/plugins_manage.t`

**Interfaces:**
- Consumes: `Model::Plugin`, `Model::PluginVersion`, `KohaPluginStore::GitHub::fetch_releases`
  (all pre-existing).
- Produces: `GET /plugins/:slug/manage` → `plugins#manage`, rendering
  `templates/plugins/manage.html.ep`.

- [ ] **Step 1: Write the failing tests**

Create `t/plugins_manage.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

subtest 'an anonymous visitor is redirected/denied' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(404);
};

subtest 'a logged-in developer who does not own this plugin gets a 404' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )->status_is(404);

    $t->get_ok('/logout');
};

subtest 'the owner sees every version regardless of status, plus GitHub-sync section, and triggers a fetch' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    my $fetch_calls = 0;
    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub {
            $fetch_calls++;
            return [ { name => 'v2.0.0', tag_name => 'v2.0.0', published_at => '2026-01-01', assets => [ { name => 'plugin.kpz' } ] } ];
        };
    }

    $t->get_ok( '/plugins/' . $plugin->slug . '/manage' )
      ->status_is(200)
      ->content_like(qr/v1\.0\.0/)
      ->content_like(qr/v0\.9\.0/)
      ->content_like(qr/v2\.0\.0/)
      ->element_exists('form[action="/new-release"]');
    is( $fetch_calls, 1 );

    $t->get_ok('/logout');
};

done_testing();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `koha-prove t/plugins_manage.t`
Expected: FAIL — route doesn't exist yet (404 for the wrong reason initially, then once the route
exists it'll fail on missing owner-gating/template).

- [ ] **Step 3: Add the route**

In `lib/KohaPluginStore.pm`, add after `$r->get('/plugins/:slug/v/:tag_name')->to('plugins#show_version');`:

```perl
    $r->get('/plugins/:slug/manage')->requires( user_authenticated => 1 )->to('plugins#manage');
```

- [ ] **Step 4: Implement the controller action**

In `lib/KohaPluginStore/Controller/Plugins.pm`, add after `show_version`:

```perl
sub manage ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;
    return $c->render( text => 'Plugin not found', status => 404 ) unless $is_owner;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'id' } }
    );

    my $config           = $c->app->plugin('Config');
    my $github_releases  = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin->repo_url );
    my $existing_tags    = { map { $_->tag_name => 1 } @versions };

    foreach my $release (@$github_releases) {
        if ( $existing_tags->{ $release->{tag_name} } ) {
            $release->{message}->{success} = 'Release has already been submitted.';
            next;
        }
        my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
        if ( scalar @kpz_assets != 1 ) {
            $release->{message}->{error} = 'Release must contain one and only one \'.kpz\' asset.';
        }
    }

    $c->stash(
        plugin          => $plugin,
        versions        => \@versions,
        github_releases => $github_releases,
    );
    $c->render('plugins/manage');
}
```

- [ ] **Step 5: Create the template**

Create `templates/plugins/manage.html.ep`:

```html
% my $plugin          = stash 'plugin';
% my $versions        = stash 'versions';
% my $github_releases = stash('github_releases') || [];
% my %tier_badge = ( CERTIFIED => 'text-bg-success', STRUCTURAL => 'text-bg-warning', INCOMPLETE => 'text-bg-danger' );
% title 'Manage releases -- ' . $plugin->name;
% layout 'default';

% content_for 'sidebar' => begin
  <ul class="list-group mb-3">
    %= link_to '/plugins/'.$plugin->slug => (class => 'list-group-item list-group-item-action') => begin
      Overview
    % end
    <li class="list-group-item active">Manage releases</li>
  </ul>
% end

<h2>Manage releases &mdash; <%= $plugin->name %></h2>

<table class="table">
  <thead>
    <tr>
      <th>Tag</th>
      <th>Version</th>
      <th>Status</th>
      <th>Certification</th>
      <th>Signed</th>
    </tr>
  </thead>
  <tbody>
    % for my $version (@$versions) {
    <tr>
      %= t td => $version->tag_name
      %= t td => ($version->version || '-')
      %= t td => $version->status
      <td>
        % if ($version->certification_tier) {
          <span class="badge <%= $tier_badge{$version->certification_tier} || 'text-bg-secondary' %>"><%= $version->certification_tier %></span>
        % }
      </td>
      <td>
        % if ($version->signature) {
          <span class="badge text-bg-info">Signed</span>
        % }
      </td>
    </tr>
    % }
  </tbody>
</table>

<p class="text-muted small">
  Every published version is signed automatically -- this confirms the file hasn't been altered
  since the store inspected it. It is not a safety or quality check; see each version's own page
  for its full technical report.
</p>

<h3>Releases from <i class='bx bxl-github'></i> github:</h3>
<table class="table">
  <thead>
    <tr>
      <th>Name</th>
      <th>Tag name</th>
      <th>Published at</th>
      <th>Actions</th>
    </tr>
  </thead>
  <tbody>
    % for my $release (@$github_releases) {
      % if ($release->{message}->{success}) {
      <tr class="text-success">
      % } elsif ($release->{message}->{error}) {
      <tr class="text-danger">
      % } else {
      <tr>
      % }
        %= t td => $release->{name}
        %= t td => $release->{tag_name}
        %= t td => $release->{published_at}
        % if ($release->{message}->{success}) {
        %= t td => $release->{message}->{success}
        % } elsif ($release->{message}->{error}) {
        %= t td => $release->{message}->{error}
        % } else {
        %= t td => form_for '/new-release' => (method => 'POST') => begin
          %= csrf_field
          <input type="hidden" name="plugin_id" value="<%= $plugin->id %>">
          <input type="hidden" name="tag_name" value="<%= $release->{tag_name} %>">
          <button type="submit" class="btn btn-primary">Add this release</button>
        % end
        % }
      </tr>
    % }
  </tbody>
</table>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `koha-prove t/plugins_manage.t`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/Controller/Plugins.pm \
        templates/plugins/manage.html.ep t/plugins_manage.t
git commit -m "Add an owner-only /plugins/:slug/manage view for release history and GitHub sync"
```

---

### Task 9: Full-suite verification and spec cross-check

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `koha-prove t/`
Expected: PASS, no regressions. (`t/login.t` is documented as stale/pre-existing-broken in
`CLAUDE.md` — ignore any failures there, they predate this work.)

- [ ] **Step 2: Run the QA script**

Run whatever this repo's `koha-qa`-equivalent lint/critic step is for this project (check
`CONTRIBUTING.md` if unsure) against every file touched across Tasks 1-8.

- [ ] **Step 3: Manual smoke test**

Start the dev server (`morbo script/koha_plugin_store`) and, in a browser:
- Visit `/` — confirm full-width layout, intro line, footer links to `/developers` and
  `/verification-key`.
- Visit a plugin's page — confirm the `Author / Name [tag ▾]` header, sidebar info-blocks,
  version-switcher dropdown, and linear Technical report section.
- Log in as a plugin owner; confirm the sidebar's Overview/Manage releases menu appears and both
  pages render correctly, and the version dropdown includes draft versions as real links.
- Visit `/authors/<some-author-slug>` for an existing seeded plugin's author.

- [ ] **Step 4: Cross-check against the spec**

Re-read
[`docs/superpowers/specs/2026-09-23-plugin-page-layout-redesign-design.md`](../specs/2026-09-23-plugin-page-layout-redesign-design.md)
section by section and confirm each one has a corresponding completed task above. The one
documented deviation (no 302 redirect from the bare plugin URL) is called out in this plan's
Global Constraints section.

- [ ] **Step 5: Commit** (only if Steps 1-4 required fixes)

```bash
git add -A
git commit -m "Fix regressions found during full-suite verification of the layout redesign"
```
