use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'unknown slug is a 404' => sub {
    $t->get_ok('/plugins/does-not-exist')->status_is(404);
};

subtest 'a published version shows no auto-refresh' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', version => '1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->text_is( '#main h2' => 'Widget' )
      ->element_exists_not('meta[http-equiv="refresh"]');
};

subtest 'a submitted version shows the auto-refresh meta tag' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('meta[http-equiv="refresh"]');
};

subtest 'a checks_running version shows the auto-refresh meta tag' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'checks_running' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('meta[http-equiv="refresh"]');
};

done_testing();
