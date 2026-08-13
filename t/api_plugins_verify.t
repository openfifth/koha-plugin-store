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
