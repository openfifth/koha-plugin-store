# Publish Signing & Digest Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sign every published plugin version with the store's Ed25519 key, expose the signed
manifest through the discovery API and a new digest-lookup endpoint, and make the
signing/certification distinction visible in the UI.

**Architecture:** A new pure `KohaPluginStore::Signing` module builds a canonical JSON
manifest and signs it; `ProcessPluginVersion` calls it once at the exact moment a version is
marked `published`, storing the manifest and signature verbatim. The discovery API and a new
`GET /api/plugins/verify` endpoint expose them; two templates gain small, explicit "signed"
UI facts kept visually separate from the certification-tier badge.

**Tech Stack:** Mojolicious (Perl), Postgres via `Mojo::Pg`, `CryptX` (`Crypt::PK::Ed25519`),
Minion, Test::Mojo, Test::More.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-13-signing-and-verification-design.md` (this plan's
  source of truth).
- The signed manifest is exactly `{ slug, version, kpz_url, digest, published_at }` —
  **`certification_tier` must never appear inside `signed_manifest`**. It's exposed as a
  separate, independently-updatable field everywhere it appears in an API response.
- Canonical serialization is `JSON->new->canonical->utf8->encode($manifest)` — sorted keys,
  deterministic regardless of Perl hash iteration order. This exact string is both what gets
  signed and what gets stored; nothing reconstructs it independently at read time.
- A signing key that can't be loaded must `die` and fail the whole Minion job (existing
  `attempts => 3` retry applies) — never silently publish unsigned.
- Known pre-existing, unrelated test failure: `t/task_process_plugin_version.t`'s
  "successful processing publishes the version" subtest already fails before this plan
  (contributor-recording assertions crash with `Can't call method "github_username" on an
  undefined value` — confirmed present on `main` before any of this plan's changes, unrelated
  to signing). Do not investigate or fix it as part of this plan. This plan's own new
  subtests are self-contained and mock `fetch_contributors` to return `[]`, sidestepping that
  code path entirely rather than depending on or fixing it.
- Test containers: this repo's tests run inside an already-running Docker Compose stack.
  Since `/app` is bind-mounted from the host (`docker-compose.yml`'s `.:/app`), file edits are
  visible in the container immediately — no `docker compose cp` needed — but the **worker**
  container caches loaded Perl modules in memory and must be restarted
  (`docker compose restart worker`) after any code change before that change takes effect in
  a running Minion job. Run tests via: `docker compose exec -T app bash -lc 'export
  PERL5LIB=$(pwd)/local/lib/perl5; export
  KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store";
  prove -l t/<file>.t'`.

---

### Task 1: `KohaPluginStore::Signing` module

**Files:**
- Create: `lib/KohaPluginStore/Signing.pm`
- Test: `t/signing.t`
- Modify: `cpanfile` (add `CryptX`)

**Interfaces:**
- Produces: `KohaPluginStore::Signing::build_manifest($plugin, $version)` → hashref
  `{ slug, version, kpz_url, digest, published_at }`. `$plugin`/`$version` are
  `KohaPluginStore::Model::Plugin`/`PluginVersion` instances (or anything with the same
  `->slug`/`->version`/`->kpz_url`/`->content_digest` accessors).
  `KohaPluginStore::Signing::canonical_json($manifest)` → sorted-key JSON string.
  `KohaPluginStore::Signing::sign($json_string, $private_key_pem)` → base64-encoded signature
  string. `KohaPluginStore::Signing::verify($json_string, $signature_b64, $public_key_pem)` →
  `1` or `0`.

- [ ] **Step 1: Add the CryptX dependency**

Add to `cpanfile` (after the existing `requires 'Digest::SHA';` line):

```perl
requires 'CryptX';
```

- [ ] **Step 2: Write the failing test**

Create `t/signing.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use Crypt::PK::Ed25519;

use KohaPluginStore::Signing;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

my $keypair = Crypt::PK::Ed25519->new;
$keypair->generate_key;
my $private_key_pem = $keypair->export_key_pem('private');
my $public_key_pem   = $keypair->export_key_pem('public');

my $plugin = KohaPluginStore::Model::Plugin->new( pg => undef, data => { slug => 'widget' } );
my $version = KohaPluginStore::Model::PluginVersion->new(
    pg   => undef,
    data => {
        version        => '1.0.0',
        kpz_url        => 'https://example.com/widget.kpz',
        content_digest => 'abc123',
    },
);

subtest 'build_manifest produces the expected shape' => sub {
    my $manifest = KohaPluginStore::Signing::build_manifest( $plugin, $version );

    like(
        delete $manifest->{published_at}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
        'published_at looks like an RFC3339 timestamp'
    );
    is_deeply(
        $manifest,
        {
            slug    => 'widget',
            version => '1.0.0',
            kpz_url => 'https://example.com/widget.kpz',
            digest  => 'abc123',
        },
        'remaining fields match plugin/version data, and certification_tier is not present'
    );
};

subtest 'canonical_json is deterministic regardless of input hash key order' => sub {
    my $a = {
        slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc',
        published_at => '2026-01-01T00:00:00Z',
    };
    my $b = {
        published_at => '2026-01-01T00:00:00Z', digest => 'abc', kpz_url => 'https://x',
        version => '1.0.0', slug => 'widget',
    };
    is(
        KohaPluginStore::Signing::canonical_json($a), KohaPluginStore::Signing::canonical_json($b),
        'same content, different key order, same output'
    );
};

subtest 'sign then verify round-trips successfully' => sub {
    my $json = KohaPluginStore::Signing::canonical_json(
        { slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc', published_at => '2026-01-01T00:00:00Z' }
    );
    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );
    ok( KohaPluginStore::Signing::verify( $json, $signature, $public_key_pem ), 'verifies against the matching public key' );
};

subtest 'verify fails against a wrong public key' => sub {
    my $other_keypair = Crypt::PK::Ed25519->new;
    $other_keypair->generate_key;
    my $wrong_public_key_pem = $other_keypair->export_key_pem('public');

    my $json = KohaPluginStore::Signing::canonical_json(
        { slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc', published_at => '2026-01-01T00:00:00Z' }
    );
    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );
    ok( !KohaPluginStore::Signing::verify( $json, $signature, $wrong_public_key_pem ), 'fails against a different keypair\'s public key' );
};

subtest 'verify fails against a tampered JSON string' => sub {
    my $json = KohaPluginStore::Signing::canonical_json(
        { slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc', published_at => '2026-01-01T00:00:00Z' }
    );
    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );
    ( my $tampered = $json ) =~ s/widget/tampered/;
    ok( !KohaPluginStore::Signing::verify( $tampered, $signature, $public_key_pem ), 'fails when the signed content is altered' );
};

done_testing();
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cpanm --installdeps . --notest
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/signing.t'
```

Expected: FAIL — `KohaPluginStore::Signing` doesn't exist yet (`Can't locate
KohaPluginStore/Signing.pm`).

- [ ] **Step 4: Implement `KohaPluginStore::Signing`**

Create `lib/KohaPluginStore/Signing.pm`:

```perl
package KohaPluginStore::Signing;

use Modern::Perl;
use JSON;
use Mojo::Date;
use Crypt::PK::Ed25519;
use MIME::Base64 qw(encode_base64 decode_base64);

sub build_manifest {
    my ( $plugin, $version ) = @_;

    return {
        slug         => $plugin->slug,
        version      => $version->version,
        kpz_url      => $version->kpz_url,
        digest       => $version->content_digest,
        published_at => Mojo::Date->new(time)->to_datetime,
    };
}

sub canonical_json {
    my ($manifest) = @_;
    return JSON->new->canonical->utf8->encode($manifest);
}

sub sign {
    my ( $json_string, $private_key_pem ) = @_;
    my $pk = Crypt::PK::Ed25519->new( \$private_key_pem );
    return encode_base64( $pk->sign_message($json_string), '' );
}

sub verify {
    my ( $json_string, $signature_b64, $public_key_pem ) = @_;
    my $pk = Crypt::PK::Ed25519->new( \$public_key_pem );
    return $pk->verify_message( decode_base64($signature_b64), $json_string ) ? 1 : 0;
}

1;
```

- [ ] **Step 5: Run the test to verify it passes**

Same command as Step 3. Expected: PASS — all 5 subtests succeed.

- [ ] **Step 6: Commit**

```bash
git add cpanfile lib/KohaPluginStore/Signing.pm t/signing.t
git commit -m "Add KohaPluginStore::Signing for building and signing the publish manifest"
```

---

### Task 2: `generate_signing_key` command

**Files:**
- Create: `lib/KohaPluginStore/Command/generate_signing_key.pm`
- Test: `t/command_generate_signing_key.t`

**Interfaces:**
- Consumes: `Crypt::PK::Ed25519` (Task 1's dependency).
- Produces: a Mojolicious::Command writing an Ed25519 private-key PEM file to a given path
  (the private key PEM alone is sufficient — `Crypt::PK::Ed25519->new($path)` can both sign
  and, via `->export_key_pem('public')`, derive the public counterpart; no separate public
  key file is written).

- [ ] **Step 1: Write the failing test**

Create `t/command_generate_signing_key.t`:

```perl
use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use Crypt::PK::Ed25519;

use KohaPluginStore;
use KohaPluginStore::Command::generate_signing_key;

my $dir  = tempdir( CLEANUP => 1 );
my $path = "$dir/signing_key.pem";
my $app  = KohaPluginStore->new;

subtest 'writes a valid Ed25519 keypair to the given path' => sub {
    KohaPluginStore::Command::generate_signing_key->new( app => $app )->run($path);
    ok( -e $path, 'key file was created' );

    my $pk = Crypt::PK::Ed25519->new($path);
    ok( $pk->is_private, 'loaded key is a private key' );
};

subtest 'refuses to overwrite an existing file without --force' => sub {
    my $original_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };

    eval { KohaPluginStore::Command::generate_signing_key->new( app => $app )->run($path) };
    like( $@, qr/already exists/, 'dies with a clear message' );

    my $unchanged_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };
    is( $unchanged_contents, $original_contents, 'the existing key file was not touched' );
};

subtest '--force does overwrite' => sub {
    my $original_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };

    KohaPluginStore::Command::generate_signing_key->new( app => $app )->run( $path, '--force' );

    my $new_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };
    isnt( $new_contents, $original_contents, 'the key file now contains a freshly generated, different key' );
};

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/command_generate_signing_key.t'
```

Expected: FAIL — `KohaPluginStore::Command::generate_signing_key` doesn't exist yet.

- [ ] **Step 3: Implement the command**

Create `lib/KohaPluginStore/Command/generate_signing_key.pm`:

```perl
package KohaPluginStore::Command::generate_signing_key;
use Mojo::Base 'Mojolicious::Command', -signatures;

use Crypt::PK::Ed25519;
use Getopt::Long qw(GetOptionsFromArray);

has description => 'Generate an Ed25519 signing keypair';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $force;
    GetOptionsFromArray( \@args, 'force' => \$force );

    my ($path) = @args;
    die "Usage: script/koha_plugin_store generate_signing_key <path> [--force]\n" unless $path;

    die "$path already exists. Use --force to overwrite.\n" if -e $path && !$force;

    my $pk = Crypt::PK::Ed25519->new;
    $pk->generate_key;

    open my $fh, '>', $path or die "Could not write $path: $!\n";
    print $fh $pk->export_key_pem('private');
    close $fh;

    say "Wrote a new Ed25519 signing keypair to $path";
}

1;

__END__

=encoding utf8

=head1 NAME

KohaPluginStore::Command::generate_signing_key - Generate an Ed25519 signing keypair

=head1 SYNOPSIS

  Usage: APPLICATION generate_signing_key <path> [--force]

  The private key alone is written -- it's sufficient to both sign (this app) and,
  via Crypt::PK::Ed25519->new($path)->export_key_pem('public'), derive the public
  key to bake into a verifier (e.g. Koha-core).

=cut
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS — all 3 subtests succeed.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Command/generate_signing_key.pm t/command_generate_signing_key.t
git commit -m "Add the generate_signing_key command"
```

---

### Task 3: Wire signing into the publish flow

**Files:**
- Modify: `lib/KohaPluginStore/Command/migrate.pm` (new migration 6)
- Modify: `lib/KohaPluginStore/Model/PluginVersion.pm` (`_columns`)
- Modify: `koha_plugin_store.conf.example`, `koha_plugin_store.conf.docker.example`
  (`signing_key_path`)
- Modify: `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`
- Test: `t/task_process_plugin_version.t`

**Interfaces:**
- Consumes: `KohaPluginStore::Signing::build_manifest`/`canonical_json`/`sign` (Task 1).
- Produces: `plugin_versions.signed_manifest` (TEXT), `plugin_versions.signature` (TEXT) —
  both populated only when `status` transitions to `published`, both `NULL` otherwise. App
  config gains `signing_key_path` (a file path).

- [ ] **Step 1: Write the failing tests**

In `t/task_process_plugin_version.t`, add near the top (after the existing `use
KohaPluginStore::Model::ReviewCheck;` line):

```perl
use Crypt::PK::Ed25519;
use JSON qw(decode_json);

use KohaPluginStore::Signing;
```

After the existing `my $t = test_app();` line, add:

```perl
my $signing_keypair  = Crypt::PK::Ed25519->new;
$signing_keypair->generate_key;
my $signing_key_dir  = tempdir( CLEANUP => 1 );
my $signing_key_path = "$signing_key_dir/signing_key.pem";
open my $signing_key_fh, '>', $signing_key_path or die $!;
print $signing_key_fh $signing_keypair->export_key_pem('private');
close $signing_key_fh;
$t->app->config->{signing_key_path} = $signing_key_path;
```

Add these two new subtests before `done_testing();` (do not modify the existing "successful
processing publishes the version" subtest — it has a pre-existing, unrelated failure; see
Global Constraints):

```perl
subtest 'a successfully published version is signed' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $plugin->id,
            tag_name  => 'v1.0.0',
            kpz_url   => 'https://example.com/widget.kpz',
            status    => 'submitted',
        }
    );

    my $fixture_zip = make_kpz($valid_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors        = sub { return []; };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub { return "syntax OK\n" };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    ok( $reloaded->signed_manifest, 'signed_manifest was recorded' );
    ok( $reloaded->signature,       'signature was recorded' );
    ok(
        KohaPluginStore::Signing::verify(
            $reloaded->signed_manifest, $reloaded->signature, $signing_keypair->export_key_pem('public')
        ),
        'the stored signature verifies against the test public key'
    );

    my $manifest = decode_json( $reloaded->signed_manifest );
    is( $manifest->{slug},   $plugin->slug,           'manifest carries the plugin slug' );
    is( $manifest->{digest}, $reloaded->content_digest, 'manifest digest matches the stored content_digest' );
    ok( !exists $manifest->{certification_tier}, 'manifest does not embed the certification tier' );
    ok( !exists $manifest->{level},               'manifest does not embed a level field either' );
};

subtest 'a missing signing key fails the job loudly instead of publishing unsigned' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
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
    *KohaPluginStore::GitHub::fetch_contributors        = sub { return []; };
    *KohaPluginStore::Check::PerlSyntax::_ensure_checkout = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_run_sandboxed   = sub { return "syntax OK\n" };

    my $previous_key_path = $t->app->config->{signing_key_path};
    $t->app->config->{signing_key_path} = "$signing_key_dir/does-not-exist.pem";

    my $job_id = $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $info = $t->app->minion->job($job_id)->info;
    is( $info->{state}, 'failed', 'the Minion job failed rather than silently publishing' );
    like( $info->{result}, qr/Could not read signing key/, 'the failure reason names the signing key problem' );

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    isnt( $reloaded->status, 'published', 'the version was not published' );

    $t->app->config->{signing_key_path} = $previous_key_path;
};
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/task_process_plugin_version.t'
```

Expected: the two new subtests FAIL — `signed_manifest`/`signature` are never populated
today, and there's no `signing_key_path` handling to fail on. The pre-existing "successful
processing publishes the version" subtest also fails, as noted in Global Constraints — that
failure is not new.

- [ ] **Step 3a: Add the migration**

In `lib/KohaPluginStore/Command/migrate.pm`, in the `__DATA__` section, after the existing
`-- 5 down` block (`DROP TABLE review_checks; ALTER TABLE plugin_versions DROP COLUMN
certification_tier;`), add:

```
-- 6 up
ALTER TABLE plugin_versions ADD COLUMN signed_manifest TEXT;
ALTER TABLE plugin_versions ADD COLUMN signature TEXT;

-- 6 down
ALTER TABLE plugin_versions DROP COLUMN signed_manifest;
ALTER TABLE plugin_versions DROP COLUMN signature;
```

- [ ] **Step 3b: Update the model's column list**

In `lib/KohaPluginStore/Model/PluginVersion.pm`, change:

```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier)];
}
```

to:

```perl
sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier signed_manifest signature)];
}
```

- [ ] **Step 3c: Document the new config entry**

In both `koha_plugin_store.conf.example` and `koha_plugin_store.conf.docker.example`, add
after the existing `github_app_token` entry:

```perl
  # Path to the PEM file holding the store's Ed25519 signing private key.
  # Generate one with: script/koha_plugin_store generate_signing_key <path>
  signing_key_path => '/path/to/signing_key.pem',
```

- [ ] **Step 3d: Wire signing into `ProcessPluginVersion`**

In `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`, add to the top `use` block:

```perl
use KohaPluginStore::Signing;
```

Replace the final publish block:

```perl
    $version->update(
        {
            status             => 'published',
            content_digest     => $digest,
            version            => $metadata->{version},
            koha_min_version   => $metadata->{minimum_version},
            certification_tier => $gating_failed ? 'STRUCTURAL' : 'CERTIFIED',
        }
    );
```

with:

```perl
    # Update the in-memory object first (no DB write yet) so build_manifest reads the
    # values this call is about to persist, rather than stale pre-publish data.
    $version->content_digest($digest);
    $version->version( $metadata->{version} );

    my $manifest = KohaPluginStore::Signing::build_manifest( $plugin, $version );
    my $json     = KohaPluginStore::Signing::canonical_json($manifest);

    my $key_path = $app->config->{signing_key_path};
    open my $key_fh, '<', $key_path or die "Could not read signing key at $key_path: $!\n";
    my $private_key_pem = do { local $/; <$key_fh> };
    close $key_fh;

    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );

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

- [ ] **Step 4: Apply the migration, sync, and run the tests to verify they pass**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; perl script/koha_plugin_store migrate'
docker compose restart worker
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/task_process_plugin_version.t'
```

Expected: the two new subtests PASS. The pre-existing "successful processing publishes the
version" subtest still fails for its unrelated reason (Global Constraints) — do not attempt
to fix it.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Command/migrate.pm lib/KohaPluginStore/Model/PluginVersion.pm \
  koha_plugin_store.conf.example koha_plugin_store.conf.docker.example \
  lib/KohaPluginStore/Task/ProcessPluginVersion.pm t/task_process_plugin_version.t
git commit -m "Sign the manifest when a plugin version is published"
```

---

### Task 4: Curate the discovery API's per-version fields

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (`sub list_all`)
- Test: `t/api_plugins.t`

**Interfaces:**
- Consumes: `plugin_versions.signed_manifest`/`signature`/`certification_tier` (Task 3).
- Produces: `GET /api/plugins`'s per-release JSON now has an explicit field list: `name`,
  `tag_name`, `version`, `koha_min_version`, `kpz_url`, `date_released`, `content_digest`,
  `certification_tier`, `author_username`, `author_avatar_url`, `signed_manifest`,
  `signature` — no longer `error_message`/`status`.

- [ ] **Step 1: Write the failing tests**

In `t/api_plugins.t`, change the first `PluginVersion->create` call (the published one) from:

```perl
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id        => $plugin->id,
        version          => '2.5.7',
        koha_min_version => '19.05',
        date_released    => '2024-07-01T15:34:06Z',
        status           => 'published',
    }
);
```

to:

```perl
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id          => $plugin->id,
        version            => '2.5.7',
        koha_min_version   => '19.05',
        date_released      => '2024-07-01T15:34:06Z',
        status             => 'published',
        content_digest     => 'abc123',
        certification_tier => 'CERTIFIED',
        signed_manifest    => '{"digest":"abc123"}',
        signature          => 'fakesignaturebase64==',
        error_message      => 'this must never be exposed publicly',
    }
);
```

Add these two subtests before `done_testing();`:

```perl
subtest 'includes the signing manifest, signature, and certification tier' => sub {
    $t->get_ok('/api/plugins?koha_version_release=20.00')
      ->status_is(200)
      ->json_is( '/0/releases/0/signed_manifest' => '{"digest":"abc123"}' )
      ->json_is( '/0/releases/0/signature' => 'fakesignaturebase64==' )
      ->json_is( '/0/releases/0/certification_tier' => 'CERTIFIED' );
};

subtest 'no longer exposes internal review fields' => sub {
    my $body = $t->get_ok('/api/plugins?koha_version_release=20.00')->tx->res->json;
    ok( !exists $body->[0]{releases}[0]{error_message}, 'error_message is not exposed' );
    ok( !exists $body->[0]{releases}[0]{status},        'status is not exposed' );
};
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/api_plugins.t'
```

Expected: FAIL — `signed_manifest`/`signature` aren't in the response yet, and
`error_message`/`status` still are (since `list_all` still uses a raw `->unblessed` dump).

- [ ] **Step 3: Curate `list_all`'s per-version fields**

In `lib/KohaPluginStore/Controller/Plugins.pm`, replace:

```perl
    my @plugins = map { $_->unblessed } KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;

    foreach my $plugin (@plugins) {
        my @releases =
            map { $_->unblessed } KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
                { plugin_id => $plugin->{id}, status => 'published' }, { order_by => { -desc => 'date_released' } }
            );

        foreach my $release (@releases) {
            next if( $release->{koha_min_version} > $koha_version_release );
            push(
                @{ $plugin->{releases} },
                $release
            );
        }

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }
```

with:

```perl
    my @plugins = map { $_->unblessed } KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;

    foreach my $plugin (@plugins) {
        my @releases = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
            { plugin_id => $plugin->{id}, status => 'published' }, { order_by => { -desc => 'date_released' } }
        );

        foreach my $release (@releases) {
            next if ( $release->koha_min_version > $koha_version_release );
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS on all subtests in the file.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm t/api_plugins.t
git commit -m "Curate the discovery API's per-version fields; expose the signed manifest"
```

---

### Task 5: `GET /api/plugins/verify` digest-lookup endpoint

**Files:**
- Modify: `lib/KohaPluginStore/Controller/Plugins.pm` (new `sub verify`)
- Modify: `lib/KohaPluginStore.pm` (route)
- Test: `t/api_plugins_verify.t`

**Interfaces:**
- Consumes: `plugin_versions.content_digest`/`signed_manifest`/`signature`/
  `certification_tier` (Task 3).
- Produces: `GET /api/plugins/verify?digest=<sha256hex>` → `200` with `{ signed_manifest,
  signature, certification_tier }`, `400` for a malformed digest, `404` if no published
  version has a matching digest.

- [ ] **Step 1: Write the failing tests**

Create `t/api_plugins_verify.t`:

```perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget', { repo_url => 'https://github.com/dev/widget' }
);
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id          => $plugin->id,
        tag_name           => 'v1.0.0',
        version            => '1.0.0',
        status             => 'published',
        content_digest     => 'a' x 64,
        certification_tier => 'CERTIFIED',
        signed_manifest    => '{"digest":"' . ( 'a' x 64 ) . '"}',
        signature          => 'fakesignaturebase64==',
    }
);
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id          => $plugin->id,
        tag_name           => 'v0.9.0',
        version            => '0.9.0',
        status             => 'changes_requested',
        content_digest     => 'b' x 64,
        certification_tier => 'INCOMPLETE',
    }
);

my $t = test_app();

subtest 'rejects a malformed digest' => sub {
    $t->get_ok('/api/plugins/verify?digest=not-a-real-digest')->status_is(400);
};

subtest 'returns 404 for an unknown digest' => sub {
    $t->get_ok( '/api/plugins/verify?digest=' . ( 'f' x 64 ) )->status_is(404);
};

subtest 'returns the signed manifest, signature, and tier for a known published digest' => sub {
    $t->get_ok( '/api/plugins/verify?digest=' . ( 'a' x 64 ) )
      ->status_is(200)
      ->json_is( '/signed_manifest' => '{"digest":"' . ( 'a' x 64 ) . '"}' )
      ->json_is( '/signature' => 'fakesignaturebase64==' )
      ->json_is( '/certification_tier' => 'CERTIFIED' )
      ->header_is( 'Access-Control-Allow-Origin' => '*' );
};

subtest 'returns 404 for a digest belonging to a non-published version' => sub {
    $t->get_ok( '/api/plugins/verify?digest=' . ( 'b' x 64 ) )->status_is(404);
};

done_testing();
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/api_plugins_verify.t'
```

Expected: FAIL — the route doesn't exist yet (every request 404s, including the ones
expecting 400/200).

- [ ] **Step 3a: Add the controller action**

In `lib/KohaPluginStore/Controller/Plugins.pm`, add after `sub list_all`:

```perl
sub verify ($c) {
    my $digest = $c->param('digest') // '';

    $c->res->headers->header( 'Access-Control-Allow-Origin'  => '*' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type,x-koha-request-id' );
    $c->res->headers->header( 'Access-Control-Allow-Methods' => 'get,options' );

    return $c->render( text => 'digest must be a 64-character sha256 hex string', status => 400 )
        unless $digest =~ /^[0-9a-f]{64}$/i;

    my ($version) = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { content_digest => $digest, status => 'published' }, { order_by => { -desc => 'id' }, limit => 1 }
    );

    return $c->render( text => 'no signed version found for this digest', status => 404 ) unless $version;

    return $c->render(
        json => {
            signed_manifest    => $version->signed_manifest,
            signature          => $version->signature,
            certification_tier => $version->certification_tier,
        },
        status => 200,
    );
}
```

- [ ] **Step 3b: Add the route**

In `lib/KohaPluginStore.pm`, add immediately after the existing
`$r->any('/api/plugins')->to('plugins#list_all');` line:

```perl
    $r->get('/api/plugins/verify')->to('plugins#verify');
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS on all subtests.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Controller/Plugins.pm lib/KohaPluginStore.pm t/api_plugins_verify.t
git commit -m "Add GET /api/plugins/verify for digest-based signature lookup"
```

---

### Task 6: UI legibility — signing vs. certification tier

**Files:**
- Modify: `templates/plugins/show.html.ep`
- Modify: `templates/site/index.html.ep`
- Test: `t/plugins_show.t`, `t/site.t`

**Interfaces:**
- Consumes: `$version->signature` (Task 3) — a version's presence of a non-`NULL` signature
  is the "is this signed" fact; no controller change needed, since `_plugin_page_stash`
  already stashes full `PluginVersion` objects whose columns already include `signature` via
  `AUTOLOAD` once Task 3's migration lands.

- [ ] **Step 1: Write the failing tests**

In `t/plugins_show.t`, add this subtest before `done_testing();`:

```perl
subtest 'a published version shows a Signed badge and the explanatory copy; a non-published one does not' => sub {
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
        {
            plugin_id       => $plugin->id,
            tag_name        => 'v1.0.0',
            status          => 'published',
            signed_manifest => '{"slug":"widget"}',
            signature       => 'fakesignature==',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.1.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/Signed/)
      ->content_like(qr/confirms the file hasn't been altered/i);

    $t->get_ok('/logout');
};
```

In `t/site.t`, add this subtest before `done_testing();`:

```perl
subtest 'sets expectations about signing and certification tier before a first submission' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->content_like(qr/signed automatically/i)
      ->content_like(qr/certification tier/i);
};
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/plugins_show.t t/site.t'
```

Expected: FAIL — neither template mentions signing yet.

- [ ] **Step 3a: Add the Signed badge and explanatory copy to the show page**

In `templates/plugins/show.html.ep`, find the Releases tab's versions table. It has a
`<thead>` row with `<th>Tag</th><th>Version</th><th>Status</th><th>Certification</th>
<th>Checks</th>` and a `<tbody>` loop building one `<tr>` per version, with a `<td>` for the
certification badge shaped like:

```
<td>
  % if ($version->certification_tier) {
    <span class="badge <%= $tier_badge{$version->certification_tier} || 'text-bg-secondary' %>"><%= $version->certification_tier %></span>
  % }
</td>
```

Add a new `<th>Signed</th>` column header immediately after `<th>Certification</th>`, and a
new `<td>` cell immediately after that certification `<td>`, in the same per-version loop:

```
<td>
  % if ($version->signature) {
    <span class="badge text-bg-info">Signed</span>
  % }
</td>
```

Immediately after the closing `</table>` of this same versions table, add:

```
<p class="text-muted small">
  Every published version is signed automatically — this confirms the file hasn't been
  altered since the store inspected it. It is not a safety or quality check; see each
  version's certification badge for that.
</p>
```

- [ ] **Step 3b: Add the home page blurb**

In `templates/site/index.html.ep`, find the logged-out branch's `<h3>How to join</h3>` numbered
list:

```
  <h3>How to join</h3>
  <ol>
    <li>Log in with your GitHub account.</li>
    <li>Pick one of your public repositories that contains a Koha plugin.</li>
    <li>Choose a tagged release to submit.</li>
  </ol>
```

Add immediately after the closing `</ol>`, before the `<p>` containing the GitHub login
button:

```
  <p>
    Once submitted, your release is signed automatically the moment it publishes — that
    confirms the file's integrity, not an endorsement of it. It also gets a certification
    tier reflecting how much automated (and eventually human) scrutiny it's had so far,
    which can rise later as review capacity allows.
  </p>
```

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS on all subtests in both files, and all pre-existing
subtests in both files still pass.

- [ ] **Step 5: Commit**

```bash
git add templates/plugins/show.html.ep templates/site/index.html.ep t/plugins_show.t t/site.t
git commit -m "Show signing status as a fact separate from certification tier"
```

---

### Task 7: Full-suite verification, docs, and stray-reference check

**Files:**
- Modify: `CLAUDE.md` (architecture notes)
- Modify: `README.md` (config docs, if it documents `koha_plugin_store.conf` entries)

**Interfaces:** none — this task confirms Tasks 1–6 integrate cleanly and documents the new
mechanism.

- [ ] **Step 1: Run the full test suite**

```bash
docker compose restart worker
docker compose exec -T app bash -lc 'export PERL5LIB=$(pwd)/local/lib/perl5; export KOHA_PLUGIN_STORE_TEST_DSN="postgresql://koha_plugin_store:koha_plugin_store@postgres:5432/koha_plugin_store"; prove -l t/'
```

Expected: every file passes except `t/task_process_plugin_version.t` (the pre-existing,
unrelated failure named in Global Constraints — confirm it's still exactly that one failing
subtest, not a new one) and `t/login.t` if present (already documented elsewhere as stale). If
any *other* file fails, that's a real regression from Tasks 1–6 and must be root-caused
before continuing.

- [ ] **Step 2: Document the signing mechanism in `CLAUDE.md`**

In `CLAUDE.md`, in the "Plugin submission workflow" section, immediately after the existing
bullet describing `content_digest` computation (the line ending "...sets the version's
`status` to `published` or `changes_requested` (with `error_message`) accordingly."), add:

```
4. On publish, `KohaPluginStore::Signing` builds and signs a small manifest (`slug`,
   `version`, `kpz_url`, `digest`, `published_at`) with the store's Ed25519 key
   (`koha_plugin_store.conf`'s `signing_key_path`, generated via `script/koha_plugin_store
   generate_signing_key`), storing both the exact signed JSON string
   (`plugin_versions.signed_manifest`) and the signature (`signature`) verbatim.
   `certification_tier` is deliberately excluded from the signed content -- it's a
   separate, re-assessable quality claim, exposed alongside the signature rather than
   frozen inside it, so a later re-certification never needs a re-sign.
5. `GET /api/plugins/verify?digest=<sha256hex>` looks up a published version by its
   `content_digest` and returns `{ signed_manifest, signature, certification_tier }` --
   this is how a Koha instance verifies a manually-uploaded `.kpz` (which has no
   `kpz_url` to match against the discovery listing), not just ones fetched via the
   discovery client.
```

- [ ] **Step 3: Check the README documents the new config entry**

```bash
grep -n "koha_plugin_store.conf.example\|github_app_token" README.md
```

If the README enumerates `koha_plugin_store.conf`'s keys (matching how it already documents
`github_app_token`/`pg_dsn`/`oauth_providers`), add `signing_key_path` to that list with the
same one-line description used in Step 3c of Task 3. If the README doesn't enumerate config
keys individually, no change is needed here.

- [ ] **Step 4: Confirm no other test file depends on the old raw-dump API shape**

```bash
grep -rln "api/plugins" t/ --include='*.t'
```

Expected: only `t/api_plugins.t` (already updated in Task 4). If any other file appears,
open it and check whether it asserts on `error_message` or `status` in a response from this
endpoint — if so, that assertion depends on the shape this plan just removed and needs
updating to match Task 4's curated field list.

- [ ] **Step 5: Commit any documentation/cleanup changes**

```bash
git add CLAUDE.md README.md
git commit -m "Document the signing mechanism and the verify endpoint"
```
