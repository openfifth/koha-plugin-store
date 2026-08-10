use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginContributor;

reset_db();

subtest 'create and find a contributor' => sub {
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create( { name => 'Widget' } );

    my $contributor = KohaPluginStore::Model::PluginContributor->new( pg => test_pg() )->create(
        {
            plugin_id           => $plugin->id,
            github_username     => 'octocat',
            avatar_url          => 'https://example.com/a.png',
            contributions_count => 42,
        }
    );

    ok( $contributor->id, 'id was assigned' );
    is( $contributor->github_username, 'octocat', 'github_username accessor reads back' );

    my $found = KohaPluginStore::Model::PluginContributor->new( pg => test_pg() )->find(
        { plugin_id => $plugin->id, github_username => 'octocat' }
    );
    is( $found->contributions_count, 42, 'found the right row' );
};

done_testing();
