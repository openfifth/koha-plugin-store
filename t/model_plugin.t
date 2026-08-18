use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

subtest 'plugin releases returns its versions' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, version => '2.5.7', tag_name => 'v2.5.7' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, version => '2.5.8', tag_name => 'v2.5.8' }
    );

    my $versions = $plugin->releases;
    is( scalar @$versions, 2, 'both versions returned' );
    is( ( sort map { $_->version } @$versions )[0], '2.5.7', 'version accessor works on the related object' );
};

subtest 'create_with_unique_slug normalizes the source string' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'Koha_Plugin!! Coverflow', { repo_url => 'https://github.com/a/coverflow' }
    );
    is( $plugin->slug, 'koha-plugin-coverflow', 'non-alphanumeric runs collapse to single hyphens' );
};

subtest 'create_with_unique_slug retries on collision' => sub {
    reset_db();
    my $first = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'My Plugin', { repo_url => 'https://github.com/a/my-plugin' }
    );
    is( $first->slug, 'my-plugin', 'first submission gets the plain slug' );

    my $second = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'My Plugin', { repo_url => 'https://github.com/b/my-plugin' }
    );
    is( $second->slug, 'my-plugin-2', 'second submission with the same base gets a suffixed slug' );

    my $third = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'My Plugin', { repo_url => 'https://github.com/c/my-plugin' }
    );
    is( $third->slug, 'my-plugin-3', 'third submission gets the next suffix' );
};

subtest 'search_compatible filters by koha_version, q, and paginates' => sub {
    reset_db();
    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'CoverFlow', description => 'A widget' }
    );
    my $reportkit = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'ReportKit', description => 'Reporting tools' }
    );
    my $unpublished = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'DraftOnly', description => 'Nothing published yet' }
    );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $coverflow->id, version => '1.0.0', tag_name => 'v1',
            status => 'published', koha_min_version => '23.11.00.000',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $reportkit->id, version => '1.0.0', tag_name => 'v1',
            status => 'published', koha_min_version => '25.11.00.000',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $unpublished->id, version => '1.0.0', tag_name => 'v1',
            status => 'submitted', koha_min_version => '23.11.00.000',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    my $compatible = $model->search_compatible(
        { koha_version => '24.05.00.000', order_by => 'name', limit => 10, offset => 0 }
    );
    is( scalar @$compatible, 1, 'only the plugin whose sole release is old enough is returned' );
    is( $compatible->[0]->name, 'CoverFlow', 'CoverFlow (23.11) is compatible with 24.05' );

    my $both = $model->search_compatible(
        { koha_version => '26.00.00.000', order_by => 'name', limit => 10, offset => 0 }
    );
    is( scalar @$both, 2, 'both published, compatible plugins are returned for a later Koha version' );
    is( $both->[0]->name, 'CoverFlow', 'ordered by name ascending' );
    is( $both->[1]->name, 'ReportKit', 'ordered by name ascending' );

    my $filtered = $model->search_compatible(
        { koha_version => '26.00.00.000', q => 'report', order_by => 'name', limit => 10, offset => 0 }
    );
    is( scalar @$filtered, 1, 'q filters by name/description substring, case-insensitively' );
    is( $filtered->[0]->name, 'ReportKit', 'the matching plugin is returned' );

    is(
        $model->count_compatible( { koha_version => '26.00.00.000' } ), 2,
        'count_compatible matches search_compatible\'s filter, ignoring pagination'
    );
};

subtest 'search_compatible respects koha_max_version as an upper bound' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'OldPlugin' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000', koha_max_version => '23.00.00.000',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    is(
        scalar @{ $model->search_compatible( { koha_version => '22.00.00.000', limit => 10, offset => 0 } ) }, 1,
        'a version within [min, max] is compatible'
    );
    is(
        scalar @{ $model->search_compatible( { koha_version => '24.00.00.000', limit => 10, offset => 0 } ) }, 0,
        'a version above koha_max_version is excluded'
    );
};

subtest 'search_compatible treats a null koha_max_version as no ceiling' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'ForeverPlugin' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    is(
        scalar @{ $model->search_compatible( { koha_version => '99.00.00.000', limit => 10, offset => 0 } ) }, 1,
        'a plugin with no koha_max_version stays compatible with a far-future version'
    );
};

subtest 'search_compatible sorts by author' => sub {
    reset_db();
    my $zeta = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'Zeta', author => 'Zed Author' }
    );
    my $alpha = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'Alpha', author => 'Ada Author' }
    );
    for my $plugin ( $zeta, $alpha ) {
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            {
                plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1',
                status => 'published', koha_min_version => '20.00.00.000',
            }
        );
    }

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    my $asc = $model->search_compatible(
        { koha_version => '24.00.00.000', order_by => 'author', limit => 10, offset => 0 }
    );
    is( $asc->[0]->name, 'Alpha', 'author ASC: Ada Author sorts before Zed Author' );
    is( $asc->[1]->name, 'Zeta', 'author ASC: Zeta is second' );

    my $desc = $model->search_compatible(
        { koha_version => '24.00.00.000', order_by => '-author', limit => 10, offset => 0 }
    );
    is( $desc->[0]->name, 'Zeta', 'author DESC: Zed Author sorts first' );
    is( $desc->[1]->name, 'Alpha', 'author DESC: Alpha is second' );
};

subtest 'search_compatible sorts by most-recently-updated, using the latest compatible release per plugin' => sub {
    reset_db();
    my $stale = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'StalePlugin' } );
    my $fresh = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'FreshPlugin' } );

    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $stale->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000', date_released => '2020-01-01T00:00:00Z',
        }
    );

    # FreshPlugin has an older release AND a newer one -- the newer one must win the sort,
    # not an arbitrary row picked from the join.
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $fresh->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000', date_released => '2019-01-01T00:00:00Z',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $fresh->id, version => '2.0.0', tag_name => 'v2', status => 'published',
            koha_min_version => '20.00.00.000', date_released => '2025-01-01T00:00:00Z',
        }
    );

    my $model = KohaPluginStore::Model::Plugin->new( pg => test_pg() );

    my $desc = $model->search_compatible(
        { koha_version => '24.00.00.000', order_by => '-updated', limit => 10, offset => 0 }
    );
    is( $desc->[0]->name, 'FreshPlugin', "FreshPlugin's 2025 release outranks StalePlugin's 2020 one" );
    is( $desc->[1]->name, 'StalePlugin', 'StalePlugin is second' );

    my $asc = $model->search_compatible(
        { koha_version => '24.00.00.000', order_by => 'updated', limit => 10, offset => 0 }
    );
    is( $asc->[0]->name, 'StalePlugin', "ascending: StalePlugin (2020) sorts before FreshPlugin (2025, via its newest release)" );
    is( $asc->[1]->name, 'FreshPlugin', 'FreshPlugin is second ascending' );
};

done_testing();
