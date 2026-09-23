use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use File::Temp qw(tempdir);
use File::Copy 'copy';
use Archive::Zip;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;
use KohaPluginStore::Model::ReviewCheck;

use Crypt::PK::Ed25519;
use JSON qw(decode_json);

use KohaPluginStore::Signing;

reset_db();

my $t = test_app();

my $signing_keypair  = Crypt::PK::Ed25519->new;
$signing_keypair->generate_key;
my $signing_key_dir  = tempdir( CLEANUP => 1 );
my $signing_key_path = "$signing_key_dir/signing_key.pem";
open my $signing_key_fh, '>', $signing_key_path or die $!;
print $signing_key_fh $signing_keypair->export_key_pem('private');
close $signing_key_fh;
$t->app->config->{signing_key_path} = $signing_key_path;

sub make_kpz {
    my ($plugin_pm_contents) = @_;
    my $dir      = tempdir( CLEANUP => 1 );
    my $zip_path = "$dir/fixture.kpz";
    my $zip      = Archive::Zip->new;
    $zip->addString( $plugin_pm_contents, 'Widget.pm' );
    $zip->writeToFileNamed($zip_path);
    return $zip_path;
}

sub make_multi_file_kpz {
    my ($files) = @_;
    my $dir      = tempdir( CLEANUP => 1 );
    my $zip_path = "$dir/fixture.kpz";
    my $zip      = Archive::Zip->new;
    $zip->addString( $files->{$_}, $_ ) for keys %$files;
    $zip->writeToFileNamed($zip_path);
    return $zip_path;
}

my $valid_plugin_pm = <<'PERL';
package Koha::Plugin::Test::Widget;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name => 'Widget',
    description => 'A test widget',
    author => 'Someone',
    minimum_version => '23.05',
    version => '1.0.0',
    license => 'GPL-3.0',
};
1;
PERL

subtest 'successful processing publishes the version' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $developer->id }
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
    *KohaPluginStore::GitHub::fetch_contributors = sub {
        return [ { github_username => 'octocat', avatar_url => 'https://example.com/a.png', contributions_count => 5 } ];
    };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files    = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    ok( $reloaded->content_digest, 'content_digest was computed' );
    is( $reloaded->koha_min_version, '23.05.00.000', 'koha_min_version is normalized from metadata' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->name, 'Widget', 'plugin name populated from metadata' );
    is( $reloaded_plugin->class_name, 'Koha::Plugin::Test::Widget', 'class_name populated' );
    is( $reloaded_plugin->author, 'Someone', 'author populated from metadata' );

    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => test_pg() )->search(
        { plugin_id => $plugin->id }
    );
    is( scalar @contributors, 1, 'one contributor recorded' );
    is( $contributors[0]->github_username, 'octocat', 'contributor username recorded' );
};

subtest 'download failure sets changes_requested with a specific message' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub { return 0 };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/not be publicly accessible/, 'error message explains the likely cause' );
};

subtest 'a zip with no plugin class file sets changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_kpz("package Not::A::Plugin;\n1;\n");

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/class file not found/, 'error message names the problem' );
};

subtest 'missing minimum_version sets changes_requested' => sub {
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
our $metadata = { name => 'Widget' };
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
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/minimum_version/, 'error message names the missing field' );
};

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
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    is( $reloaded->koha_min_version, '23.11.00.000', 'minimum_version is normalized' );
    is( $reloaded->koha_max_version, '25.05.00.000', 'maximum_version is normalized' );
};

subtest 'a contributors fetch failure does not block publishing' => sub {
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
    *KohaPluginStore::GitHub::fetch_contributors = sub { die 'GitHub is down' };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files    = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is still published despite the contributors fetch failing' );
};

subtest 'a fully compliant version reaches CERTIFIED' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    maximum_version => '23.11',
    version         => '1.0.0',
    license         => 'GPL-3.0',
};
1;
PERL
            'Development.md'   => "# Development\n",
            't/basic.t'         => "use Test::More;\nok(1);\ndone_testing();\n",
            'templates/page.tt' => "[% INCLUDE 'doc-head-close.inc' %]\n<h1>[% t('Hello') %]</h1>\n",
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_verification       = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files     = sub { return 1 };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    is( $reloaded->certification_tier, 'CERTIFIED', 'certification_tier is CERTIFIED' );

    my @checks = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->search( { plugin_version_id => $version->id }, { limit => 100 } );
    is( scalar @checks, 11, 'a review_checks row was recorded for every check' );
    is( scalar( grep { $_->passed } @checks ), 10, 'every check passed except the non-gating GPG signature check' );
};

subtest 'passing only required checks reaches STRUCTURAL' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    version         => '1.0.0',
    license         => 'GPL-3.0',
};
1;
PERL
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_verification       = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files     = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    is( $reloaded->certification_tier, 'STRUCTURAL', 'certification_tier is STRUCTURAL, not CERTIFIED' );
};

subtest 'failing a required check reaches INCOMPLETE and never publishes' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    version         => '1.0.0',
};
1;
PERL
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::GitHub::fetch_tag_verification       = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files     = sub { return 0 };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    is( $reloaded->certification_tier, 'INCOMPLETE', 'certification_tier is INCOMPLETE' );

    my $manifest_check = KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->find(
        { plugin_version_id => $version->id, check_name => 'manifest_completeness' }
    );
    ok( !$manifest_check->passed, 'the manifest_completeness check row records the failure' );
};

subtest 'a sandbox infrastructure failure sets check_error, not changes_requested' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm' => <<'PERL',
package Widget;
use Modern::Perl;
use base qw(Koha::Plugins::Base);
our $metadata = {
    name            => 'Widget',
    description     => 'A test widget',
    author          => 'Someone',
    minimum_version => '23.05',
    version         => '1.0.0',
    license         => 'GPL-3.0',
};
1;
PERL
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors = sub { return [] };
    *KohaPluginStore::Check::PerlSyntax::_call_broker =
        sub { die "check_infrastructure_error: sandbox broker request failed: unreachable\n" };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'check_error', 'status is check_error, not changes_requested' );
};

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
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

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
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

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

subtest 'malicious metadata code is never executed, only ignored' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $marker_dir  = tempdir( CLEANUP => 1 );
    my $marker_file = "$marker_dir/pwned";

    my $evil_plugin_pm = <<PERL;
package Koha::Plugin::Test::Evil;
use base qw(Koha::Plugins::Base);
our \$metadata = {
    name            => do { system('touch', '$marker_file'); 'Evil' },
    description     => 'x',
    author          => 'x',
    minimum_version => '23.05',
    version         => '1.0.0',
};
1;
PERL
    my $fixture_zip = make_kpz($evil_plugin_pm);

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    ok( !-e $marker_file, 'the system() call embedded in the metadata never ran' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->name, undef, "the 'name' field, whose value wasn't a plain literal, was dropped rather than executed" );
};

subtest 'a Zip Slip path in the .kpz is rejected rather than extracted outside the sandbox' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', kpz_url => 'https://example.com/widget.kpz', status => 'submitted' }
    );

    my $fixture_zip = make_multi_file_kpz(
        {
            'Widget.pm'          => $valid_plugin_pm,
            '../../escaped.conf' => "malicious content\n",
        }
    );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::download_kpz = sub {
        my ( $token, $url, $dest_path ) = @_;
        copy( $fixture_zip, $dest_path ) or die "copy failed: $!";
        return 1;
    };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/unsafe path/, 'error message names the problem' );
};

subtest 'a comment containing an apostrophe inside the metadata block does not break parsing' => sub {
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
    name => 'Widget', # don't break this
    description => "A test widget",
    author => "Someone",
    minimum_version => '23.05',
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
    *KohaPluginStore::GitHub::fetch_contributors           = sub { return [] };
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published despite the comment containing an apostrophe' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->name, 'Widget', 'metadata after the commented field still parsed correctly' );
};

subtest 'successful processing fetches and stores the README HTML' => sub {
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
    *KohaPluginStore::GitHub::fetch_contributors      = sub { return []; };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_readme_html        = sub { return '<h1>Widget</h1>'; };
    *KohaPluginStore::Check::PerlSyntax::_call_broker  = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->readme_html, '<h1>Widget</h1>', 'readme_html populated from the README fetch' );
};

subtest 'a failed README fetch does not fail processing and leaves any existing readme_html untouched' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $developer->id, readme_html => '<p>Old readme</p>' }
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
    *KohaPluginStore::GitHub::fetch_contributors      = sub { return []; };
    *KohaPluginStore::GitHub::fetch_tag_has_test_files = sub { return 0 };
    *KohaPluginStore::GitHub::fetch_readme_html        = sub { die "network error\n" };
    *KohaPluginStore::Check::PerlSyntax::_call_broker  = sub { return { passed => 1, message => undef } };

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs_in_foreground;

    my $reloaded_version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded_version->status, 'published', 'processing still succeeds despite the README fetch dying' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->readme_html, '<p>Old readme</p>', 'prior readme_html is left untouched, not wiped' );
};

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

done_testing();
