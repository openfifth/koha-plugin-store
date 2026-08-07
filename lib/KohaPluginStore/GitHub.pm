package KohaPluginStore::GitHub;

use Modern::Perl;
use Mojo::UserAgent;

sub fetch_public_repos {
    my ($access_token) = @_;

    return [] unless $access_token;

    my $tx = Mojo::UserAgent->new->get(
        'https://api.github.com/user/repos?visibility=public&sort=updated&per_page=100' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return [] unless $tx->result->code == 200;

    my $repos = $tx->result->json;
    return [ map { { full_name => $_->{full_name}, html_url => $_->{html_url} } } @$repos ];
}

1;
