package MyApp::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub list_all ($self) {
    my $plugins = $self->plugins->fetch_all();
    $self->stash( plugins => $plugins );
    $self->render();
}

1;
