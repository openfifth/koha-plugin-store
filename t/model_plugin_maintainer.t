use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget', { repo_url => 'https://github.com/dev/widget' }
);
my $owner_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'owner', username => 'owner' }
);
my $other_dev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'other', username => 'other' }
);

subtest 'grant creates a new row' => sub {
    my $row = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $owner_dev->id, role => 'owner', granted_via => 'creator' }
    );
    is( $row->role, 'owner' );
    is( $row->granted_via, 'creator' );
};

subtest 'grant is idempotent and never downgrades an existing role/granted_via' => sub {
    my $model = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() );
    my $first_verified_at = $model->find( { plugin_id => $plugin->id, developer_id => $owner_dev->id } )->last_verified_at;

    sleep 1;    # last_verified_at has second-resolution; make the bump observable
    my $row = $model->grant(
        { plugin_id => $plugin->id, developer_id => $owner_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    is( $row->role, 'owner', 'role was not downgraded from owner to maintainer' );
    is( $row->granted_via, 'creator', 'granted_via was not overwritten' );
    isnt( $row->last_verified_at, $first_verified_at, 'last_verified_at was bumped' );
};

subtest 'a different developer gets their own row' => sub {
    my $row = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $other_dev->id, role => 'maintainer', granted_via => 'github_access' }
    );
    is( $row->developer_id, $other_dev->id );

    my @all = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->search( { plugin_id => $plugin->id } );
    is( scalar @all, 2, 'both maintainers are recorded for the plugin' );
};

done_testing();
