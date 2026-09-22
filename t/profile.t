use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();

subtest 'anonymous visitor cannot reach the profile page' => sub {
    $t->get_ok('/profile')->status_is(404);    # existing #TODO in the app: this should be 401
};

subtest 'logged-in developer sees their own profile info' => sub {
    reset_db();
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { oauth_provider_key => 'github', provider_user_id => 'mock' }
    );

    $t->get_ok('/profile')
      ->status_is(200)
      ->text_is( 'h3' => $developer->username )
      ->content_like(qr/GitHub/)
      ->element_exists( qq{a[href="https://github.com/} . $developer->username . qq{"]} );

    $t->get_ok('/logout');
};

done_testing();
