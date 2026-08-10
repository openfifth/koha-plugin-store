use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

reset_db();

my $t = test_app();

subtest 'GitHub login with oauth_mock enabled bypasses OAuth2 handshake' => sub {
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github')->status_is(302)->header_is( Location => '/my-plugins' );

    # Verify that a developer row was created with mockdev username
    my $developers = $t->app->pg->db->select( 'developers', ['username'] )->arrays->to_array;
    my @usernames = map { $_->[0] } @$developers;
    ok( grep( { $_ eq 'mockdev' } @usernames ), 'mockdev developer was created' );

    # Clean up for subsequent tests
    $t->app->config->{oauth_mock} = 0;
    reset_db();
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 'fake-token' } );
    };
    *KohaPluginStore::Controller::Auth::_fetch_github_profile = sub {
        return { id => '4242', login => 'octocat', avatar_url => 'https://example.com/o.png' };
    };
}

subtest 'GitHub login creates a developer and logs them in' => sub {
    $t->get_ok('/auth/github')->status_is(302)->header_is( Location => '/my-plugins' );
};

subtest 'log_in_developer stores only the id in session, not the whole row' => sub {
    $t->app->routes->get(
        '/__test/session_developer' => sub {
            my $c = shift;
            return $c->render( json => { session_developer => $c->session->{developer} } );
        }
    );

    $t->get_ok('/__test/session_developer')->status_is(200);
    my $session_developer = $t->tx->res->json('/session_developer');
    is_deeply( [ sort keys %$session_developer ], ['id'], 'only id is stored, nothing else' );
};

subtest 'GitHub login stores the access token in session for later API calls' => sub {
    $t->app->routes->get('/__test/session_token' => sub {
        my $c = shift;
        return $c->render( json => { token => $c->session->{github_access_token} } );
    });

    $t->get_ok('/__test/session_token')->status_is(200)->json_is( '/token' => 'fake-token' );
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 0 } );
    };
}

subtest 'GitHub login rejects when user denies authorization' => sub {
    $t->get_ok('/auth/github')->status_is(400);
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Controller::Auth::_get_oauth_token_p = sub {
        return Mojo::Promise->resolve( { access_token => 'fake-token' } );
    };
    *KohaPluginStore::Controller::Auth::_fetch_github_profile = sub {
        return { id => '4242', login => 'octocat', avatar_url => 'https://example.com/o.png' };
    };
}

subtest 'my-plugins requires login' => sub {
    $t->get_ok('/logout')->status_is(302);
    $t->get_ok('/my-plugins')->status_is(404); # existing #TODO in the app: this should be 401
};

done_testing();
