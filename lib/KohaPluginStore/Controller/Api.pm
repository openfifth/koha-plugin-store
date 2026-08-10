package KohaPluginStore::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub ping ($c) {
    return $c->render( openapi => { status => 'ok' } );
}

sub developer_repos ($c) {
    my $developer = $c->logged_in_user;
    return $c->render( openapi => { repos => $developer->cached_repos || [] } );
}

1;
