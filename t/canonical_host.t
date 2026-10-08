use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app);

reset_db();

my $t = test_app();
$t->ua->max_redirects(0);

# Unset: every Host is served as-is.
$t->get_ok( '/', { Host => 'old.example.org' } )->status_is(200);

$t->app->config->{canonical_host} = 'new.example.org';

$t->get_ok( '/', { Host => 'new.example.org' } )->status_is(200);
$t->get_ok( '/', { Host => 'NEW.example.org' } )->status_is(200);

$t->get_ok( '/plugins/foo?x=1&y=2', { Host => 'old.example.org' } )
    ->status_is(301)
    ->header_is( Location => 'https://new.example.org/plugins/foo?x=1&y=2' );

$t->head_ok( '/', { Host => 'old.example.org' } )->status_is(301);

# Non-idempotent requests keep their method via 308.
$t->post_ok( '/anything', { Host => 'old.example.org' } )
    ->status_is(308)
    ->header_is( Location => 'https://new.example.org/anything' );

# A non-default port on the old host doesn't leak into the redirect.
$t->get_ok( '/api/plugins', { Host => 'old.example.org:8443' } )
    ->status_is(301)
    ->header_is( Location => 'https://new.example.org/api/plugins' );

done_testing();
