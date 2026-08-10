use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

reset_db();

my $t = Test::Mojo->new('KohaPluginStore');
$t->app->pg( test_pg() );

$t->app->config->{oauth_mock} = 1;
$t->get_ok('/auth/github');
$t->app->config->{oauth_mock} = 0;

{
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [ { full_name => 'octocat/Hello-World', html_url => 'https://github.com/octocat/Hello-World' } ];
    };
}

subtest 'rejects a repo not in the developer\'s own list, without calling GitHub for release info' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_releases = sub {
        die 'should not be called for an unowned repo';
    };

    $t->post_ok( '/new-plugin' => form => { plugin_repo => 'https://github.com/someone-else/not-mine' } )
      ->status_is(200)
      ->text_like( 'li.text-danger' => qr/not in the list of your public GitHub repositories/ );
};

subtest 'accepts a repo beyond a single page of results' => sub {
    no strict 'refs';
    no warnings 'redefine';

    # 101 affiliated repos -- more than the old single-page fetch_public_repos
    # (per_page=100) would ever have seen. This one is last, proving the
    # ownership check paginates through everything rather than truncating.
    *KohaPluginStore::GitHub::fetch_all_repos = sub {
        return [
            ( map { { full_name => "acme/repo$_", html_url => "https://github.com/acme/repo$_" } } 1 .. 100 ),
            { full_name => 'acme/repo101', html_url => 'https://github.com/acme/repo101' },
        ];
    };
    *KohaPluginStore::Controller::Plugins::_get_latest_release_from_github = sub { return; };

    $t->post_ok( '/new-plugin' => form => { plugin_repo => 'https://github.com/acme/repo101' } )
      ->status_is(200)
      ->element_exists_not('li.text-danger');
};

done_testing();
