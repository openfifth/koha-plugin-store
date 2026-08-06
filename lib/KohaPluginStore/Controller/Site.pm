package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

sub index {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;
    $c->stash( plugins => \@plugins );
    $c->render;
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

1;
