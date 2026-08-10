use Mojo::Base -strict;
use Test::More;
use Mojo::JSON qw(encode_json);
use Mojo::Message::Response;

use KohaPluginStore::GitHub;

sub _fake_tx {
    my (@repos) = @_;
    my $res = Mojo::Message::Response->new;
    $res->code(200);
    $res->body( encode_json( \@repos ) );
    return bless { result => $res }, 'FakeTx';
}

sub FakeTx::result { return $_[0]->{result} }

subtest 'no access token returns an empty list without making a request' => sub {
    is_deeply( KohaPluginStore::GitHub::fetch_all_repos(undef), [], 'undef token' );
    is_deeply( KohaPluginStore::GitHub::fetch_all_repos(''),    [], 'empty string token' );
};

subtest 'fetches until a short page is returned' => sub {
    no strict 'refs';
    no warnings 'redefine';

    my @pages = (
        [ map { { full_name => "acme/repo$_", html_url => "https://github.com/acme/repo$_" } } 1 .. 100 ],
        [ { full_name => 'acme/repo101', html_url => 'https://github.com/acme/repo101' } ],
    );
    my @requested_urls;
    *KohaPluginStore::GitHub::_get = sub {
        my ($url) = @_;
        push @requested_urls, $url;
        return _fake_tx( @{ shift @pages } );
    };

    my $repos = KohaPluginStore::GitHub::fetch_all_repos('fake-token');
    is( scalar @$repos, 101, 'both pages combined' );
    is( $repos->[100]{full_name}, 'acme/repo101', 'last repo present' );
    is( scalar @requested_urls,   2,              'stopped after the short page' );
    like( $requested_urls[0], qr/page=1/, 'first request is page 1' );
    like( $requested_urls[1], qr/page=2/, 'second request is page 2' );
};

subtest 'stops at the safety cap rather than looping forever' => sub {
    no strict 'refs';
    no warnings 'redefine';

    my $calls = 0;
    *KohaPluginStore::GitHub::_get = sub {
        $calls++;
        return _fake_tx( map { { full_name => "acme/r$_", html_url => "https://github.com/acme/r$_" } } 1 .. 100 );
    };

    my $repos = KohaPluginStore::GitHub::fetch_all_repos('fake-token');
    is( $calls, 20, 'capped at 20 pages' );
    is( scalar @$repos, 2000, '20 full pages returned' );
};

subtest 'a non-200 response stops pagination and returns what was gathered so far' => sub {
    no strict 'refs';
    no warnings 'redefine';

    my $call = 0;
    *KohaPluginStore::GitHub::_get = sub {
        $call++;
        return _fake_tx( { full_name => 'acme/repo1', html_url => 'https://github.com/acme/repo1' } ) if $call == 1;
        my $res = Mojo::Message::Response->new;
        $res->code(502);
        return bless { result => $res }, 'FakeTx';
    };

    my $repos = KohaPluginStore::GitHub::fetch_all_repos('fake-token');
    is_deeply( $repos, [ { full_name => 'acme/repo1', html_url => 'https://github.com/acme/repo1' } ], 'first page kept' );
};

done_testing();
