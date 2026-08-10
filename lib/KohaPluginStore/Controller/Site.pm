package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Developer;

sub index {
    my $c = shift;

    $c->render;
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

1;
