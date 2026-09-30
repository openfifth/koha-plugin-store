use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::backfill_markdown_rendering;
use KohaPluginStore::Model::Plugin;

reset_db();

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
    return undef;
};
*KohaPluginStore::GitHub::fetch_changelog_markdown = sub {
    my ( $token, $owner_repo ) = @_;
    return "## 1.0.0\n\nInitial release.\n" if $owner_repo eq 'https://github.com/dev/widget';
    return undef;
};

my $app = KohaPluginStore->new;
$app->pg( test_pg() );

KohaPluginStore::Command::backfill_markdown_rendering->new( app => $app )->run;

my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
is( $reloaded->readme_html, "<h1>Widget</h1>\n<p>Docs.</p>\n", 'readme_html re-rendered through the new pipeline' );
is( $reloaded->changelog_html, "<h2>1.0.0</h2>\n<p>Initial release.</p>\n", 'changelog_html re-rendered through the new pipeline' );

my $reloaded_no_readme = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin_no_readme->id } );
is( $reloaded_no_readme->readme_html, undef, 'a plugin with no fetchable README is left with no readme_html' );

done_testing();
