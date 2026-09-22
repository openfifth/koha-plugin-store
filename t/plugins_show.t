use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::ReviewCheck;
use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

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
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
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
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'checks_running' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('meta[http-equiv="refresh"]');
};

subtest 'a changes_requested version shows per-check results, not just the generic error message' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id          => $plugin->id,
            tag_name           => 'v1.0.0',
            status             => 'changes_requested',
            certification_tier => 'INCOMPLETE',
            error_message      => 'One or more required checks failed -- see the version page for details.',
        }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        {
            plugin_version_id => $version->id,
            check_name        => 'perl_syntax',
            required          => 1,
            passed            => 0,
            message           => "lib/Foo.pm: syntax error at line 12",
        }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        {
            plugin_version_id => $version->id,
            check_name        => 'docs_presence',
            required          => 0,
            passed            => 1,
            message           => undef,
        }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/perl_syntax/)
      ->content_like(qr/lib\/Foo\.pm: syntax error at line 12/)
      ->content_like(qr/docs_presence/)
      ->content_like(qr/INCOMPLETE/);
};

subtest 'check results for every version are shown, not truncated by search()\'s default row limit' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    # Two versions with six checks each (12 total) -- more than search()'s default
    # limit of 10 rows. _plugin_page_stash fetches every version's checks in one
    # combined query ordered only by check_name, so a version whose checks sort late
    # alphabetically must still show up in full, not get silently cut off.
    for my $tag ( 'v1.0.0', 'v2.0.0' ) {
        my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            {
                plugin_id          => $plugin->id,
                tag_name           => $tag,
                status             => 'changes_requested',
                certification_tier => 'INCOMPLETE',
                error_message      => 'One or more required checks failed.',
            }
        );
        for my $letter ( 'a' .. 'f' ) {
            KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
                {
                    plugin_version_id => $version->id,
                    check_name        => "check_${tag}_${letter}",
                    required          => 0,
                    passed            => 1,
                    message           => undef,
                }
            );
        }
    }

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/check_v1\.0\.0_a/)
      ->content_like(qr/check_v1\.0\.0_f/)
      ->content_like(qr/check_v2\.0\.0_a/)
      ->content_like(qr/check_v2\.0\.0_f/);

    $t->get_ok('/logout');
};

subtest 'a logged-in owner triggers a GitHub releases fetch; a public visitor does not' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');    # logs in as mockdev
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    my $fetch_calls = 0;
    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub { $fetch_calls++; return []; };
    }

    $t->get_ok( '/plugins/' . $plugin->slug )->status_is(200);
    is( $fetch_calls, 1, 'owner view fetches GitHub releases' );

    $t->get_ok('/logout');
    $fetch_calls = 0;
    $t->get_ok( '/plugins/' . $plugin->slug )->status_is(200);
    is( $fetch_calls, 0, 'public view does not fetch GitHub releases' );
};

subtest 'public visitor sees only published versions and no GitHub-available section' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/v1\.0\.0/)
      ->content_unlike(qr/v0\.9\.0/)
      ->content_unlike(qr/Releases from.*github/is)
      ->element_exists_not('#edit-plugin-modal');
};

subtest 'owner sees all versions plus the GitHub-available section and an edit control' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v0.9.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    {
        no strict 'refs';
        no warnings 'redefine';
        *KohaPluginStore::GitHub::fetch_releases = sub {
            return [ { name => 'v2.0.0', tag_name => 'v2.0.0', published_at => '2026-01-01', assets => [ { name => 'plugin.kpz' } ] } ];
        };
    }

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/v1\.0\.0/)
      ->content_like(qr/v0\.9\.0/)
      ->content_like(qr/v2\.0\.0/)
      ->element_exists('#edit-plugin-modal');

    $t->get_ok('/logout');
};

subtest 'public visitor with zero published versions sees empty releases table, no certification details' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id          => $plugin->id,
            tag_name           => 'v1.0.0',
            version            => '1.0.0',
            status             => 'changes_requested',
            certification_tier => 'INCOMPLETE',
            error_message      => 'One or more required checks failed'
        }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        {
            plugin_version_id => $version->id,
            check_name        => 'perl_syntax',
            required          => 1,
            passed            => 0,
            message           => 'Syntax error',
        }
    );

    # Public visitor should not see any version details
    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_unlike(qr/v1\.0\.0/)
      ->content_unlike(qr/INCOMPLETE/)
      ->content_unlike(qr/perl_syntax/)
      ->content_unlike(qr/Syntax error/);
};

subtest 'a published version shows a Signed badge and the explanatory copy; a non-published one does not' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id       => $plugin->id,
            tag_name        => 'v1.0.0',
            status          => 'published',
            signed_manifest => '{"slug":"widget"}',
            signature       => 'fakesignature==',
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.1.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/<tr>(?:(?!<\/tr>).)*?v1\.0\.0(?:(?!<\/tr>).)*?<span class="badge text-bg-info">Signed<\/span>(?:(?!<\/tr>).)*?<\/tr>/s)
      ->content_unlike(qr/<tr>(?:(?!<\/tr>).)*?v1\.1\.0(?:(?!<\/tr>).)*?<span class="badge text-bg-info">Signed<\/span>(?:(?!<\/tr>).)*?<\/tr>/s)
      ->content_like(qr/confirms the file hasn't been altered/i);

    $t->get_ok('/logout');
};

subtest 'readme_html renders as the primary content when present' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', readme_html => '<h1>Widget README</h1>' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/<h1>Widget README<\/h1>/, 'readme_html rendered unescaped');
};

subtest 'a plugin with no readme_html falls back gracefully' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/No README is available/);
};

subtest 'issue_tracker_url link appears only when set' => sub {
    reset_db();
    my $with_tracker = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-a', { name => 'WidgetA', repo_url => 'https://github.com/dev/widget-a', issue_tracker_url => 'https://github.com/dev/widget-a/issues' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $with_tracker->id, tag_name => 'v1.0.0', status => 'published' }
    );
    my $without_tracker = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-b', { name => 'WidgetB', repo_url => 'https://github.com/dev/widget-b' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $without_tracker->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $with_tracker->slug )
      ->status_is(200)
      ->element_exists('a[href="https://github.com/dev/widget-a/issues"]');

    $t->get_ok( '/plugins/' . $without_tracker->slug )
      ->status_is(200)
      ->content_unlike(qr/Issue tracker/);
};

subtest 'the technical report tab still shows every check for is_owner and only published-version checks for everyone else' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );
    my $published = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );
    my $draft = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v2.0.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $published->id, check_name => 'docs_presence', required => 0, passed => 1, message => undef }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $draft->id, check_name => 'perl_syntax', required => 1, passed => 0, message => 'boom' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/docs_presence/)
      ->content_like(qr/perl_syntax/);

    $t->get_ok('/logout');
    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/docs_presence/)
      ->content_unlike(qr/perl_syntax/);
};

done_testing();
