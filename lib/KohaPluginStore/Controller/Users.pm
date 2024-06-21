package KohaPluginStore::Controller::Users;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use KohaPluginStore::Model::Users;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::Users->new()->search;
    $c->stash( users => \@users );
    $c->render;
}

1;
