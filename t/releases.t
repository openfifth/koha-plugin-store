use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

reset_db();

my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '1', username => 'owner' }
);
my $other = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '2', username => 'other' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'CoverFlow', developer_id => $owner->id }
);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

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
    $t->post_ok( '/new-release' => form => { plugin_id => $plugin->id } )->status_is(404); # existing #TODO: should be 401
};

subtest 'a different developer cannot submit a release for someone else\'s plugin' => sub {
    login_as($other);
    $t->post_ok(
        '/new-release' => form => {
            plugin_id                         => $plugin->id,
            release_metadata_version          => '1.0.0',
            release_metadata_koha_min_version => '19.05',
        }
    )->status_is(401);
};

subtest 'the owning developer can submit a release' => sub {
    login_as($owner);
    $t->post_ok(
        '/new-release' => form => {
            plugin_id                         => $plugin->id,
            release_metadata_version          => '1.0.0',
            release_metadata_koha_min_version => '19.05',
        }
    )->status_is(200);
};

done_testing();
