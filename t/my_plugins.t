use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

reset_db();

my $t = test_app();

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

subtest 'shows the welcome-back header and the submit/bulk-submit nav buttons' => sub {
    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/Welcome back, mockdev/i)
      ->element_exists('a[href="/new-plugin"]')
      ->element_exists('a[href="/new-plugin/bulk"]')
      ->content_like(qr/Submit a new plugin/i)
      ->content_like(qr/Bulk submit plugins/i);
};

subtest 'shows an empty state when the developer has no plugins yet' => sub {
    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/don't have any plugins yet/i);
};

subtest 'lists the developer\'s own plugins once they have one' => sub {
    my $owner = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );
    KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create_with_unique_slug(
        'widget', { name => 'Widget', repo_url => 'https://github.com/dev/widget', developer_id => $owner->id }
    );

    $t->get_ok('/my-plugins')
      ->status_is(200)
      ->content_like(qr/Widget/)
      ->content_unlike(qr/don't have any plugins yet/i);
};

done_testing();
