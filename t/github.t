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
    is_deeply( $repos, [ { full_name => 'acme/repo1', html_url => 'https://github.com/acme/repo1', permissions => undef } ], 'first page kept' );
};

subtest 'fetch_all_repos captures each repo\'s permissions object' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body( Mojo::JSON::encode_json( [
            {
                full_name   => 'octocat/Hello-World',
                html_url    => 'https://github.com/octocat/Hello-World',
                permissions => { admin => 0, maintain => 0, push => 1, triage => 1, pull => 1 },
            },
        ] ) );
        return bless { result => $res }, 'FakeTx';
    };

    my $repos = KohaPluginStore::GitHub::fetch_all_repos('token');
    is( scalar @$repos, 1 );
    is_deeply(
        $repos->[0],
        {
            full_name   => 'octocat/Hello-World',
            html_url    => 'https://github.com/octocat/Hello-World',
            permissions => { admin => 0, maintain => 0, push => 1, triage => 1, pull => 1 },
        }
    );
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

subtest 'fetch_tag_verification reports a signed annotated tag as verified, independent of its commit' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my ($url) = @_;
        if ( $url =~ m{/git/refs/tags/} ) {
            return _fake_release_tx( { object => { sha => 'tagsha123', type => 'tag' } } );
        }
        if ( $url =~ m{/git/tags/tagsha123} ) {
            # The tag object itself is signed -- deliberately not asked about
            # the underlying commit's own (possibly unsigned) verification.
            return _fake_release_tx( { verification => { verified => 1 } } );
        }
        die "unexpected URL: $url";
    };

    is( KohaPluginStore::GitHub::fetch_tag_verification( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 1, 'reports verified' );
};

subtest 'fetch_tag_verification reports an unsigned annotated tag as unverified' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my ($url) = @_;
        if ( $url =~ m{/git/refs/tags/} ) {
            return _fake_release_tx( { object => { sha => 'tagsha123', type => 'tag' } } );
        }
        if ( $url =~ m{/git/tags/tagsha123} ) {
            return _fake_release_tx( { verification => { verified => 0 } } );
        }
        die "unexpected URL: $url";
    };

    is( KohaPluginStore::GitHub::fetch_tag_verification( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 0, 'reports unverified' );
};

subtest 'fetch_tag_verification falls back to the commit for a lightweight tag' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my ($url) = @_;
        if ( $url =~ m{/git/refs/tags/} ) {
            return _fake_release_tx( { object => { sha => 'commitsha456', type => 'commit' } } );
        }
        if ( $url =~ m{/commits/commitsha456} ) {
            return _fake_release_tx( { commit => { verification => { verified => 1 } } } );
        }
        die "unexpected URL: $url";
    };

    is( KohaPluginStore::GitHub::fetch_tag_verification( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 1, 'reports the commit\'s own verification' );
};

subtest 'fetch_tag_verification returns undef on a non-200 response' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_tag_verification( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), undef, 'returns undef' );
};

subtest 'fetch_tag_has_test_files finds a t/*.t file at the tree root' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my ($url) = @_;
        if ( $url =~ m{/git/trees/v1\.0\.0} ) {
            return _fake_release_tx(
                {
                    tree => [
                        { path => 't/basic.t', type => 'blob' },
                        { path => 'Widget.pm', type => 'blob' },
                    ]
                }
            );
        }
        die "unexpected URL: $url";
    };

    is( KohaPluginStore::GitHub::fetch_tag_has_test_files( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 1, 'found' );
};

subtest 'fetch_tag_has_test_files finds a t/*.t file nested under the plugin module directory' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        return _fake_release_tx( { tree => [ { path => 'Koha/Plugin/Com/Example/Widget/t/basic.t', type => 'blob' } ] } );
    };

    is( KohaPluginStore::GitHub::fetch_tag_has_test_files( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 1, 'found' );
};

subtest 'fetch_tag_has_test_files does not match a .t file that just happens to sit outside a t/ directory' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        return _fake_release_tx( { tree => [ { path => 'Koha/Plugin/Com/Example/Widget/stray.t', type => 'blob' } ] } );
    };

    is( KohaPluginStore::GitHub::fetch_tag_has_test_files( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 0, 'not found' );
};

subtest 'fetch_tag_has_test_files ignores a tree entry named t (not a blob)' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        return _fake_release_tx( { tree => [ { path => 't', type => 'tree' } ] } );
    };

    is( KohaPluginStore::GitHub::fetch_tag_has_test_files( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 0, 'not found' );
};

subtest 'fetch_tag_has_test_files returns 0 when the tree has no matches' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        return _fake_release_tx( { tree => [ { path => 'Widget.pm', type => 'blob' } ] } );
    };

    is( KohaPluginStore::GitHub::fetch_tag_has_test_files( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), 0, 'not found' );
};

subtest 'fetch_tag_has_test_files returns undef on a non-200 response' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_tag_has_test_files( 'token', 'https://github.com/dev/widget', 'v1.0.0' ), undef, 'returns undef' );
};

subtest 'fetch_tag_has_test_files requires a tag_name but not a token' => sub {
    is(
        KohaPluginStore::GitHub::fetch_tag_has_test_files( undef, 'https://github.com/dev/widget', undef ), undef,
        'returns undef without a tag, and without making a request'
    );
};

subtest 'fetch_readme_html returns the raw HTML body on success' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_readme = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body('<h1>Widget</h1><p>Docs.</p>');
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_readme_html( 'token', 'https://github.com/dev/widget' ),
        '<h1>Widget</h1><p>Docs.</p>',
        'raw pre-rendered HTML returned as-is, not JSON-decoded'
    );
};

subtest 'fetch_readme_html returns undef on a non-200 response (no README, rate-limited, ...)' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_readme = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_readme_html( 'token', 'https://github.com/dev/widget' ), undef, 'undef, not a die' );
};

subtest 'fetch_readme_html still makes a request with no token configured' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_args;
    *KohaPluginStore::GitHub::_get_readme = sub { push @seen_args, [@_]; return _fake_tx(); };

    KohaPluginStore::GitHub::fetch_readme_html( undef, 'https://github.com/a/b' );
    is( scalar @seen_args, 1, 'the request was made' );
    is( $seen_args[0][1], undef, 'with no token' );
};

subtest 'fetch_changelog_html tries CHANGELOG.md first and returns its HTML body on success' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_paths;
    *KohaPluginStore::GitHub::_get_readme = sub {
        my ($url) = @_;
        push @seen_paths, $url;
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body('<h2>1.0.0</h2><p>Initial release.</p>');
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_changelog_html( 'token', 'https://github.com/dev/widget' ),
        '<h2>1.0.0</h2><p>Initial release.</p>',
        'raw pre-rendered HTML returned as-is'
    );
    is( $seen_paths[0], 'https://api.github.com/repos/dev/widget/contents/CHANGELOG.md', 'CHANGELOG.md tried first' );
    is( scalar @seen_paths, 1, 'stops after the first successful path' );
};

subtest 'fetch_changelog_html falls back to CHANGES.md when CHANGELOG.md is missing' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_paths;
    *KohaPluginStore::GitHub::_get_readme = sub {
        my ($url) = @_;
        push @seen_paths, $url;
        my $res = Mojo::Message::Response->new;
        $res->code( $url =~ /CHANGES\.md/ ? 200 : 404 );
        $res->body('<h2>1.0.0</h2>') if $url =~ /CHANGES\.md/;
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_changelog_html( 'token', 'https://github.com/dev/widget' ),
        '<h2>1.0.0</h2>'
    );
    is_deeply(
        \@seen_paths,
        [
            'https://api.github.com/repos/dev/widget/contents/CHANGELOG.md',
            'https://api.github.com/repos/dev/widget/contents/CHANGES.md',
        ],
        'both paths tried, in order'
    );
};

subtest 'fetch_changelog_html returns undef when neither file exists' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_readme = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_changelog_html( 'token', 'https://github.com/dev/widget' ), undef );
};

done_testing();
