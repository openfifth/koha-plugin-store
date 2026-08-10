package KohaPluginStore::GitHub;

use Modern::Perl;
use Mojo::UserAgent;

my $PER_PAGE          = 100;
my $MAX_PAGES         = 20;
my $PLACEHOLDER_TOKEN = 'YOUR_TOKEN_HERE';

sub fetch_all_repos {
    my ($access_token) = @_;

    return [] unless $access_token;

    my @repos;
    for my $page ( 1 .. $MAX_PAGES ) {
        my $tx = _get(
            "https://api.github.com/user/repos?affiliation=owner,collaborator,organization_member"
              . "&sort=full_name&per_page=$PER_PAGE&page=$page",
            $access_token
        );

        last unless $tx->result->code == 200;

        my $batch = $tx->result->json;
        last unless $batch && @$batch;

        push @repos, map { { full_name => $_->{full_name}, html_url => $_->{html_url} } } @$batch;

        last if @$batch < $PER_PAGE;
    }

    return \@repos;
}

# Omits Authorization entirely rather than sending a bad/placeholder value --
# GitHub 401s on a bad token even for public data that would otherwise be
# served fine unauthenticated (just at a much lower, 60/hr rate limit).
sub _auth_header {
    my ($access_token) = @_;

    return () unless $access_token && $access_token ne $PLACEHOLDER_TOKEN;
    return ( Authorization => 'Bearer ' . $access_token );
}

# Test seam: overridden in tests to avoid real HTTP calls.
sub _get {
    my ( $url, $access_token ) = @_;

    return Mojo::UserAgent->new->get(
        $url => { Accept => 'application/vnd.github+json', _auth_header($access_token) }
    );
}

# Test seam, separate from _get: needs a different Accept header and UA option.
sub _get_binary {
    my ( $url, $access_token ) = @_;

    return Mojo::UserAgent->new( max_redirects => 5 )->get(
        $url => { Accept => 'application/octet-stream', _auth_header($access_token) }
    );
}

sub fetch_releases {
    my ( $access_token, $owner_repo ) = @_;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = _get( "$api_repo/releases?per_page=10", $access_token );

    return [] unless $tx->result->code == 200;

    return [ map { _trim_release($_) } @{ $tx->result->json } ];
}

sub fetch_release_by_tag {
    my ( $access_token, $owner_repo, $tag_name ) = @_;

    return unless $tag_name;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = _get( "$api_repo/releases/tags/$tag_name", $access_token );

    return unless $tx->result->code == 200;

    return _trim_release( $tx->result->json );
}

sub download_kpz {
    my ( $access_token, $download_url, $dest_path ) = @_;

    return unless $download_url;

    my $tx = _get_binary( $download_url, $access_token );

    return unless $tx->result->code == 200;

    $tx->result->content->asset->move_to($dest_path);
    return 1;
}

sub fetch_contributors {
    my ( $access_token, $owner_repo ) = @_;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = _get( "$api_repo/contributors?per_page=100", $access_token );

    return [] unless $tx->result->code == 200;

    return [
        map {
            {
                github_username     => $_->{login},
                avatar_url          => $_->{avatar_url},
                contributions_count => $_->{contributions},
            }
        } @{ $tx->result->json }
    ];
}

sub _trim_release {
    my ($release) = @_;

    return {
        tag_name     => $release->{tag_name},
        name         => $release->{name},
        published_at => $release->{published_at},
        author       => {
            login      => $release->{author}{login},
            avatar_url => $release->{author}{avatar_url},
        },
        assets => [
            map { { name => $_->{name}, browser_download_url => $_->{browser_download_url} } }
                @{ $release->{assets} }
        ],
    };
}

1;
