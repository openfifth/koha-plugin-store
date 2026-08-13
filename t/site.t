use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use Mojo::Promise;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

reset_db();

my $t = test_app();

subtest 'anonymous visitor sees the pitch and join path, not the welcome-back panel' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->content_like(qr/community-run plugin catalogue/i)
      ->content_like(qr/for plugin developers/i)
      ->element_exists('a[href="/auth/github"]')
      ->element_exists_not('a[href="/new-plugin"]')
      ->element_exists_not('a[href="/my-plugins"]')
      ->content_unlike(qr/Welcome back/i);
};

subtest 'logged-in developer sees the welcome-back panel, not the join path' => sub {
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->get_ok('/')
      ->status_is(200)
      ->content_like(qr/Welcome back, mockdev/i)
      ->element_exists('a[href="/new-plugin"]')
      ->element_exists('a[href="/my-plugins"]')
      ->element_exists_not('a[href="/auth/github"]')
      ->content_unlike(qr/community-run plugin catalogue/i);

    $t->get_ok('/logout');
};

subtest 'no longer duplicates the All Plugins listing' => sub {
    $t->get_ok('/')->element_exists_not('table');
};

subtest 'sets expectations about signing and certification tier before a first submission' => sub {
    $t->get_ok('/')
      ->status_is(200)
      ->content_like(qr/signed automatically/i)
      ->content_like(qr/certification tier/i);
};

done_testing();
