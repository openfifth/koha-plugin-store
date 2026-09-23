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
      ->text_is( '#plugin-title' => 'Widget' )
      ->element_exists_not('meta[http-equiv="refresh"]');
};

subtest 'the same version is also reachable at its own permalink' => sub {
    $t->get_ok( '/plugins/widget/v/v1.0.0' )
      ->status_is(200)
      ->text_is( '#plugin-title' => 'Widget' );
};

subtest 'a submitted version (no published version exists yet) shows the auto-refresh meta tag to its owner' => sub {
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

    $t->get_ok('/logout');
};

subtest 'a public visitor sees no processing state and no auto-refresh when nothing is published yet' => sub {
    $t->get_ok('/plugins/widget')
      ->status_is(200)
      ->element_exists_not('meta[http-equiv="refresh"]')
      ->content_like(qr/No published release yet/);
};

subtest 'a checks_running version shows the auto-refresh meta tag to its owner' => sub {
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

    $t->get_ok('/logout');
};

subtest 'a changes_requested version (owner, nothing published yet) shows its own per-check results' => sub {
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
        { plugin_version_id => $version->id, check_name => 'perl_syntax', required => 1, passed => 0, message => 'lib/Foo.pm: syntax error at line 12' }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $version->id, check_name => 'docs_presence', required => 0, passed => 1, message => undef }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/perl_syntax/)
      ->content_like(qr/lib\/Foo\.pm: syntax error at line 12/)
      ->content_like(qr/docs_presence/)
      ->content_like(qr/INCOMPLETE/);

    $t->get_ok('/logout');
};

subtest 'a single version\'s full 11-check report is not truncated by search()\'s default row limit of 10' => sub {
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
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );
    for my $letter ( 'a' .. 'k' ) {    # 11 checks, one over the default limit of 10
        KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
            { plugin_version_id => $version->id, check_name => "check_$letter", required => 0, passed => 1, message => undef }
        );
    }

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_like(qr/check_a/)
      ->content_like(qr/check_k/);

    $t->get_ok('/logout');
};

subtest 'public visitor: dropdown links the published tag but only shows (does not link) a non-published one' => sub {
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
      ->element_exists('a[href="/plugins/widget/v/v1.0.0"]')
      ->element_exists_not('a[href="/plugins/widget/v/v0.9.0"]')
      ->content_like(qr/v0\.9\.0/, 'the draft tag is still shown, just not linked')
      ->element_exists_not('#edit-plugin-modal');

    $t->get_ok('/plugins/widget/v/v0.9.0')->status_is(404);
};

subtest 'owner: dropdown links every version, including drafts; edit control is present' => sub {
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

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('a[href="/plugins/widget/v/v1.0.0"]')
      ->element_exists('a[href="/plugins/widget/v/v0.9.0"]')
      ->element_exists('#edit-plugin-modal');

    $t->get_ok('/plugins/widget/v/v0.9.0')->status_is(200);

    $t->get_ok('/logout');
};

subtest 'a plugin with zero published versions renders inline at the bare URL and hides its draft from the public' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        {
            plugin_id          => $plugin->id,
            tag_name           => 'v1.0.0',
            status             => 'changes_requested',
            certification_tier => 'INCOMPLETE',
            error_message      => 'One or more required checks failed',
        }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => ( $plugin->latest_version->id ), check_name => 'perl_syntax', required => 1, passed => 0, message => 'Syntax error' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->content_unlike(qr/v1\.0\.0/)
      ->content_unlike(qr/INCOMPLETE/)
      ->content_unlike(qr/perl_syntax/)
      ->content_unlike(qr/Syntax error/)
      ->content_like(qr/No published release yet/);
};

subtest 'a published version shows a Signed badge; the same plugin\'s draft version does not' => sub {
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
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published', signed_manifest => '{"slug":"widget"}', signature => 'fakesignature==' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.1.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    $t->get_ok('/plugins/widget/v/v1.0.0')
      ->status_is(200)
      ->element_exists('.badge.text-bg-info');

    $t->get_ok('/plugins/widget/v/v1.1.0')
      ->status_is(200)
      ->element_exists_not('.badge.text-bg-info');

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

subtest 'a non-owner cannot reach a non-published version\'s page at all (not just hidden content -- a 404)' => sub {
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
    my $draft = KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v2.0.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );
    KohaPluginStore::Model::ReviewCheck->new( pg => test_pg() )->record(
        { plugin_version_id => $draft->id, check_name => 'perl_syntax', required => 1, passed => 0, message => 'boom' }
    );

    $t->get_ok('/plugins/widget/v/v2.0.0')
      ->status_is(200)
      ->content_like(qr/perl_syntax/);

    $t->get_ok('/logout');
    $t->get_ok('/plugins/widget/v/v2.0.0')->status_is(404);
};

subtest 'a different, real logged-in developer (not the owner) gets a 404 for another developer\'s draft version' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    # Developer A: the mock-OAuth identity, now logged in (the requester).
    my $developer_a = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );

    # Developer B: a second, distinct, real Developer row -- the plugin owner.
    # Not the logged-in session; not a NULL developer_id.
    my $developer_b = KohaPluginStore::Model::Developer->new( pg => test_pg() )->create(
        { oauth_provider_key => 'github', provider_user_id => 'other-owner-1', username => 'other-owner' }
    );
    isnt( $developer_a->id, $developer_b->id, 'two distinct real developer rows' );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'gadget', { repo_url => 'https://github.com/dev/gadget', developer_id => $developer_b->id }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v2.0.0', status => 'changes_requested', certification_tier => 'INCOMPLETE' }
    );

    # Developer A is logged in (via the mock OAuth session), developer B owns
    # the plugin -- a real, non-owning developer requesting someone else's
    # draft version must still get a 404.
    $t->get_ok('/plugins/gadget/v/v2.0.0')->status_is(404);

    $t->get_ok('/logout');
};

subtest 'author name links to the public author page' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', author => 'Jane Doe', repo_url => 'https://github.com/dev/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $plugin->slug )
      ->status_is(200)
      ->element_exists('a[href="/authors/jane-doe"]')
      ->text_is('a[href="/authors/jane-doe"]' => 'Jane Doe');
};

subtest 'a changelog excerpt for the current version renders when it matches; falls back to a full-changelog link otherwise' => sub {
    reset_db();
    my $matching = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-a', { name => 'WidgetA', repo_url => 'https://github.com/dev/widget-a', changelog_html => '<h2>1.0.0</h2><p>Added sparkle.</p>' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $matching->id, tag_name => 'v1.0.0', status => 'published' }
    );
    my $nonmatching = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget-b', { name => 'WidgetB', repo_url => 'https://github.com/dev/widget-b', changelog_html => '<p>Freeform notes, no headings.</p>' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $nonmatching->id, tag_name => 'v1.0.0', status => 'published' }
    );

    $t->get_ok( '/plugins/' . $matching->slug )
      ->status_is(200)
      ->content_like(qr/Added sparkle\./);

    $t->get_ok( '/plugins/' . $nonmatching->slug )
      ->status_is(200)
      ->content_like(qr/Full changelog/)
      ->content_unlike(qr/Freeform notes/);
};

done_testing();
