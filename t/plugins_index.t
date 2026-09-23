use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $t = test_app();

subtest 'only plugins with a published version are listed' => sub {
    reset_db();
    my $published = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Published' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $published->id, tag_name => 'v1', status => 'published' }
    );
    my $draft = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'DraftOnly' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $draft->id, tag_name => 'v1', status => 'submitted' }
    );

    $t->get_ok('/')
      ->status_is(200)
      ->content_like(qr/Published/)
      ->content_unlike(qr/DraftOnly/);
};

subtest 'no koha_version query param is required, unlike the API endpoint' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'AnyVersion' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1', status => 'published', koha_min_version => '99.00.00.000' }
    );

    $t->get_ok('/')->status_is(200)->content_like(qr/AnyVersion/);
};

subtest 'q filters the card list' => sub {
    reset_db();
    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'CoverFlow' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $coverflow->id, tag_name => 'v1', status => 'published' }
    );
    my $reportkit = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'ReportKit' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $reportkit->id, tag_name => 'v1', status => 'published' }
    );

    $t->get_ok('/?q=report')
      ->status_is(200)
      ->content_like(qr/ReportKit/)
      ->content_unlike(qr/CoverFlow/);
};

subtest 'certification_tier filters the card list' => sub {
    reset_db();
    my $certified = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Certified' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $certified->id, tag_name => 'v1', status => 'published', certification_tier => 'CERTIFIED' }
    );
    my $structural = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Structural' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $structural->id, tag_name => 'v1', status => 'published', certification_tier => 'STRUCTURAL' }
    );

    $t->get_ok('/?certification_tier=CERTIFIED')
      ->status_is(200)
      ->content_like(qr/Certified/)
      ->content_unlike(qr/Structural/);
};

subtest '_order_by=-name sorts descending' => sub {
    reset_db();
    for my $name (qw(Alpha Bravo)) {
        my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => $name } );
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            { plugin_id => $plugin->id, tag_name => 'v1', status => 'published' }
        );
    }

    my $html = $t->get_ok('/?_order_by=-name')->tx->res->body;
    ok( index( $html, 'Bravo' ) < index( $html, 'Alpha' ), 'Bravo (Z-ward) appears before Alpha in the markup' );
};

subtest 'homepage shows a one-line intro above the search form' => sub {
    $t->get_ok('/')->content_like(qr/Browse and install community-contributed plugins for your Koha library system\./);
};

done_testing();
