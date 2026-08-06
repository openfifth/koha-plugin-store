use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => '1', username => 'seeder' }
);
my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'CoverFlow', description => 'A widget', developer_id => $developer->id }
);
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id        => $plugin->id,
        version          => '2.5.7',
        koha_min_version => '19.05',
        date_released    => '2024-07-01T15:34:06Z',
    }
);

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'requires koha_version_release' => sub {
    $t->get_ok('/api/plugins')->status_is(400);
};

subtest 'lists the seeded plugin and its compatible release' => sub {
    $t->get_ok('/api/plugins?koha_version_release=20.00')
      ->status_is(200)
      ->json_is( '/0/name' => 'CoverFlow' )
      ->json_is( '/0/releases/0/version' => '2.5.7' )
      ->header_is( 'Access-Control-Allow-Origin' => '*' );
};

done_testing();
