use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);
use CsrfHelper qw(csrf_token);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::PluginMaintainer;

reset_db();

my $t = test_app();

subtest 'unknown slug is a 404' => sub {
    $t->post_ok( '/plugins/does-not-exist/edit' => form => { name => 'x', description => 'x', repo_url => 'x', author => 'x' } )
      ->status_is(404);
};

subtest 'a non-owner cannot update the plugin' => sub {
    reset_db();

    # The real owner -- a different developer than the one who logs in below.
    my $real_owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'real-owner', username => 'realowner' }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev, NOT $real_owner
    $t->app->config->{oauth_mock} = 0;

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $real_owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => { name => 'Changed', description => 'x', repo_url => 'x', author => 'x' } )
      ->status_is(401);

    $t->get_ok('/logout');
};

subtest 'a blank required field re-renders the page with an error and preserves input' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => { name => 'Widget', description => '', repo_url => 'https://github.com/dev/widget', author => 'Dev', csrf_token => csrf_token($t) } )
      ->status_is(200)
      ->content_like(qr/required/i)
      ->element_exists('input[name="name"][value="Widget"]');

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->description, 'Original', 'description was not changed on validation failure' );

    $t->get_ok('/logout');
};

subtest 'a valid update persists and redirects to the plugin page' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' =>
        form => { name => 'Widget', description => 'Updated description', repo_url => 'https://github.com/dev/widget', author => 'Dev', csrf_token => csrf_token($t) } )
      ->status_is(302)
      ->header_is( Location => '/plugins/' . $plugin->slug );

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->description, 'Updated description', 'description was updated' );

    $t->get_ok('/logout');
};

subtest 'issue_tracker_url is optional -- omitting it does not block a valid update' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' =>
        form => { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->issue_tracker_url, undef, 'left unset when omitted from the form' );

    $t->get_ok('/logout');
};

subtest 'issue_tracker_url persists when provided' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' =>
        form => {
            name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev',
            issue_tracker_url => 'https://github.com/dev/widget/issues', csrf_token => csrf_token($t),
        } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->issue_tracker_url, 'https://github.com/dev/widget/issues', 'issue_tracker_url was saved' );

    $t->get_ok('/logout');
};

subtest 'a non-http(s) repo_url is rejected and not persisted' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => {
        name => 'Widget', description => 'Original', author => 'Dev',
        repo_url => 'javascript:alert(document.cookie)', csrf_token => csrf_token($t),
    } )
      ->status_is(200)
      ->content_like(qr/http/i);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->repo_url, 'https://github.com/dev/widget', 'repo_url was not changed' );

    $t->get_ok('/logout');
};

subtest 'a non-http(s) issue_tracker_url is rejected and not persisted' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => {
        name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget', author => 'Dev',
        issue_tracker_url => 'javascript:alert(document.cookie)', csrf_token => csrf_token($t),
    } )
      ->status_is(200)
      ->content_like(qr/http/i);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->issue_tracker_url, undef, 'issue_tracker_url was not changed' );

    $t->get_ok('/logout');
};

subtest 'a granted maintainer (not the original owner) can update the plugin' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner6', username => 'owner6' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget6', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget6', author => 'Dev', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' =>
        form => { name => 'Widget', description => 'Updated by maintainer', repo_url => 'https://github.com/dev/widget6', author => 'Dev', csrf_token => csrf_token($t) } )
      ->status_is(302);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->description, 'Updated by maintainer' );

    $t->get_ok('/logout');
};

subtest 'a maintainer (not the owner) cannot change repo_url' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner7', username => 'owner7' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget7', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget7', author => 'Dev', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => {
        name => 'Widget', description => 'Original', author => 'Dev',
        repo_url => 'https://github.com/hijacker/evil-repo', csrf_token => csrf_token($t),
    } )
      ->status_is(200)
      ->content_like(qr/Only the plugin owner can change the repository URL/i);

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->repo_url, 'https://github.com/dev/widget7', 'repo_url was not changed by a non-owner maintainer' );

    $t->get_ok('/logout');
};

subtest 'the same maintainer can still change other fields when repo_url is submitted unchanged' => sub {
    reset_db();
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'owner8', username => 'owner8' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget8', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget8', author => 'Dev', developer_id => $owner->id }
    );

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $mockdev = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::PluginMaintainer->new( pg => test_pg() )->grant(
        { plugin_id => $plugin->id, developer_id => $mockdev->id, role => 'maintainer', granted_via => 'github_access' }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => {
        name => 'Renamed Widget', description => 'Updated by maintainer', author => 'New Author',
        repo_url => 'https://github.com/dev/widget8', issue_tracker_url => 'https://github.com/dev/widget8/issues',
        csrf_token => csrf_token($t),
    } )
      ->status_is(302)
      ->header_is( Location => '/plugins/' . $plugin->slug );

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->name,              'Renamed Widget',                              'name was updated by maintainer' );
    is( $reloaded->description,       'Updated by maintainer',                       'description was updated by maintainer' );
    is( $reloaded->author,            'New Author',                                  'author was updated by maintainer' );
    is( $reloaded->issue_tracker_url, 'https://github.com/dev/widget8/issues',       'issue_tracker_url was updated by maintainer' );
    is( $reloaded->repo_url,          'https://github.com/dev/widget8',              'repo_url is unchanged' );

    $t->get_ok('/logout');
};

subtest 'the true owner can still change repo_url' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget9', { name => 'Widget', description => 'Original', repo_url => 'https://github.com/dev/widget9', author => 'Dev', developer_id => $owner->id }
    );

    $t->post_ok( '/plugins/' . $plugin->slug . '/edit' => form => {
        name => 'Widget', description => 'Original', author => 'Dev',
        repo_url => 'https://github.com/dev/widget9-renamed', csrf_token => csrf_token($t),
    } )
      ->status_is(302)
      ->header_is( Location => '/plugins/' . $plugin->slug );

    my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
    is( $reloaded->repo_url, 'https://github.com/dev/widget9-renamed', 'the true owner can change repo_url' );

    $t->get_ok('/logout');
};

done_testing();
