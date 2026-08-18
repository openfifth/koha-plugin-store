use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::backfill_koha_versions;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );

my $good = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    { plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', koha_min_version => '23.11' }
);
my $bad = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    { plugin_id => $plugin->id, version => '2.0.0', tag_name => 'v2', koha_min_version => 'not-a-version' }
);

my $app = KohaPluginStore->new;
$app->pg( test_pg() );

KohaPluginStore::Command::backfill_koha_versions->new( app => $app )->run;

my $reloaded_good = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $good->id } );
my $reloaded_bad  = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { id => $bad->id } );

is( $reloaded_good->koha_min_version, '23.11.00.000', 'a parseable value is normalized in place' );
is( $reloaded_bad->koha_min_version, 'not-a-version', 'an unparseable value is left untouched' );

done_testing();
