package KohaPluginStore::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::GitHub;

sub ping ($c) {
    return $c->render( openapi => { status => 'ok' } );
}

sub developer_repos ($c) {
    my $repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
    return $c->render( openapi => { repos => $repos } );
}

1;
