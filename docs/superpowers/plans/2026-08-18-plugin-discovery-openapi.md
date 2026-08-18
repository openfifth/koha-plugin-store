# Plugin Discovery OpenAPI Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the store's ad-hoc `GET /api/plugins` into a documented, OpenAPI-contracted
`GET /api/v1/plugins` with real server-side search/pagination/sort, fix its N+1 query
pattern, and make Koha-version compatibility filtering correct (a real `koha_max_version`
bound instead of an unenforced one, and safe version comparison instead of comparing free
text) — then update both consumers (Koha's Perl and Vue client) to match.

**Architecture:** The store's existing `/api/v1` OpenAPI route group
(`Mojolicious::Plugin::OpenAPI`, `lib/KohaPluginStore/OpenAPI/spec.yaml`) gains two public
paths routed to the existing `Controller::Plugins` (via per-operation `x-mojo-to`, since the
group's default controller is `Controller::Api`). Compatibility filtering moves from an
in-Perl `>` comparison over free text to a normalized, canonical-form `TEXT` column
comparison in SQL, computed once at submission time by a new shared version-normalization
module. The N+1 release-fetch becomes two queries: one for a page of matching plugin IDs
(plus a sibling count), one batch-fetching all their compatible releases.

**Tech Stack:** Perl (`Modern::Perl`), Mojolicious (`Mojo::Pg`, `Mojolicious::Plugin::OpenAPI`),
`Test::More` (`done_testing()`, no fixed count, in this repo) for the store; Koha core's
`Modern::Perl`/`Mojo::UserAgent`, `Test::More tests => N` (fixed count) + `Test::NoWarnings`
for `Koha/Plugins/Store.pm`; Vue 3 Options API for the client.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-18-plugin-discovery-openapi-design.md` (this plan's
  source of truth), committed on this repo's `planning` branch.
- **Two repos, two worktrees:**
  - Store-side tasks (1–7) happen in a **new worktree/branch**, `worktree-plugin-discovery-api`,
    branched from `origin/main` of the `koha-plugin-store` bare repo
    (`/home/martin/Projects/koha/tooling/koha-plugin-store/store.git`) — matching this
    project's existing `worktree-<feature>` convention (see `worktree-check-pipeline`,
    `worktree-signing-pipeline`, etc.). Do not commit this work directly to the `main`
    worktree.
  - Koha-side tasks (8–9) happen in the existing `bug_35837` worktree
    (`/home/martin/Projects/koha/core/worktrees/bug_35837`, branch `bug_35837`) — already
    the home of the rest of this feature's Koha-core work.
- **Dependency ordering:** Tasks 8–9 (Koha-side) consume the contract Tasks 1–7 (store-side)
  define. They can be implemented and unit-tested independently against the *documented*
  contract (mocked HTTP responses, no live store needed) — neither Koha task requires the
  store worktree to exist locally — but don't consider bug 35837's plugin-discovery feature
  actually working end-to-end until the store side is deployed somewhere Koha can reach.
- **Store repo test convention:** `Test::More` with `done_testing()` — no fixed `tests => N`
  count to maintain (unlike Koha core). `subtest`s each get their own `plan tests => N`.
- **Koha repo test convention:** `t/Koha/Plugins/Store.t` uses a fixed
  `use Test::More tests => 6;` (5 subtests + `Test::NoWarnings`) — update that count only if
  a task adds a new top-level subtest; adding assertions *inside* an existing subtest only
  changes that subtest's own `plan tests => N`.
- Follow existing code style exactly in both repos: 4-space indent, no unrelated
  reformatting. Store-repo Perl: `Modern::Perl`, `Mojo::Base -signatures` where the file
  already uses it. Koha-core Perl: `Modern::Perl`, existing POD conventions.
- New Koha version strings are canonicalized as `MM.mm.pp.bbb` (2/2/2/3-digit
  zero-padded segments, e.g. `26.06.00.011`) by `KohaPluginStore::Version::normalize`
  (Task 2) — the *only* place this format is decided; every other task consumes it as a
  black box.

---

### Task 1: `koha_max_version` column

**Repo/worktree:** `koha-plugin-store`, new worktree `worktree-plugin-discovery-api`.

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (new migration block, end of `__DATA__`)
- Modify: `lib/KohaPluginStore/Model/PluginVersion.pm:11-13` (`_columns`)
- Test: `t/model_plugin_version.t` (new file — no existing test file for this model)

**Interfaces:**
- Produces: `plugin_versions.koha_max_version` (`TEXT`, nullable). `NULL` means "no upper
  bound" — every task after this one must treat `NULL` that way, never as "incompatible
  with everything."

- [ ] **Step 1: Create the worktree**

```bash
cd /home/martin/Projects/koha/tooling/koha-plugin-store/store.git
git worktree add ../worktrees/worktree-plugin-discovery-api -b worktree-plugin-discovery-api origin/main
cd ../worktrees/worktree-plugin-discovery-api
```

All subsequent steps in Tasks 1–7 run from this worktree.

- [ ] **Step 2: Write the failing test**

Create `t/model_plugin_version.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

subtest 'koha_max_version round-trips through create/find, defaults to undef' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, version => '1.0.0', koha_min_version => '23.11.00.000' }
    );
    is( $version->koha_max_version, undef, 'koha_max_version defaults to undef when not given' );

    my $bounded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id        => $plugin->id,
            version          => '2.0.0',
            tag_name         => 'v2.0.0',
            koha_min_version => '23.11.00.000',
            koha_max_version => '25.05.00.000',
        }
    );
    is( $bounded->koha_max_version, '25.05.00.000', 'koha_max_version round-trips when given' );
};

done_testing();
```

- [ ] **Step 3: Run it to verify it fails**

```bash
docker compose up -d postgres
prove -l t/model_plugin_version.t
```

Expected: FAIL — `koha_max_version is not a column on plugin_versions` (from `Model::Base`'s
`AUTOLOAD`, since the column doesn't exist yet and isn't in `_columns`).

- [ ] **Step 4: Add the migration**

In `lib/KohaPluginStore/Command/migrate.pm`, append after the existing `-- 6 down` block
(end of `__DATA__`):

```
-- 7 up
ALTER TABLE plugin_versions ADD COLUMN koha_max_version TEXT;

-- 7 down
ALTER TABLE plugin_versions DROP COLUMN koha_max_version;
```

- [ ] **Step 5: Add the column to the model**

In `lib/KohaPluginStore/Model/PluginVersion.pm:11-13`, change:

```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier signed_manifest signature)];
}
```

to:

```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version koha_max_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier signed_manifest signature)];
}
```

- [ ] **Step 6: Apply the migration and run the test**

```bash
script/koha_plugin_store migrate
prove -l t/model_plugin_version.t
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/PluginVersion.pm t/model_plugin_version.t
git commit -m "Add koha_max_version to plugin_versions"
```

---

### Task 2: `KohaPluginStore::Version::normalize`

**Repo/worktree:** `koha-plugin-store`, `worktree-plugin-discovery-api`.

**Files:**
- Create: `lib/KohaPluginStore/Version.pm`
- Test: `t/version.t`

**Interfaces:**
- Produces: `KohaPluginStore::Version::normalize($string)` → a canonical `MM.mm.pp.bbb`
  string (2/2/2/3-digit zero-padded), or `undef` if `$string` isn't a dotted-numeric
  version (empty, non-numeric segment, more than 4 segments). Never dies.

This mirrors Koha core's own `Koha::Plugins::Base::_version_compare` (splits on
`. + : ~ -`, pads missing trailing segments with `0`) but produces a fixed-width string
for safe `TEXT` comparison in SQL, rather than a comparison result — and additionally
rejects non-numeric segments and inputs with more than 4 segments, which
`_version_compare` tolerates (it only needs to *compare*, not store a canonical form).

- [ ] **Step 1: Write the failing test**

Create `t/version.t`:

```perl
use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Version qw(normalize);

subtest 'normalizes a full 4-segment version' => sub {
    is( normalize('26.06.00.011'), '26.06.00.011', 'already-canonical input is unchanged' );
};

subtest 'zero-pads missing trailing segments' => sub {
    is( normalize('23.11'), '23.11.00.000', 'a 2-segment version gets padded to 4' );
    is( normalize('23'), '23.00.00.000', 'a 1-segment version gets padded to 4' );
};

subtest 'normalizes inconsistent zero-padding to the canonical width' => sub {
    is( normalize('9.5.0.0'), '09.05.00.000', 'single-digit segments get padded' );
};

subtest 'rejects non-numeric segments' => sub {
    is( normalize('23.11.beta'), undef, 'a non-numeric segment is rejected' );
    is( normalize('not-a-version'), undef, 'non-numeric input is rejected' );
};

subtest 'rejects more than 4 segments' => sub {
    is( normalize('23.11.00.000.1'), undef, 'a 5-segment version is rejected' );
};

subtest 'rejects empty or undef input' => sub {
    is( normalize(''), undef, 'empty string is rejected' );
    is( normalize(undef), undef, 'undef is rejected' );
};

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/version.t
```

Expected: FAIL — `Can't locate KohaPluginStore/Version.pm`.

- [ ] **Step 3: Implement**

Create `lib/KohaPluginStore/Version.pm`:

```perl
package KohaPluginStore::Version;

use Modern::Perl;
use Exporter 'import';

our @EXPORT_OK = qw(normalize);

=head1 NAME

KohaPluginStore::Version

=head1 API

=head2 Functions

=head3 normalize

    my $canonical = normalize('23.11');
    # '23.11.00.000'

Parses a Koha version string the same way Koha core's own
C<Koha::Plugins::Base::_version_compare> does (split on C<. + : ~ ->, zero-pad missing
trailing segments), then renders it as a fixed-width C<MM.mm.pp.bbb> string safe for a
plain C<TEXT> comparison in SQL. Returns C<undef> -- never dies -- if C<$string> isn't a
dotted-numeric version: empty/undef, a non-numeric segment, or more than 4 segments.

=cut

sub normalize {
    my ($string) = @_;
    return unless defined $string && length $string;

    my @parts = split /[.+:~-]/, $string;
    return unless @parts;
    return if @parts > 4;
    return if grep { !/^\d+$/ } @parts;

    push @parts, 0 while @parts < 4;

    return sprintf( '%02d.%02d.%02d.%03d', @parts );
}

1;
```

- [ ] **Step 4: Run it to verify it passes**

```bash
prove -l t/version.t
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Version.pm t/version.t
git commit -m "Add KohaPluginStore::Version::normalize"
```

---

### Task 3: Validate and normalize versions in `ProcessPluginVersion`

**Repo/worktree:** `koha-plugin-store`, `worktree-plugin-discovery-api`.

**Files:**
- Modify: `lib/KohaPluginStore/Task/ProcessPluginVersion.pm:107-112` (replace the existing
  `minimum_version` presence check) and `:207-217` (the final `$version->update`)
- Test: `t/task_process_plugin_version.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Version::normalize` (Task 2).
- Produces: a published `plugin_versions` row now always has a normalized
  `koha_min_version`, and a normalized `koha_max_version` if the plugin declared one — never
  the raw, author-supplied string.

- [ ] **Step 1: Write the failing tests**

This file mocks `KohaPluginStore::GitHub`'s functions and `KohaPluginStore::Check::PerlSyntax`'s
Docker-sandboxing internals via direct glob assignment (`no strict 'refs'; no warnings
'redefine'; *Package::function = sub {...};`), not `Test::MockModule` — match that exact
style, and reuse the file-level `$t` (`my $t = test_app();`, declared once near the top)
rather than creating a new one per subtest. `make_kpz`, `test_pg`, `reset_db`, `$t`, and
`copy` (from the file's own `use File::Copy 'copy';`) are all already in scope.

In `t/task_process_plugin_version.t`, find the existing `subtest 'missing minimum_version
sets changes_requested'` (around line 173) and add three new subtests immediately after
it, following the exact same glob-mocking pattern that subtest already uses:

```perl
subtest 'malformed minimum_version sets changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $bad_plugin_pm = <<'PERL';
package Koha::Plugin::Test::Widget;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name => 'Widget',
    minimum_version => 'not-a-version',
    version => '1.0.0',
};
1;
PERL
    my $fixture_zip = make_kpz($bad_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub { return [] };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/minimum_version.*not a valid Koha version/, 'error message names the problem' );
};

subtest 'malformed maximum_version sets changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $bad_plugin_pm = <<'PERL';
package Koha::Plugin::Test::Widget;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name => 'Widget',
    minimum_version => '23.11',
    maximum_version => 'also-not-a-version',
    version => '1.0.0',
};
1;
PERL
    my $fixture_zip = make_kpz($bad_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub { return [] };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/maximum_version.*not a valid Koha version/, 'error message names the problem' );
};

subtest 'valid minimum_version and maximum_version are normalized on publish' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $plugin_pm = <<'PERL';
package Koha::Plugin::Test::Widget;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name => 'Widget',
    description => 'A test widget',
    author => 'Someone',
    minimum_version => '23.11',
    maximum_version => '25.5',
    version => '1.0.0',
    license => 'GPL-3.0',
};
1;
PERL
    my $fixture_zip = make_kpz($plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files    = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub { return "syntax OK\n" };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    is( $reloaded->koha_min_version, '23.11.00.000', 'minimum_version is normalized' );
    is( $reloaded->koha_max_version, '25.05.00.000', 'maximum_version is normalized' );
};
```

The first two subtests reject before reaching the check pipeline, so they don't need the
`PerlSyntax`/`fetch_tag_has_test_files` mocks (matching the existing 'missing
minimum_version' subtest, which doesn't need them either). The third subtest publishes
successfully, so it needs the full mock set, matching 'successful processing publishes the
version' (line 70).

Also fix a pre-existing assertion this task's implementation will otherwise break: in
`subtest 'successful processing publishes the version'` (line 70), change:

```perl
    is( $reloaded->koha_min_version, '23.05', 'koha_min_version parsed from metadata' );
```

to:

```perl
    is( $reloaded->koha_min_version, '23.05.00.000', 'koha_min_version is normalized from metadata' );
```

(`$valid_plugin_pm`, this subtest's fixture, declares `minimum_version => '23.05'` — after
this task's change, the stored value is the normalized `23.05.00.000`, not the raw string.)

- [ ] **Step 2: Run the tests to verify they fail**

```bash
prove -l t/task_process_plugin_version.t
```

Expected: the three new subtests FAIL — malformed versions aren't rejected yet, and
`koha_min_version`/`koha_max_version` are stored verbatim, not normalized. The
just-edited assertion in 'successful processing publishes the version' also FAILS at this
point (still expects the old raw-string behavior against not-yet-changed code) — this is
expected and resolves in Step 4 along with everything else.

- [ ] **Step 3: Implement**

In `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`, add the import near the top
(after `use KohaPluginStore::Signing;`):

```perl
use KohaPluginStore::Version qw(normalize);
```

Replace the existing block at lines 107-112:

```perl
    unless ( $metadata->{minimum_version} ) {
        $version->update(
            { status => 'changes_requested', error_message => 'Plugin metadata is missing \'minimum_version\'.' }
        );
        return;
    }
```

with:

```perl
    unless ( $metadata->{minimum_version} ) {
        $version->update(
            { status => 'changes_requested', error_message => 'Plugin metadata is missing \'minimum_version\'.' }
        );
        return;
    }

    my $koha_min_version = normalize( $metadata->{minimum_version} );
    unless ($koha_min_version) {
        $version->update(
            {
                status        => 'changes_requested',
                error_message => "Plugin metadata's minimum_version ('$metadata->{minimum_version}') is not a valid Koha version string.",
            }
        );
        return;
    }

    my $koha_max_version;
    if ( $metadata->{maximum_version} ) {
        $koha_max_version = normalize( $metadata->{maximum_version} );
        unless ($koha_max_version) {
            $version->update(
                {
                    status        => 'changes_requested',
                    error_message => "Plugin metadata's maximum_version ('$metadata->{maximum_version}') is not a valid Koha version string.",
                }
            );
            return;
        }
    }
```

Then change the final `$version->update` (lines 207-217) from:

```perl
    $version->update(
        {
            status             => 'published',
            content_digest     => $digest,
            version            => $metadata->{version},
            koha_min_version   => $metadata->{minimum_version},
            certification_tier => $gating_failed ? 'STRUCTURAL' : 'CERTIFIED',
            signed_manifest    => $json,
            signature          => $signature,
        }
    );
```

to:

```perl
    $version->update(
        {
            status             => 'published',
            content_digest     => $digest,
            version            => $metadata->{version},
            koha_min_version   => $koha_min_version,
            koha_max_version   => $koha_max_version,
            certification_tier => $gating_failed ? 'STRUCTURAL' : 'CERTIFIED',
            signed_manifest    => $json,
            signature          => $signature,
        }
    );
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
prove -l t/task_process_plugin_version.t
```

Expected: PASS, including every pre-existing subtest.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Task/ProcessPluginVersion.pm t/task_process_plugin_version.t
git commit -m "Validate and normalize minimum_version/maximum_version at publish time"
```

---

### Task 4: Backfill existing rows

**Repo/worktree:** `koha-plugin-store`, `worktree-plugin-discovery-api`.

**Files:**
- Create: `lib/KohaPluginStore/Command/backfill_koha_versions.pm`
- Test: `t/command_backfill_koha_versions.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Version::normalize` (Task 2).
- Produces: a `script/koha_plugin_store backfill_koha_versions` command that rewrites every
  `plugin_versions.koha_min_version` to its normalized form in place, and logs (via `warn`,
  to STDERR — this is a one-off maintenance command run by a human, not a Minion job) any
  row whose `koha_min_version` doesn't parse, leaving that row's value untouched.

- [ ] **Step 1: Write the failing test**

Create `t/command_backfill_koha_versions.t`, following the exact instantiation style
`t/command_generate_signing_key.t` already established for one-off commands
(`KohaPluginStore::Command::<name>->new( app => $app )->run(...)` — not
`Mojo::Server->load_app`/`$app->commands->run`):

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::backfill_koha_versions;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );

my $good = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    { plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', koha_min_version => '23.11' }
);
my $bad = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    { plugin_id => $plugin->id, version => '2.0.0', tag_name => 'v2', koha_min_version => 'not-a-version' }
);

my $app = KohaPluginStore->new;
$app->pg( test_pg() );

KohaPluginStore::Command::backfill_koha_versions->new( app => $app )->run;

my $reloaded_good = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $good->id } );
my $reloaded_bad  = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $bad->id } );

is( $reloaded_good->koha_min_version, '23.11.00.000', 'a parseable value is normalized in place' );
is( $reloaded_bad->koha_min_version, 'not-a-version', 'an unparseable value is left untouched' );

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

```bash
prove -l t/command_backfill_koha_versions.t
```

Expected: FAIL — `Can't locate KohaPluginStore/Command/backfill_koha_versions.pm`.

- [ ] **Step 3: Implement**

Create `lib/KohaPluginStore/Command/backfill_koha_versions.pm`, modeled on the existing
`Command::migrate` (`Mojolicious::Command` subclass, `$self->app->pg`):

```perl
package KohaPluginStore::Command::backfill_koha_versions;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Version qw(normalize);

has description => 'Normalize existing koha_min_version values to the canonical form';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = $self->app->pg;

    my $rows = $pg->db->query('SELECT id, koha_min_version FROM plugin_versions')->hashes;

    my ( $updated, $skipped ) = ( 0, 0 );
    for my $row (@$rows) {
        my $canonical = normalize( $row->{koha_min_version} );
        unless ($canonical) {
            warn "plugin_versions.id=$row->{id}: could not parse koha_min_version '"
                . ( $row->{koha_min_version} // '(null)' ) . "', leaving unchanged\n";
            $skipped++;
            next;
        }
        next if $canonical eq $row->{koha_min_version};

        $pg->db->query( 'UPDATE plugin_versions SET koha_min_version = ? WHERE id = ?', $canonical, $row->{id} );
        $updated++;
    }

    say "Normalized $updated row(s), skipped $skipped unparseable row(s).";
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::backfill_koha_versions - Normalize existing koha_min_version values

=head1 SYNOPSIS

  Usage: APPLICATION backfill_koha_versions

=cut
```

- [ ] **Step 4: Run it to verify it passes**

```bash
prove -l t/command_backfill_koha_versions.t
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Command/backfill_koha_versions.pm t/command_backfill_koha_versions.t
git commit -m "Add backfill_koha_versions command to normalize existing rows"
```

---

### Task 5: Two-query batch-fetch Model methods

**Repo/worktree:** `koha-plugin-store`, `worktree-plugin-discovery-api`.

**Files:**
- Modify: `lib/KohaPluginStore/Model/Plugin.pm` (two new methods)
- Modify: `lib/KohaPluginStore/Model/PluginVersion.pm` (one new method)
- Test: `t/model_plugin.t`, `t/model_plugin_version.t`

**Interfaces:**
- Produces: `KohaPluginStore::Model::Plugin->new(pg => $pg)->search_compatible($args)` →
  arrayref of `Plugin` objects for one page, where `$args` is
  `{ koha_version => $v, q => $q_or_undef, order_by => 'name'|'-name', limit => $n, offset => $n }`.
- Produces: `KohaPluginStore::Model::Plugin->new(pg => $pg)->count_compatible($args)` →
  integer, same filter semantics as `search_compatible` (`q`/`koha_version` only —
  `order_by`/`limit`/`offset` are meaningless for a count and are ignored if passed).
- Produces: `KohaPluginStore::Model::PluginVersion->new(pg => $pg)->for_plugin_ids(\@ids, { koha_version => $v })`
  → arrayref of `PluginVersion` objects: every published, compatible release for exactly
  those plugin IDs, ordered by `date_released DESC`. Returns `[]` (not an error) if
  `\@ids` is empty.

- [ ] **Step 1: Write the failing tests**

In `t/model_plugin.t`, add at the end (before `done_testing();`):

```perl
subtest 'search_compatible filters by koha_version, q, and paginates' => sub {
    reset_db();
    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'CoverFlow', description => 'A widget' }
    );
    my $reportkit = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'ReportKit', description => 'Reporting tools' }
    );
    my $unpublished = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'DraftOnly', description => 'Nothing published yet' }
    );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $coverflow->id, version => '1.0.0', tag_name => 'v1',
            status => 'published', koha_min_version => '23.11.00.000',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $reportkit->id, version => '1.0.0', tag_name => 'v1',
            status => 'published', koha_min_version => '25.11.00.000',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $unpublished->id, version => '1.0.0', tag_name => 'v1',
            status => 'submitted', koha_min_version => '23.11.00.000',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    my $compatible = $model->search_compatible(
        { koha_version => '24.05.00.000', order_by => 'name', limit => 10, offset => 0 }
    );
    is( scalar @$compatible, 1, 'only the plugin whose sole release is old enough is returned' );
    is( $compatible->[0]->name, 'CoverFlow', 'CoverFlow (23.11) is compatible with 24.05' );

    my $both = $model->search_compatible(
        { koha_version => '26.00.00.000', order_by => 'name', limit => 10, offset => 0 }
    );
    is( scalar @$both, 2, 'both published, compatible plugins are returned for a later Koha version' );
    is( $both->[0]->name, 'CoverFlow', 'ordered by name ascending' );
    is( $both->[1]->name, 'ReportKit', 'ordered by name ascending' );

    my $filtered = $model->search_compatible(
        { koha_version => '26.00.00.000', q => 'report', order_by => 'name', limit => 10, offset => 0 }
    );
    is( scalar @$filtered, 1, 'q filters by name/description substring, case-insensitively' );
    is( $filtered->[0]->name, 'ReportKit', 'the matching plugin is returned' );

    is(
        $model->count_compatible( { koha_version => '26.00.00.000' } ), 2,
        'count_compatible matches search_compatible\'s filter, ignoring pagination'
    );
};

subtest 'search_compatible respects koha_max_version as an upper bound' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'OldPlugin' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000', koha_max_version => '23.00.00.000',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    is(
        scalar @{ $model->search_compatible( { koha_version => '22.00.00.000', limit => 10, offset => 0 } ) }, 1,
        'a version within [min, max] is compatible'
    );
    is(
        scalar @{ $model->search_compatible( { koha_version => '24.00.00.000', limit => 10, offset => 0 } ) }, 0,
        'a version above koha_max_version is excluded'
    );
};

subtest 'search_compatible treats a null koha_max_version as no ceiling' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'ForeverPlugin' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    is(
        scalar @{ $model->search_compatible( { koha_version => '99.00.00.000', limit => 10, offset => 0 } ) }, 1,
        'a plugin with no koha_max_version stays compatible with a far-future version'
    );
};
```

In `t/model_plugin_version.t`, add at the end (before `done_testing();`):

```perl
subtest 'for_plugin_ids batch-fetches published, compatible releases for exactly the given plugins' => sub {
    reset_db();
    my $a = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'A' } );
    my $b = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'B' } );
    my $c = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'C' } );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $a->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $a->id, version => '2.0.0', tag_name => 'v2', status => 'submitted', koha_min_version => '20.00.00.000' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $b->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $c->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
    );

    my $versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )
        ->for_plugin_ids( [ $a->id, $b->id ], { koha_version => '24.00.00.000' } );

    is( scalar @$versions, 2, 'only published releases for the requested plugin ids are returned' );
    my @plugin_ids = sort map { $_->plugin_id } @$versions;
    is_deeply( \@plugin_ids, [ sort ( $a->id, $b->id ) ], 'exactly A and B, not C' );
};

subtest 'for_plugin_ids returns an empty arrayref for an empty id list' => sub {
    reset_db();
    is_deeply(
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->for_plugin_ids( [], { koha_version => '24.00.00.000' } ),
        [], 'no query is attempted, just an empty result'
    );
};
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
prove -l t/model_plugin.t t/model_plugin_version.t
```

Expected: FAIL — `search_compatible`/`count_compatible`/`for_plugin_ids` don't exist yet.

- [ ] **Step 3: Implement `search_compatible`/`count_compatible`**

In `lib/KohaPluginStore/Model/Plugin.pm`, add after `create_with_unique_slug` (before the
trailing `1;`):

```perl
my %ORDER_BY = (
    'name'  => 'p.name ASC',
    '-name' => 'p.name DESC',
);

sub _compatible_where_and_binds {
    my ( $self, $args ) = @_;

    my @clauses = ( "v.status = 'published'", 'v.koha_min_version <= ?', '(v.koha_max_version IS NULL OR v.koha_max_version >= ?)' );
    my @binds   = ( $args->{koha_version}, $args->{koha_version} );

    if ( defined $args->{q} && length $args->{q} ) {
        push @clauses, '(p.name ILIKE ? OR p.description ILIKE ?)';
        push @binds, '%' . $args->{q} . '%', '%' . $args->{q} . '%';
    }

    return ( join( ' AND ', @clauses ), \@binds );
}

sub search_compatible {
    my ( $self, $args ) = @_;

    my ( $where, $binds ) = $self->_compatible_where_and_binds($args);
    my $order_by = $ORDER_BY{ $args->{order_by} // '' } // $ORDER_BY{name};

    my $rows = $self->pg->db->query(
        qq{
            SELECT DISTINCT p.*
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE $where
            ORDER BY $order_by
            LIMIT ? OFFSET ?
        },
        @$binds, $args->{limit}, $args->{offset}
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}

sub count_compatible {
    my ( $self, $args ) = @_;

    my ( $where, $binds ) = $self->_compatible_where_and_binds($args);

    my $count = $self->pg->db->query(
        qq{
            SELECT COUNT(DISTINCT p.id)
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE $where
        },
        @$binds
    )->array->[0];

    return $count;
}
```

`$ORDER_BY` is a fixed whitelist deliberately -- `$args->{order_by}` must never be
interpolated into SQL directly, since it ultimately traces back to a client-supplied
`_order_by` query parameter (Task 6).

- [ ] **Step 4: Implement `for_plugin_ids`**

In `lib/KohaPluginStore/Model/PluginVersion.pm`, add before the trailing `1;`:

```perl
sub for_plugin_ids {
    my ( $self, $plugin_ids, $args ) = @_;

    return [] unless @$plugin_ids;

    my $placeholders = join ',', ('?') x scalar(@$plugin_ids);

    my $rows = $self->pg->db->query(
        qq{
            SELECT *
            FROM plugin_versions
            WHERE status = 'published'
              AND plugin_id IN ($placeholders)
              AND koha_min_version <= ?
              AND (koha_max_version IS NULL OR koha_max_version >= ?)
            ORDER BY date_released DESC
        },
        @$plugin_ids, $args->{koha_version}, $args->{koha_version}
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
prove -l t/model_plugin.t t/model_plugin_version.t
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/Model/Plugin.pm lib/KohaPluginStore/Model/PluginVersion.pm t/model_plugin.t t/model_plugin_version.t
git commit -m "Add search_compatible/count_compatible/for_plugin_ids for the discovery API"
```

---

### Task 6: Rewrite `list_all` and `verify`

**Repo/worktree:** `koha-plugin-store`, `worktree-plugin-discovery-api`.

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm:146-215` (`list_all`, `verify`)
- Test: `t/api_plugins.t`, `t/api_plugins_verify.t` (rewritten in Task 7, once the routes
  actually move -- this task keeps the *old* unversioned routes working with the *new*
  query logic, so existing tests keep passing unmodified in the meantime)

**Interfaces:**
- Consumes: `Model::Plugin->search_compatible`/`count_compatible`,
  `Model::PluginVersion->for_plugin_ids` (Task 5).
- Produces: `list_all`/`verify`'s external behavior is unchanged from Task 5's tests'
  perspective (still mounted at the old paths for now -- Task 7 moves them) but `list_all`
  now accepts `q`, `_page`, `_per_page`, `_order_by` and sets `X-Total-Count`.

- [ ] **Step 1: Write the failing tests**

In `t/api_plugins.t`, add these subtests before `done_testing();` (the existing seeded
plugin has `koha_min_version => '19.05'` -- unnormalized, since it's created directly via
`Model::PluginVersion->create`, bypassing `ProcessPluginVersion`'s Task 3 normalization;
these new subtests seed their own, already-canonical fixtures rather than relying on that
one):

```perl
subtest 'q filters by name/description, koha_max_version excludes an incompatible release, X-Total-Count is set' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'seeder' }
    );
    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'CoverFlow', description => 'A widget', developer_id => $developer->id }
    );
    my $reportkit = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'ReportKit', description => 'Reporting tools', developer_id => $developer->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $coverflow->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $reportkit->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000', koha_max_version => '21.00.00.000',
        }
    );

    my $t = test_app();

    $t->get_ok('/api/plugins?koha_version_release=25.00.00.000&q=report')
      ->status_is(200)
      ->json_is( '/0/name' => 'ReportKit' )
      ->header_is( 'X-Total-Count' => 0 );
    is( scalar @{ $t->tx->res->json }, 0, 'ReportKit itself is excluded -- its only release is above koha_max_version' );

    $t->get_ok('/api/plugins?koha_version_release=20.50.00.000&q=report')
      ->status_is(200)
      ->json_is( '/0/name' => 'ReportKit' )
      ->header_is( 'X-Total-Count' => 1 );
};

subtest '_page and _per_page paginate; _order_by=-name sorts descending' => sub {
    reset_db();
    for my $name (qw(Alpha Bravo Charlie)) {
        my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => $name } );
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            { plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
        );
    }

    my $t = test_app();

    $t->get_ok('/api/plugins?koha_version_release=25.00.00.000&_page=1&_per_page=2&_order_by=-name')
      ->status_is(200)
      ->json_is( '/0/name' => 'Charlie' )
      ->json_is( '/1/name' => 'Bravo' )
      ->header_is( 'X-Total-Count' => 3 );
    is( scalar @{ $t->tx->res->json }, 2, 'only 2 of 3 returned on page 1' );

    $t->get_ok('/api/plugins?koha_version_release=25.00.00.000&_page=2&_per_page=2&_order_by=-name')
      ->status_is(200)
      ->json_is( '/0/name' => 'Alpha' );
    is( scalar @{ $t->tx->res->json }, 1, 'the remaining plugin is on page 2' );
};
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
prove -l t/api_plugins.t
```

Expected: the new subtests FAIL -- `q`/`_page`/`_per_page`/`_order_by`/`koha_max_version`
aren't consulted yet, and `X-Total-Count` isn't set. The pre-existing subtests (using
`koha_version_release`) should still PASS at this point -- Step 3 keeps that param name
working for now; Task 7 renames it when the route moves.

- [ ] **Step 3: Implement**

In `lib/KohaPluginStore/Controller/Plugins.pm`, replace `sub list_all` (lines 146-189)
with:

```perl
sub list_all ($c) {
    my $koha_version = $c->param('koha_version_release');

    return $c->render( text => 'koha_version_release required', status => 400 ) unless $koha_version;

    my $q        = $c->param('q');
    my $page     = $c->param('_page') || 1;
    my $per_page = $c->param('_per_page') || 20;
    my $order_by = $c->param('_order_by');

    my $args = { koha_version => $koha_version, q => $q, order_by => $order_by };

    my $plugin_model = KohaPluginStore::Model::Plugin->new( pg => $c->pg );
    my $total        = $plugin_model->count_compatible($args);

    my @plugins;
    if ( $per_page == -1 ) {
        @plugins = @{ $plugin_model->search_compatible( { %$args, limit => $total, offset => 0 } ) };
    }
    else {
        @plugins = @{ $plugin_model->search_compatible( { %$args, limit => $per_page, offset => ( $page - 1 ) * $per_page } ) };
    }

    my @plugin_hashes = map { $_->unblessed } @plugins;
    my $releases      = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )
        ->for_plugin_ids( [ map { $_->{id} } @plugin_hashes ], { koha_version => $koha_version } );

    my %releases_by_plugin_id;
    push @{ $releases_by_plugin_id{ $_->plugin_id } }, $_ for @$releases;

    for my $plugin (@plugin_hashes) {
        for my $release ( @{ $releases_by_plugin_id{ $plugin->{id} } // [] } ) {
            push(
                @{ $plugin->{releases} },
                {
                    name               => $release->name,
                    tag_name           => $release->tag_name,
                    version            => $release->version,
                    koha_min_version   => $release->koha_min_version,
                    kpz_url            => $release->kpz_url,
                    date_released      => $release->date_released,
                    content_digest     => $release->content_digest,
                    certification_tier => $release->certification_tier,
                    author_username    => $release->author_username,
                    author_avatar_url  => $release->author_avatar_url,
                    signed_manifest    => $release->signed_manifest,
                    signature          => $release->signature,
                }
            );
        }

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }

    # The following is required for CORS
    # Without this, users won't be able to list from remote locations
    $c->res->headers->header( 'Access-Control-Allow-Origin'  => '*' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type,x-koha-request-id' );
    $c->res->headers->header( 'Access-Control-Allow-Methods' => 'get,options' );
    $c->res->headers->header( 'X-Total-Count'                => $total );

    return $c->render( json => \@plugin_hashes, status => 200 );
}
```

`verify` is unchanged in this task -- Task 7 relocates it but doesn't change its logic.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
prove -l t/api_plugins.t t/api_plugins_verify.t
```

Expected: PASS -- including the pre-existing `koha_version_release`-based subtests, since
the param name hasn't changed yet.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/api_plugins.t
git commit -m "Add q/pagination/sort/koha_max_version to list_all"
```

---

### Task 7: Move both routes under `/api/v1`, rename the param

**Repo/worktree:** `koha-plugin-store`, `worktree-plugin-discovery-api`.

**Files:**
- Modify: `lib/KohaPluginStore.pm` (delete the two old route lines)
- Modify: `lib/KohaPluginStore/OpenAPI/spec.yaml` (add both paths)
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`koha_version_release` →
  `koha_version` param name; `$c->render(json => ...)` → `$c->render(openapi => ...)` to
  match this app's existing OpenAPI-routed controller methods' convention)
- Modify: `t/api_plugins.t`, `t/api_plugins_verify.t` (new paths, renamed param)

**Interfaces:**
- Produces: `GET /api/v1/plugins`, `GET /api/v1/plugins/verify` -- the old unversioned
  `/api/plugins`, `/api/plugins/verify` no longer exist (deleted, not aliased -- see the
  design doc §3 for why).

- [ ] **Step 1: Write the failing tests**

In `t/api_plugins.t`, change every `$t->get_ok('/api/plugins...')` to
`$t->get_ok('/api/v1/plugins...')`, and every `koha_version_release=` to `koha_version=`.
For example, the first subtest becomes:

```perl
subtest 'requires koha_version' => sub {
    $t->get_ok('/api/v1/plugins')->status_is(400);
};
```

...and so on for every subtest added across Tasks 6 and the pre-existing ones in this file
(mechanical find-and-replace: `/api/plugins` → `/api/v1/plugins`, `koha_version_release=`
→ `koha_version=`).

In `t/api_plugins_verify.t`, change every `$t->get_ok('/api/plugins/verify...')` to
`$t->get_ok('/api/v1/plugins/verify...')`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
prove -l t/api_plugins.t t/api_plugins_verify.t
```

Expected: FAIL -- `/api/v1/plugins` and `/api/v1/plugins/verify` don't exist yet (still
routed at the old unversioned paths).

- [ ] **Step 3: Rename the param in the controller**

In `lib/KohaPluginStore/Controller/Plugins.pm`, in `list_all`, change:

```perl
    my $koha_version = $c->param('koha_version_release');

    return $c->render( text => 'koha_version_release required', status => 400 ) unless $koha_version;
```

to:

```perl
    my $koha_version = $c->param('koha_version');

    return $c->render( openapi => { error => 'koha_version required' }, status => 400 ) unless $koha_version;
```

Change the final `return $c->render( json => \@plugin_hashes, status => 200 );` to
`return $c->render( openapi => \@plugin_hashes, status => 200 );`.

In `verify`, change `return $c->render( text => 'digest must be a 64-character sha256 hex string', status => 400 )`
to `return $c->render( openapi => { error => 'digest must be a 64-character sha256 hex string' }, status => 400 )`,
`return $c->render( text => 'no signed version found for this digest', status => 404 )` to
`return $c->render( openapi => { error => 'no signed version found for this digest' }, status => 404 )`,
and its final `return $c->render( json => {...}, status => 200 )` to
`return $c->render( openapi => {...}, status => 200 )` (body unchanged).

- [ ] **Step 4: Move the routes**

In `lib/KohaPluginStore.pm`, delete:

```perl
    #TODO: Use OpenAPI mojolicious plugin?
    $r->any('/api/plugins')->to('plugins#list_all');
    $r->get('/api/plugins/verify')->to('plugins#verify');
```

In `lib/KohaPluginStore/OpenAPI/spec.yaml`, add under `paths:` (alongside the existing
`/ping` and `/developer/repos`; no `security:` block on either -- like `/ping`, these are
public by default, since the spec has no top-level security requirement):

```yaml
  /plugins:
    get:
      operationId: listPlugins
      x-mojo-to: plugins#list_all
      parameters:
        - name: koha_version
          in: query
          required: true
          schema:
            type: string
        - name: q
          in: query
          required: false
          schema:
            type: string
        - name: _page
          in: query
          required: false
          schema:
            type: integer
        - name: _per_page
          in: query
          required: false
          schema:
            type: integer
        - name: _order_by
          in: query
          required: false
          schema:
            type: string
      responses:
        '200':
          description: Compatible, published plugins with their compatible releases
          content:
            application/json:
              schema:
                type: array
                items:
                  type: object
        '400':
          description: koha_version is required
          content:
            application/json:
              schema:
                type: object
  /plugins/verify:
    get:
      operationId: verifyPluginDigest
      x-mojo-to: plugins#verify
      parameters:
        - name: digest
          in: query
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Signed manifest, signature, and certification tier for the published version matching this digest
          content:
            application/json:
              schema:
                type: object
        '400':
          description: digest is not a valid sha256 hex string
          content:
            application/json:
              schema:
                type: object
        '404':
          description: no published version found for this digest
          content:
            application/json:
              schema:
                type: object
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
prove -l t/api_plugins.t t/api_plugins_verify.t
```

Expected: PASS.

- [ ] **Step 6: Run the full store test suite**

```bash
prove -l t/
```

Expected: PASS (confirms nothing else in the repo referenced the old paths -- the design
doc's own review already confirmed the store's own web UI doesn't call this endpoint, so
this is a final safety check, not an expected-fail step).

- [ ] **Step 7: Commit**

```bash
git add lib/KohaPluginStore.pm lib/KohaPluginStore/OpenAPI/spec.yaml lib/KohaPluginStore/Controller/Plugins.pm t/api_plugins.t t/api_plugins_verify.t
git commit -m "Move plugin discovery/verify under /api/v1, rename koha_version_release to koha_version"
```

This is the last store-side task. At this point the store's half of the contract in the
design doc is complete and independently deployable.

---

### Task 8: Update `Koha::Plugins::Store`

**Repo/worktree:** Koha core, `bug_35837` (`/home/martin/Projects/koha/core/worktrees/bug_35837`).

**Files:**
- Modify: `Koha/Plugins/Store.pm` (both methods)
- Test: `t/Koha/Plugins/Store.t`

**Interfaces:**
- Produces: `lookup_by_kpz_url`/`lookup_by_digest`'s public signatures and return shapes
  are unchanged -- only the URL and query param they call against change.

- [ ] **Step 1: Write the failing tests**

In `t/Koha/Plugins/Store.t`, each `Test::MockModule->new('Mojo::UserAgent')->mock(get =>
sub {...})` currently ignores the URL it's called with entirely. Add a URL-capturing
assertion to each subtest that exercises an HTTP call, so a wrong URL/param actually fails
the test. Replace the subtest `'returns undef when no release matches the given kpz_url'`
(lines 37-56) with:

```perl
subtest 'returns undef when no release matches the given kpz_url' => sub {
    plan tests => 2;
    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );
    t::lib::Mocks::mock_preference( 'Version', '26.06.00.000' );

    my $requested_url;
    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            ( undef, $requested_url ) = @_;
            my $tx = Mojo::Transaction::HTTP->new;
            $tx->res->code(200);
            $tx->res->body('[]');
            return $tx;
        }
    );

    is(
        Koha::Plugins::Store->lookup_by_kpz_url('https://example.com/nomatch.kpz'), undef,
        'undef when the store has no plugin with a matching release kpz_url'
    );
    is(
        $requested_url, 'http://store.example.com/api/v1/plugins?koha_version=26.06.00.000&_per_page=-1',
        'requests the v1 path with koha_version and _per_page=-1 (needs the full, unpaginated catalog to scan)'
    );
};
```

Replace the subtest `'resolves repo_url, certification_tier, signed_manifest, and
signature for a matching kpz_url'` (lines 58-88) similarly, adding the same URL capture
and a second assertion after the existing `is_deeply`:

```perl
subtest 'resolves repo_url, certification_tier, signed_manifest, and signature for a matching kpz_url' => sub {
    plan tests => 2;

    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );
    t::lib::Mocks::mock_preference( 'Version', '26.06.00.000' );

    my $requested_url;
    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            ( undef, $requested_url ) = @_;
            my $tx   = Mojo::Transaction::HTTP->new;
            my $body =
                  '[{"repo_url":"https://github.com/openfifth/koha-plugin-coverflow","releases":'
                . '[{"kpz_url":"https://example.com/match.kpz","certification_tier":"CERTIFIED",'
                . '"signed_manifest":"{\"digest\":\"abc123\"}","signature":"fakesignaturebase64=="}]}]';
            $tx->res->code(200);
            $tx->res->body($body);
            return $tx;
        }
    );

    is_deeply(
        Koha::Plugins::Store->lookup_by_kpz_url('https://example.com/match.kpz'),
        {
            repo_url           => 'https://github.com/openfifth/koha-plugin-coverflow',
            certification_tier => 'CERTIFIED',
            signed_manifest    => '{"digest":"abc123"}',
            signature          => 'fakesignaturebase64==',
        },
        'repo_url, certification_tier, signed_manifest, and signature all resolved from the matching release'
    );
    is(
        $requested_url, 'http://store.example.com/api/v1/plugins?koha_version=26.06.00.000&_per_page=-1',
        'requests the v1 path with koha_version and _per_page=-1'
    );
};
```

Replace the two `lookup_by_digest` subtests (lines 90-126) similarly, capturing and
asserting the URL:

```perl
subtest 'lookup_by_digest returns undef when plugin_store_url is not configured' => sub {
    plan tests => 1;
    t::lib::Mocks::mock_config( 'plugin_store_url', undef );
    is( Koha::Plugins::Store->lookup_by_digest('abc123'), undef, 'undef when the store URL is not configured' );
};

subtest 'lookup_by_digest resolves signed_manifest, signature, and certification_tier for a known digest' => sub {
    plan tests => 3;

    t::lib::Mocks::mock_config( 'plugin_store_url', 'http://store.example.com' );

    my $requested_url;
    my $ua_module = Test::MockModule->new('Mojo::UserAgent');
    $ua_module->mock(
        get => sub {
            ( undef, $requested_url ) = @_;
            my $tx = Mojo::Transaction::HTTP->new;
            $tx->res->code(200);
            $tx->res->body(
                '{"signed_manifest":"{\"digest\":\"abc123\"}","signature":"fakesig==","certification_tier":"CERTIFIED"}'
            );
            return $tx;
        }
    );
    is_deeply(
        Koha::Plugins::Store->lookup_by_digest('abc123'),
        { signed_manifest => '{"digest":"abc123"}', signature => 'fakesig==', certification_tier => 'CERTIFIED' },
        'fields resolved from a 200 response'
    );
    is(
        $requested_url, 'http://store.example.com/api/v1/plugins/verify?digest=abc123',
        'requests the v1 verify path'
    );

    $ua_module->mock(
        get => sub {
            my $tx = Mojo::Transaction::HTTP->new;
            $tx->res->code(404);
            return $tx;
        }
    );
    is( Koha::Plugins::Store->lookup_by_digest('unknown'), undef, 'undef on a 404 (no matching published version)' );
};
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
ktd --name "${KTD_INSTANCE:-bug_35837}" --shell --run 'prove -v t/Koha/Plugins/Store.t'
```

Expected: the `is($requested_url, ...)` assertions FAIL (still requesting the old
`/api/plugins?koha_version_release=...` path); the pre-existing `is_deeply`/`is` result
assertions still PASS, since `Store.pm` hasn't changed yet.

- [ ] **Step 3: Implement**

In `Koha/Plugins/Store.pm`, change `lookup_by_kpz_url`'s request line:

```perl
    my $tx           = $ua->get("$store_url/api/plugins?koha_version_release=$koha_version");
```

to:

```perl
    my $tx           = $ua->get("$store_url/api/v1/plugins?koha_version=$koha_version&_per_page=-1");
```

Change `lookup_by_digest`'s request line:

```perl
    my $tx = $ua->get("$store_url/api/plugins/verify?digest=$digest");
```

to:

```perl
    my $tx = $ua->get("$store_url/api/v1/plugins/verify?digest=$digest");
```

Update both methods' POD (`C<GET /api/plugins?koha_version_release=...>` →
`C<GET /api/v1/plugins?koha_version=...&_per_page=-1>`; `C<GET
/api/plugins/verify?digest=...>` → `C<GET /api/v1/plugins/verify?digest=...>`).

- [ ] **Step 4: Run the tests to verify they pass**

```bash
ktd --name "${KTD_INSTANCE:-bug_35837}" --shell --run 'prove -v t/Koha/Plugins/Store.t'
```

Expected: all subtests PASS (file-level count stays `tests => 6` -- no new top-level
subtest was added, only assertions inside existing ones).

- [ ] **Step 5: Commit**

```bash
git add Koha/Plugins/Store.pm t/Koha/Plugins/Store.t
git commit -m "Bug 35837: Point Koha::Plugins::Store at the store's /api/v1 discovery contract"
```

---

### Task 9: Update the Vue client

**Repo/worktree:** Koha core, `bug_35837`.

**Files:**
- Modify: `koha-tmpl/intranet-tmpl/prog/js/vue/fetch/plugin-store-api-client.js`
- Modify: `koha-tmpl/intranet-tmpl/prog/js/vue/components/Plugin-store/SearchModal.vue`

**Interfaces:**
- Produces: `PluginStoreAPIClient.plugins.getStoreAll(koha_version, q)` -- a new second
  parameter, `q`, threaded through to the server. `SearchModal.vue`'s search box now
  triggers a server request (debounced) instead of filtering an already-fetched array in
  JavaScript.

**No automated test coverage exists for these components** (confirmed -- no
`.test.js`/`__tests__` for any Plugin-store Vue file, consistent with the rest of this
feature area). Step 4 is manual verification against a running KTD instance.

- [ ] **Step 1: Update the API client**

In `plugin-store-api-client.js`, change:

```javascript
            getStoreAll: koha_version_release =>
                this.getAll({
                    endpoint: `${plugin_store_url}/api/plugins`,
                    params: {
                        koha_version_release: koha_version_release
                            ? koha_version_release
                            : "",
                    },
                }),
```

to:

```javascript
            getStoreAll: (koha_version, q) =>
                this.getAll({
                    endpoint: `${plugin_store_url}/api/v1/plugins`,
                    params: {
                        koha_version: koha_version || "",
                        ...(q ? { q } : {}),
                        _per_page: 100,
                    },
                }),
```

`_per_page: 100` is explicit here because `HttpClient.getAll()`
(`koha-tmpl/intranet-tmpl/prog/js/vue/fetch/http-client.js:104-123`) defaults to
`_per_page: -1` (unlimited) unless overridden -- per the design doc, this endpoint should
fetch a generous first page rather than the entire catalog, deferring real pagination UI
until the catalog actually outgrows 100 entries.

- [ ] **Step 2: Update `SearchModal.vue` to send `q` server-side**

Replace the `data()`/`computed`/`beforeCreate` section:

```javascript
    data() {
        return {
            storeCatalog: [],
            searchTerm: "",
        };
    },
    computed: {
        availablePlugins() {
            const installedClasses = this.installed_plugins.map(p => p.class);
            return this.storeCatalog.filter(
                p => !installedClasses.includes(p.class_name)
            );
        },
        filteredPlugins() {
            if (!this.searchTerm) return this.availablePlugins;
            const term = this.searchTerm.toLowerCase();
            return this.availablePlugins.filter(p =>
                [p.name, p.description, p.author].some(
                    field => field && field.toLowerCase().includes(term)
                )
            );
        },
    },
    beforeCreate() {
        const client = APIClient.plugin_store;
        client.plugins.getStoreAll(this.koha_version?.release).then(
            result => {
                this.storeCatalog = result;
            },
            () => {
                this.setError(
                    this.$__(
                        "The plugin store could not be reached. Please check your internet connection and try again."
                    )
                );
            }
        );
    },
```

with:

```javascript
    data() {
        return {
            storeCatalog: [],
            searchTerm: "",
            searchDebounceTimer: null,
        };
    },
    computed: {
        filteredPlugins() {
            const installedClasses = this.installed_plugins.map(p => p.class);
            return this.storeCatalog.filter(
                p => !installedClasses.includes(p.class_name)
            );
        },
    },
    watch: {
        searchTerm() {
            clearTimeout(this.searchDebounceTimer);
            this.searchDebounceTimer = setTimeout(
                () => this.fetchCatalog(),
                300
            );
        },
    },
    beforeCreate() {
        this.fetchCatalog();
    },
    methods: {
        fetchCatalog() {
            const client = APIClient.plugin_store;
            client.plugins
                .getStoreAll(this.koha_version?.release, this.searchTerm)
                .then(
                    result => {
                        this.storeCatalog = result;
                    },
                    () => {
                        this.setError(
                            this.$__(
                                "The plugin store could not be reached. Please check your internet connection and try again."
                            )
                        );
                    }
                );
        },
```

(the existing `mostRecentRelease`/`install` methods stay in the same `methods` block,
unchanged -- this just adds `fetchCatalog` alongside them and removes the now-redundant
client-side `availablePlugins`/`filteredPlugins` split, since server-side `q` replaces the
JS substring filter and `filteredPlugins` now only needs to do the installed-plugin
exclusion).

Note: `fetchCatalog` referencing `this.koha_version` inside `beforeCreate` relies on
`koha_version` being a global already available at that point (unchanged from today's
code, which does the same in its existing `beforeCreate`).

- [ ] **Step 3: Rebuild the Vue bundle**

```bash
ktd --name "${KTD_INSTANCE:-bug_35837}" --shell --run 'yarn build'
```

- [ ] **Step 4: Manual verification**

Requires the store's `worktree-plugin-discovery-api` branch (Tasks 1-7) running somewhere
this KTD instance's `plugin_store_url` config points at -- the store's own
`DEVELOPMENT.md` documents running it locally via `morbo`/Docker.

Against a running KTD instance:
1. Open the plugin manager's search/install modal. Confirm the catalog loads (network tab:
   request to `/api/v1/plugins`, not `/api/plugins`).
2. Type a search term. Confirm a new request fires (debounced -- not one per keystroke)
   with `q=<term>` in the query string, and the visible list updates to the server's
   filtered response, not a client-side re-filter of the original list.
3. Confirm a plugin whose only release's `koha_max_version` is below this Koha instance's
   version does not appear in the results at all.
4. Confirm install still works from a search result (unrelated to this change, but a
   regression here would mean the response shape broke on the way through).

- [ ] **Step 5: Commit**

```bash
git add koha-tmpl/intranet-tmpl/prog/js/vue/fetch/plugin-store-api-client.js koha-tmpl/intranet-tmpl/prog/js/vue/components/Plugin-store/SearchModal.vue
git commit -m "Bug 35837: Send search term server-side, point SearchModal at /api/v1/plugins"
```
