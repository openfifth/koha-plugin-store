use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

# Clear Minion jobs from previous test runs
test_pg()->db->query('DELETE FROM minion_jobs');

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

subtest 'shows a list of releases to choose from, eligible ones selectable' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
    *KohaPluginStore::GitHub::fetch_releases = sub {
        return [
            {
                tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
                author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
                assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
            },
            {
                tag_name => 'v0.9.0', name => 'v0.9.0', published_at => '2025-01-01T00:00:00Z',
                author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
                assets => [],
            },
        ];
    };

    $t->post_ok( '/new-plugin' => form => { plugin_repo => 'https://github.com/octocat/Hello-World' } )
      ->status_is(200)
      ->element_exists('input[type="radio"][value="v1.0.0"]')
      ->element_exists_not('input[type="radio"][value="v0.9.0"]');

    # Verify the ineligible release message is shown
    like( $t->tx->res->body, qr/one and only one/, 'shows ineligible release message' );
};

subtest 'submitting a chosen tag creates rows and enqueues a job' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
            assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };

    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/octocat/Hello-World',
            tag_name    => 'v1.0.0',
        }
    )->status_is(302);

    my $location = $t->tx->res->headers->location;
    like( $location, qr{^/plugins/hello-world}, 'redirects to the new plugin detail page' );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/Hello-World' } );
    ok( $plugin, 'a plugin row was created' );
    is( $plugin->slug, 'hello-world', 'slug derived from the repo name' );

    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->find( { plugin_id => $plugin->id } );
    is( $version->status, 'submitted', 'version starts as submitted' );
    is( $version->author_username, 'octocat', 'author captured from the release JSON' );

    my $jobs = $t->app->minion->jobs( { tasks => ['process_plugin_version'] } );
    my $job_count = $jobs->total;
    is( $job_count, 1, 'a process_plugin_version job was enqueued' );

    # Verify attempts parameter was set to 3
    while (my $job = $jobs->next) {
        is( $job->{attempts}, 3, 'job has attempts set to 3' );
    }
};

subtest 'rejects duplicate submission of same release with constraint violation' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
    *KohaPluginStore::GitHub::fetch_release_by_tag = sub {
        return {
            tag_name => 'v1.0.0', name => 'v1.0.0', published_at => '2026-01-01T00:00:00Z',
            author => { login => 'octocat', avatar_url => 'https://example.com/a.png' },
            assets => [ { name => 'plugin.kpz', browser_download_url => 'https://example.com/plugin.kpz' } ],
        };
    };

    # Get the plugin created in the previous subtest
    my $existing_plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { repo_url => 'https://github.com/octocat/Hello-World' } );
    ok( $existing_plugin, 'plugin from previous subtest exists' );

    # Mock create_with_unique_slug to return the existing plugin (simulating a scenario where we try to reuse it)
    my $original_create = \&KohaPluginStore::Model::Plugin::create_with_unique_slug;
    *KohaPluginStore::Model::Plugin::create_with_unique_slug = sub {
        my ($self, @args) = @_;
        return $existing_plugin;
    };

    # Try to submit the same release again
    $t->post_ok(
        '/new-plugin-confirm' => form => {
            plugin_repo => 'https://github.com/octocat/Hello-World',
            tag_name    => 'v1.0.0',
        }
    )->status_is(200);

    # Should show the error message (renders new-plugin-step2 with errors)
    like( $t->tx->res->body, qr/already been submitted/, 'shows already submitted error message' );

    # Verify no additional job was enqueued (should still be 1 from previous subtest)
    my $job_count = $t->app->minion->jobs( { tasks => ['process_plugin_version'] } )->total;
    is( $job_count, 1, 'no second job was enqueued for duplicate submission' );

    # Restore the original method
    *KohaPluginStore::Model::Plugin::create_with_unique_slug = $original_create;
};

done_testing();
