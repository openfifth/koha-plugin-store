package KohaPluginStore::Controller::Api;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub ping ($c) {
    return $c->render( openapi => { status => 'ok' } );
}

1;
