package KohaPluginStore::Controller::Users;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use KohaPluginStore::Model::User;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::User->new()->search();

    $c->stash( users => \@users );
    $c->render;
}

1;
