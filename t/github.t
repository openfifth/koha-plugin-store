use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::GitHub;

subtest 'no access token returns an empty list without making a request' => sub {
    is_deeply( KohaPluginStore::GitHub::fetch_public_repos(undef), [], 'undef token' );
    is_deeply( KohaPluginStore::GitHub::fetch_public_repos(''), [], 'empty string token' );
};

done_testing();
