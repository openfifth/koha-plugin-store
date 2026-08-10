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

sub _fake_release_tx {
    my ($release) = @_;
    my $res = Mojo::Message::Response->new;
    $res->code(200);
    $res->body( encode_json($release) );
    return bless { result => $res }, 'FakeTx';
}

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

subtest '_auth_header omits Authorization when no usable token is configured' => sub {
    is_deeply( [ KohaPluginStore::GitHub::_auth_header(undef) ], [], 'undef' );
    is_deeply( [ KohaPluginStore::GitHub::_auth_header('') ], [], 'empty string' );
    is_deeply( [ KohaPluginStore::GitHub::_auth_header('YOUR_TOKEN_HERE') ], [], 'unfilled-in placeholder from the .conf.example templates' );
};

subtest '_auth_header includes Authorization for a real token' => sub {
    is_deeply( [ KohaPluginStore::GitHub::_auth_header('real-token') ], [ Authorization => 'Bearer real-token' ] );
};

# These calls read public data -- GitHub serves it unauthenticated, just at a much
# lower rate limit (60/hr vs 5000/hr). Not having github_app_token configured (or
# still having the unfilled-in placeholder) shouldn't make the app stop working,
# so these functions must still attempt the request rather than short-circuiting.
subtest 'fetch_releases still makes a request with no token configured' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_args;
    *KohaPluginStore::GitHub::_get = sub { push @seen_args, [@_]; return _fake_tx(); };

    KohaPluginStore::GitHub::fetch_releases( undef, 'https://github.com/a/b' );
    is( scalar @seen_args, 1, 'the request was made' );
    is( $seen_args[0][1], undef, 'with no token' );
};

subtest 'fetch_release_by_tag requires a tag_name but not a token' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my $calls = 0;
    *KohaPluginStore::GitHub::_get = sub {
        $calls++;
        return _fake_release_tx( { tag_name => 'v1.0.0', name => 'v1.0.0', assets => [] } );
    };

    is( KohaPluginStore::GitHub::fetch_release_by_tag( undef, 'https://github.com/a/b', undef ), undef, 'no tag_name' );
    is( $calls, 0, 'request skipped without a tag_name' );

    KohaPluginStore::GitHub::fetch_release_by_tag( undef, 'https://github.com/a/b', 'v1.0.0' );
    is( $calls, 1, 'request made once a tag_name is given, even with no token' );
};

subtest 'download_kpz requires a download_url but not a token' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my $calls = 0;
    *KohaPluginStore::GitHub::_get_binary = sub { $calls++; return _fake_tx(); };

    is( KohaPluginStore::GitHub::download_kpz( undef, undef, '/tmp/x.kpz' ), undef, 'no download_url' );
    is( $calls, 0, 'request skipped without a download_url' );
};

subtest 'download_kpz still makes a request with no token configured' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_args;
    *KohaPluginStore::GitHub::_get_binary = sub {
        push @seen_args, [@_];
        my $res = Mojo::Message::Response->new;
        $res->code(502);    # short-circuits before touching the (unfaked) asset/move_to path
        return bless { result => $res }, 'FakeTx';
    };

    KohaPluginStore::GitHub::download_kpz( undef, 'https://example.com/x.kpz', '/tmp/x.kpz' );
    is( scalar @seen_args, 1, 'the request was made' );
    is( $seen_args[0][1], undef, 'with no token' );
};

subtest 'fetch_contributors still makes a request with no token configured' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my $calls = 0;
    *KohaPluginStore::GitHub::_get = sub { $calls++; return _fake_tx(); };

    KohaPluginStore::GitHub::fetch_contributors( undef, 'https://github.com/a/b' );
    is( $calls, 1, 'the request was made' );
};

done_testing();
