use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'links to the detail page and shows the latest version\'s status' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $developer->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )
      ->create( { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'submitted' } );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )
      ->create( { plugin_id => $plugin->id, tag_name => 'v1.0.1', status => 'published' } );

    $t->get_ok('/plugins')
      ->status_is(200)
      ->element_exists( qq{a[href="/plugins/} . $plugin->slug . qq{"]} )
      ->text_like( 'td.plugin-status span' => qr/published/ );
};

subtest 'a plugin with no versions yet shows a placeholder, not an error' => sub {
    reset_db();
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'dev' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'bare', { name => 'Bare', repo_url => 'https://github.com/dev/bare', developer_id => $developer->id }
    );

    $t->get_ok('/plugins')->status_is(200)->text_like( 'td.plugin-status' => qr/^\s*-\s*$/ );
};

subtest 'My Plugins shows the same link and status' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )
      ->find( { oauth_provider_key => 'github', provider_user_id => 'mock' } );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $developer->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )
      ->create( { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'checks_running' } );

    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->element_exists( qq{a[href="/plugins/} . $plugin->slug . qq{"]} )
      ->text_like( 'td.plugin-status span' => qr/checks_running/ );
};

done_testing();
