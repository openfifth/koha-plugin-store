use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::backfill_markdown_rendering;
use KohaPluginStore::Model::Plugin;

reset_db();

# Created first (lowest id, so processed first in the command's unordered
# SELECT -- see below) specifically to prove that a render/sanitize
# exception on one plugin doesn't abort the whole run before it reaches the
# plugins created after it.
my $plugin_broken = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'Broken', repo_url => 'https://github.com/dev/broken', readme_html => '<p>Old broken readme</p>' }
);

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'Widget', repo_url => 'https://github.com/dev/widget', readme_html => '<p>Old readme</p>' }
);
my $plugin_no_readme = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'NoReadme', repo_url => 'https://github.com/dev/noreadme' }
);

no strict 'refs';
no warnings 'redefine';
*KohaPluginStore::GitHub::fetch_readme_markdown = sub {
    my ( $token, $owner_repo ) = @_;
    return "# Widget\n\nDocs.\n" if $owner_repo eq 'https://github.com/dev/widget';
    return "# Broken\n"          if $owner_repo eq 'https://github.com/dev/broken';
    return undef;
};
*KohaPluginStore::GitHub::fetch_changelog_markdown = sub {
    my ( $token, $owner_repo ) = @_;
    return "## 1.0.0\n\nInitial release.\n" if $owner_repo eq 'https://github.com/dev/widget';
    return undef;
};

# Simulates a render-stage exception (e.g. a bug in a future CommonMark
# upgrade, or some other die past the fetch stage -- NOT invalid UTF-8:
# Markdown.pm's OPT_VALIDATE_UTF8 replaces invalid bytes with U+FFFD and
# returns normally, it does not make CommonMark throw) for exactly the
# "Broken" plugin's markdown, while behaving normally for every other input --
# this exercises the eval scope actually catching a failure past the fetch
# stage, not just a fetch that returns undef.
my $real_render = \&KohaPluginStore::Markdown::render;
*KohaPluginStore::Markdown::render = sub {
    my ($markdown) = @_;
    die "simulated render failure\n" if defined $markdown && $markdown eq "# Broken\n";
    return $real_render->($markdown);
};

my $app = KohaPluginStore->new;
$app->pg( test_pg() );

KohaPluginStore::Command::backfill_markdown_rendering->new( app => $app )->run;

my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
is( $reloaded->readme_html, "<h1>Widget</h1>\n<p>Docs.</p>\n", 'readme_html re-rendered through the new pipeline' );
is( $reloaded->changelog_html, "<h2>1.0.0</h2>\n<p>Initial release.</p>\n", 'changelog_html re-rendered through the new pipeline' );

my $reloaded_no_readme = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin_no_readme->id } );
is( $reloaded_no_readme->readme_html, undef, 'a plugin with no fetchable README is left with no readme_html' );

my $reloaded_broken = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin_broken->id } );
is(
    $reloaded_broken->readme_html, '<p>Old broken readme</p>',
    'a plugin whose render throws is left with its prior readme_html, not crashed or nulled'
);

done_testing();
