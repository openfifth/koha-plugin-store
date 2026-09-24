use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::reconcile_maintainers;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
    'widget', { repo_url => 'https://github.com/dev/widget' }
);

my $still_has_access = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'a', username => 'still-has-access' }
);
my $lost_access = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'b', username => 'lost-access' }
);
my $api_errored = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'c', username => 'api-errored' }
);
my $manually_granted = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'd', username => 'manually-granted' }
);

my $maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $still_has_access->id, role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $lost_access->id,      role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $api_errored->id,      role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $manually_granted->id, role => 'maintainer', granted_via => 'manual' } );

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_collaborator_permission = sub {
        my ( $token, $repo_url, $username ) = @_;
        return { ok => 1, permission => 'write' }  if $username eq 'still-has-access';
        return { ok => 1, permission => 'read' }   if $username eq 'lost-access';
        return { ok => 0 }                         if $username eq 'api-errored';
        die "unexpected username $username (manually-granted should never be checked)";
    };
}

my $app = KohaPluginStore->new;
$app->pg( test_pg() );
$app->config->{github_app_token} = 'irrelevant-because-mocked';

KohaPluginStore::Command::reconcile_maintainers->new( app => $app )->run;

ok(
    $maintainer_model->find( { plugin_id => $plugin->id, developer_id => $still_has_access->id } ),
    'a maintainer who still has write access keeps their row'
);
ok(
    !$maintainer_model->find( { plugin_id => $plugin->id, developer_id => $lost_access->id } ),
    'a maintainer whose permission dropped below write is revoked'
);
ok(
    $maintainer_model->find( { plugin_id => $plugin->id, developer_id => $api_errored->id } ),
    'a maintainer is NOT revoked when the API call itself failed (never guess on uncertainty)'
);
ok(
    $maintainer_model->find( { plugin_id => $plugin->id, developer_id => $manually_granted->id } ),
    'a manually-granted maintainer is never even checked, let alone revoked'
);

done_testing();
