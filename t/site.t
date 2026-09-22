use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

reset_db();

my $t = test_app();

subtest 'home page shows the plugin discovery UI, not the developer pitch' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->content_like(qr/Search plugins/i)
      ->content_unlike(qr/community-run plugin catalogue/i);
};

subtest 'the test-environment banner is gone' => sub {
    $t->get_ok('/')->content_unlike(qr/test environment/i);
};

subtest 'anonymous visitor has no account menu; logged-in developer does, linking to My Plugins, Profile, and Log Out' => sub {
    $t->get_ok('/')->element_exists_not('#account-menu-toggle');

    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->get_ok('/')
      ->element_exists('#account-menu-toggle')
      ->element_exists('a[href="/my-plugins"]')
      ->element_exists('a[href="/profile"]')
      ->element_exists('a[href="/logout"]');

    $t->get_ok('/logout');
};

subtest 'sidebar nav links to Browse Plugins and Plugin developers' => sub {
    $t->get_ok('/')
      ->element_exists('#sidebar a[href="/"]')
      ->element_exists('#sidebar a[href="/developers"]');
};

subtest 'developer login link is labeled for developers, not librarians' => sub {
    $t->get_ok('/')->content_like(qr/Developer login/);
};

subtest 'developers: anonymous visitor sees the pitch and join path, not the welcome-back panel' => sub {
    $t->get_ok('/developers')
      ->status_is(200)
      ->content_like(qr/community-run plugin catalogue/i)
      ->content_like(qr/for plugin developers/i)
      ->element_exists('a[href="/auth/github"]')
      ->element_exists_not('a[href="/new-plugin"]')
      ->element_exists_not('a[href="/my-plugins"]')
      ->content_unlike(qr/Welcome back/i);
};

subtest 'developers: logged-in developer sees the welcome-back panel, not the join path' => sub {
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->get_ok('/developers')
      ->status_is(200)
      ->content_like(qr/Welcome back, mockdev/i)
      ->element_exists('a[href="/new-plugin"]')
      ->element_exists('a[href="/my-plugins"]')
      ->element_exists_not('a[href="/auth/github"]')
      ->content_unlike(qr/community-run plugin catalogue/i);

    $t->get_ok('/logout');
};

subtest 'developers: no longer duplicates the All Plugins listing' => sub {
    $t->get_ok('/developers')->element_exists_not('table');
};

subtest 'developers: sets expectations about signing and certification tier before a first submission' => sub {
    $t->get_ok('/developers')
      ->status_is(200)
      ->content_like(qr/signed automatically/i)
      ->content_like(qr/certification tier/i);
};

done_testing();
