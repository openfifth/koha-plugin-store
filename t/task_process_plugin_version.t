use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use File::Temp qw(tempdir);
use File::Copy 'copy';
use Archive::Zip;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

sub make_kpz {
    my ($plugin_pm_contents) = @_;
    my $dir      = tempdir( CLEANUP => 1 );
    my $zip_path = "$dir/fixture.kpz";
    my $zip      = Archive::Zip->new;
    $zip->addString( $plugin_pm_contents, 'Widget.pm' );
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

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is published' );
    ok( $reloaded->content_digest, 'content_digest was computed' );
    is( $reloaded->koha_min_version, '23.05', 'koha_min_version parsed from metadata' );

    my $reloaded_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded_plugin->name, 'Widget', 'plugin name populated from metadata' );
    is( $reloaded_plugin->class_name, 'Koha::Plugin::Test::Widget', 'class_name populated' );

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
    $t->app->minion->perform_jobs;

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

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

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

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'changes_requested', 'status is changes_requested' );
    like( $reloaded->error_message, qr/minimum_version/, 'error message names the missing field' );
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

    $t->app->minion->enqueue( process_plugin_version => [ $version->id ] );
    $t->app->minion->perform_jobs;

    my $reloaded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $version->id } );
    is( $reloaded->status, 'published', 'status is still published despite the contributors fetch failing' );
};

done_testing();
