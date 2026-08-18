use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

subtest 'koha_max_version round-trips through create/find, defaults to undef' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, version => '1.0.0', koha_min_version => '23.11.00.000' }
    );
    is( $version->koha_max_version, undef, 'koha_max_version defaults to undef when not given' );

    my $bounded = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id        => $plugin->id,
            version          => '2.0.0',
            tag_name         => 'v2.0.0',
            koha_min_version => '23.11.00.000',
            koha_max_version => '25.05.00.000',
        }
    );
    is( $bounded->koha_max_version, '25.05.00.000', 'koha_max_version round-trips when given' );
};

done_testing();
