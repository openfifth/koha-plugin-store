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
my $repo_gone = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
    { oauth_provider_key => 'github', provider_user_id => 'e', username => 'repo-gone' }
);

my $maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $still_has_access->id, role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $lost_access->id,      role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $api_errored->id,      role => 'maintainer', granted_via => 'github_access' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $manually_granted->id, role => 'maintainer', granted_via => 'manual' } );
$maintainer_model->grant( { plugin_id => $plugin->id, developer_id => $repo_gone->id,       role => 'maintainer', granted_via => 'github_access' } );

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_collaborator_permission = sub {
        my ( $token, $repo_url, $username ) = @_;
        return { ok => 1, permission => 'write' }  if $username eq 'still-has-access';
        return { ok => 1, permission => 'read' }   if $username eq 'lost-access';
        return { ok => 0 }                         if $username eq 'api-errored';
        return { ok => 1, not_found => 1 }        if $username eq 'repo-gone';
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
ok(
    !$maintainer_model->find( { plugin_id => $plugin->id, developer_id => $repo_gone->id } ),
    'a maintainer whose repo is gone (not_found) is revoked'
);

subtest 'circuit breaker: a systemically mis-scoped token aborts with no revocations' => sub {
    reset_db();

    my $breaker_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'breaker-widget', { repo_url => 'https://github.com/dev/breaker-widget' }
    );

    my @devs;
    for my $n ( 1 .. 4 ) {
        push @devs, KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
            { oauth_provider_key => 'github', provider_user_id => "breaker-$n", username => "breaker-dev-$n" }
        );
    }

    my $breaker_maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() );
    for my $dev (@devs) {
        $breaker_maintainer_model->grant(
            { plugin_id => $breaker_plugin->id, developer_id => $dev->id, role => 'maintainer', granted_via => 'github_access' }
        );
    }

    # 4 github_access rows, all of which 404 -- simulates a github_app_token
    # that can no longer see any repo it's asked about (e.g. a fine-grained
    # PAT whose repository selection changed), not 4 individually-gone repos.
    no strict 'refs';
    no warnings 'redefine';
    local *KohaPluginStore::GitHub::fetch_collaborator_permission = sub {
        return { ok => 1, not_found => 1 };
    };

    my $app = KohaPluginStore->new;
    $app->pg( test_pg() );
    $app->config->{github_app_token} = 'irrelevant-because-mocked';

    eval { KohaPluginStore::Command::reconcile_maintainers->new( app => $app )->run; };
    ok( $@, 'run() aborts (dies) instead of silently mass-revoking when the not_found rate looks systemic' );

    for my $dev (@devs) {
        ok(
            $breaker_maintainer_model->find( { plugin_id => $breaker_plugin->id, developer_id => $dev->id } ),
            'maintainer ' . $dev->username . ' was NOT revoked -- the circuit breaker deferred it instead'
        );
    }
};

done_testing();
