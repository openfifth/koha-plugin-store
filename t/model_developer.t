use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

subtest 'find_or_create_from_oauth creates on first login' => sub {
    my $developer = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find_or_create_from_oauth(
        {
            oauth_provider_key => 'github',
            provider_user_id   => '12345',
            username            => 'octocat',
            avatar_url          => 'https://example.com/octocat.png',
        }
    );
    ok( $developer->id, 'id was assigned' );
    is( $developer->username, 'octocat', 'username set' );
};

subtest 'find_or_create_from_oauth finds and refreshes an existing developer' => sub {
    my $first = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find_or_create_from_oauth(
        {
            oauth_provider_key => 'github',
            provider_user_id   => '99999',
            username            => 'oldname',
            avatar_url          => 'https://example.com/old.png',
        }
    );
    my $second = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find_or_create_from_oauth(
        {
            oauth_provider_key => 'github',
            provider_user_id   => '99999',
            username            => 'newname',
            avatar_url          => 'https://example.com/new.png',
        }
    );
    is( $second->id, $first->id, 'same developer row, not a new one' );
    is( $second->username, 'newname', 'username refreshed' );

    my $reloaded = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find( { id => $first->id } );
    is( $reloaded->username, 'newname', 'refresh was persisted' );
};

done_testing();
