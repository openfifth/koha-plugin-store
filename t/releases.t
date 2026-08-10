use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '1', username => 'owner' }
);
my $other = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '2', username => 'other' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'coverflow', { name => 'CoverFlow', repo_url => 'https://github.com/owner/coverflow', developer_id => $owner->id }
);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );
$t->app->plugin( Minion => { Pg => test_pg() } );

my $profile_to_return;
{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 'fake-token' } );
    };
    *KohaPluginStore::Controller::Auth::_fetch_github_profile = sub {
        return $profile_to_return;
    };
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author => { login => 'owner', avatar_url => 'https://example.com/a.png' },
            assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };
}

sub login_as {
    my ($developer) = @_;
    $profile_to_return = {
        id         => $developer->provider_user_id,
        login      => $developer->username,
        avatar_url => $developer->avatar_url,
    };
    $t->get_ok('/auth/github')->status_is(302);
}

subtest 'anonymous cannot submit a release' => sub {
    $t->get_ok('/logout');
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )->status_is(404); # existing #TODO: should be 401
};

subtest 'a different developer cannot submit a release for someone else\'s plugin' => sub {
    login_as($other);
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )->status_is(401);
};

subtest 'the owning developer can submit a release' => sub {
    login_as($owner);
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )
      ->status_is(302)
      ->header_is( Location => '/plugins/coverflow' );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0' }
    );
    is( $version->status, 'submitted', 'version created with submitted status' );

    my $job_count = $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total;
    is( $job_count, 1, 'a process_plugin_version job was enqueued' );
};

subtest 'submitting the same tag again is rejected' => sub {
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id, tag_name => 'v1.0.0' } )->status_is(409);
};

done_testing();
