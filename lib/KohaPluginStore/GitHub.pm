package KohaPluginStore::GitHub;

use Modern::Perl;
use Mojo::UserAgent;

my $PER_PAGE  = 100;
my $MAX_PAGES = 20;

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

# Test seam: overridden in tests to avoid real HTTP calls.
sub _get {
    my ( $url, $access_token ) = @_;

    return Mojo::UserAgent->new->get(
        $url => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );
}

1;
