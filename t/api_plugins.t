use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

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
        plugin_id          => $plugin->id,
        version            => '2.5.7',
        koha_min_version   => '19.05',
        date_released      => '2024-07-01T15:34:06Z',
        status             => 'published',
        content_digest     => 'abc123',
        certification_tier => 'CERTIFIED',
        signed_manifest    => '{"digest":"abc123"}',
        signature          => 'fakesignaturebase64==',
        error_message      => 'this must never be exposed publicly',
    }
);
KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
    {
        plugin_id        => $plugin->id,
        version          => '2.6.0',
        koha_min_version => '19.05',
        date_released    => '2024-08-01T15:34:06Z',
        status           => 'changes_requested',
    }
);

my $t = test_app();

subtest 'requires koha_version' => sub {
    $t->get_ok('/api/v1/plugins')->status_is(400);
};

subtest 'lists the seeded plugin and its compatible published release' => sub {
    $t->get_ok('/api/v1/plugins?koha_version=20.00')
      ->status_is(200)
      ->json_is( '/0/name' => 'CoverFlow' )
      ->json_is( '/0/releases/0/version' => '2.5.7' )
      ->header_is( 'Access-Control-Allow-Origin' => '*' );
};

subtest 'excludes a non-published release for the same plugin' => sub {
    my $body = $t->get_ok('/api/v1/plugins?koha_version=20.00')->tx->res->json;
    my @versions = map { $_->{version} } @{ $body->[0]{releases} };
    ok( !( grep { $_ eq '2.6.0' } @versions ), 'the changes_requested release is not exposed' );
};

subtest 'includes the signing manifest, signature, and certification tier' => sub {
    $t->get_ok('/api/v1/plugins?koha_version=20.00')
      ->status_is(200)
      ->json_is( '/0/releases/0/signed_manifest' => '{"digest":"abc123"}' )
      ->json_is( '/0/releases/0/signature' => 'fakesignaturebase64==' )
      ->json_is( '/0/releases/0/certification_tier' => 'CERTIFIED' );
};

subtest 'no longer exposes internal review fields' => sub {
    my $body = $t->get_ok('/api/v1/plugins?koha_version=20.00')->tx->res->json;
    ok( !exists $body->[0]{releases}[0]{error_message}, 'error_message is not exposed' );
    ok( !exists $body->[0]{releases}[0]{status},        'status is not exposed' );
};

subtest 'does not expose readme_html, but does expose issue_tracker_url' => sub {
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } )
      ->update( { readme_html => '<h1>CoverFlow</h1><p>Big README</p>', issue_tracker_url => 'https://github.com/dev/coverflow/issues' } );

    my $body = $t->get_ok('/api/v1/plugins?koha_version=20.00')->tx->res->json;
    ok( !exists $body->[0]{readme_html}, 'readme_html is stripped from the listing response, even though it is genuinely set' );
    is( $body->[0]{issue_tracker_url}, 'https://github.com/dev/coverflow/issues', 'issue_tracker_url is still exposed' );
};

subtest 'q filters by name/description, koha_max_version excludes an incompatible release, X-Total-Count is set' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'seeder' }
    );
    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'CoverFlow', description => 'A widget', developer_id => $developer->id }
    );
    my $reportkit = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
        { name => 'ReportKit', description => 'Reporting tools', developer_id => $developer->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $coverflow->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $reportkit->id, version => '1.0.0', tag_name => 'v1', status => 'published',
            koha_min_version => '20.00.00.000', koha_max_version => '21.00.00.000',
        }
    );

    my $t = test_app();

    $t->get_ok('/api/v1/plugins?koha_version=25.00.00.000&q=report')
      ->status_is(200)
      ->header_is( 'X-Total-Count' => 0 );
    is( scalar @{ $t->tx->res->json }, 0, 'ReportKit itself is excluded -- its only release is above koha_max_version' );

    $t->get_ok('/api/v1/plugins?koha_version=20.50.00.000&q=report')
      ->status_is(200)
      ->json_is( '/0/name' => 'ReportKit' )
      ->header_is( 'X-Total-Count' => 1 );
};

subtest '_page and _per_page paginate; _order_by=-name sorts descending' => sub {
    reset_db();
    for my $name (qw(Alpha Bravo Charlie)) {
        my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => $name } );
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            { plugin_id => $plugin->id, version => '1.0.0', tag_name => 'v1', status => 'published', koha_min_version => '20.00.00.000' }
        );
    }

    my $t = test_app();

    $t->get_ok('/api/v1/plugins?koha_version=25.00.00.000&_page=1&_per_page=2&_order_by=-name')
      ->status_is(200)
      ->json_is( '/0/name' => 'Charlie' )
      ->json_is( '/1/name' => 'Bravo' )
      ->header_is( 'X-Total-Count' => 3 );
    is( scalar @{ $t->tx->res->json }, 2, 'only 2 of 3 returned on page 1' );

    $t->get_ok('/api/v1/plugins?koha_version=25.00.00.000&_page=2&_per_page=2&_order_by=-name')
      ->status_is(200)
      ->json_is( '/0/name' => 'Alpha' );
    is( scalar @{ $t->tx->res->json }, 1, 'the remaining plugin is on page 2' );
};

subtest 'a private plugin never appears in /api/v1/plugins, even when it matches a search term' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'seeder' }
    );
    my $private = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'telford-erp', { name => 'TelfordERP', description => 'Bespoke integration', developer_id => $developer->id, is_private => 1 }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $private->id, version => '1.0.0', koha_min_version => '19.05',
            status => 'published', content_digest => 'private123',
        }
    );
    my $public = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'telford-public-erp', { name => 'TelfordPublicERP', description => 'A public integration', developer_id => $developer->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id => $public->id, version => '1.0.0', koha_min_version => '19.05',
            status => 'published', content_digest => 'public123',
        }
    );

    $t->get_ok('/api/v1/plugins?koha_version=20.00&q=Telford')
      ->status_is(200)
      ->header_is( 'X-Total-Count' => 1 );
    my $body = $t->tx->res->json;
    is( scalar @$body, 1, 'exactly one plugin returned' );
    is( $body->[0]{name}, 'TelfordPublicERP', 'the public one, not the private one' );

    $t->get_ok( '/plugins/' . $private->slug )
      ->status_is(200)
      ->content_like(qr/TelfordERP/);
};

done_testing();
