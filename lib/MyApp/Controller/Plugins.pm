package MyApp::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub list_all ($c) {
    my $plugins = $c->plugins->fetch_all();
    return $c->render( json => $plugins, status => 200 );
}

1;
