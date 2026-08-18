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

subtest 'for_plugin_ids batch-fetches published, compatible releases for exactly the given plugins' => sub {
    reset_db();
    my $a = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'A' } );
    my $b = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'B' } );
    my $c = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'C' } );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $a->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $a->id, version => '2.0.0', tag_name => 'v2', status => 'submitted', koha_min_version => '20.00.00.000' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $b->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $c->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
    );

    my $versions = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )
        ->for_plugin_ids( [ $a->id, $b->id ], { koha_version => '24.00.00.000' } );

    is( scalar @$versions, 2, 'only published releases for the requested plugin ids are returned' );
    my @plugin_ids = sort map { $_->plugin_id } @$versions;
    is_deeply( \@plugin_ids, [ sort ( $a->id, $b->id ) ], 'exactly A and B, not C' );
};

subtest 'for_plugin_ids returns an empty arrayref for an empty id list' => sub {
    reset_db();
    is_deeply(
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->for_plugin_ids( [], { koha_version => '24.00.00.000' } ),
        [], 'no query is attempted, just an empty result'
    );
};

done_testing();
