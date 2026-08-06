use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB;

my $t = Test::Mojo->new('KohaPluginStore');

subtest 'ping responds per the OpenAPI spec' => sub {
    $t->get_ok('/api/v1/ping')
      ->status_is(200)
      ->json_is( '/status' => 'ok' );
};

subtest 'undefined operations are rejected by the router' => sub {
    $t->post_ok('/api/v1/ping')->status_is(404);
};

done_testing();
