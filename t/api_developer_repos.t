use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

subtest 'anonymous request is rejected' => sub {
    $t->get_ok('/api/v1/developer/repos')->status_is(401);
};

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_public_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'logged-in developer gets their repo list' => sub {
    $t->app->config->{oauth_mock} = 1;
    $t->get_ok('/auth/github');
    $t->app->config->{oauth_mock} = 0;

    $t->get_ok('/api/v1/developer/repos')
      ->status_is(200)
      ->json_is( '/repos/0/full_name' => 'octocat/Hello-World' )
      ->json_is( '/repos/0/html_url'  => 'https://github.com/octocat/Hello-World' );
};

done_testing();
