package MyApp::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub list_all ($c) {
    my $plugins = $c->plugins;

    # The following is required for CORS. Dev only (?)
    $c->res->headers->header( 'Access-Control-Allow-Origin' => 'http://localhost:8081' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'x-koha-request-id' );

    return $c->render( json => $plugins, status => 200 );
}

1;
