use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

reset_db();

my $t = test_app();

subtest 'author page lists only that author\'s published plugins' => sub {
    reset_db();
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', author => 'Octavia Cat', description => 'A fine widget', repo_url => 'https://github.com/a/widget' }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
        { plugin_id => $plugin->id, tag_name => 'v1', status => 'published', certification_tier => 'CERTIFIED' }
    );

    $t->get_ok('/authors/octavia-cat')
      ->status_is(200)
      ->content_like(qr/Octavia Cat/)
      ->content_like(qr/Widget/)
      ->content_like(qr/A fine widget/)
      ->element_exists('a[href="/plugins/widget"]');
};

subtest 'a slug with zero matching published plugins 404s' => sub {
    $t->get_ok('/authors/nobody-here')->status_is(404);
};

subtest 'a private plugin is excluded from its author\'s public page' => sub {
    reset_db();
    my $public = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', author => 'Octavia Cat', repo_url => 'https://github.com/a/widget' }
    );
    my $private = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'secret-widget', { name => 'SecretWidget', author => 'Octavia Cat', is_private => 1, repo_url => 'https://github.com/a/secret-widget' }
    );
    for my $plugin ( $public, $private ) {
        KohaPluginStore::Model::PluginVersion->new( pg => test_pg() )->create(
            { plugin_id => $plugin->id, tag_name => 'v1', status => 'published' }
        );
    }

    $t->get_ok('/authors/octavia-cat')
      ->status_is(200)
      ->content_like(qr/Widget/)
      ->content_unlike(qr/SecretWidget/);
};

done_testing();
