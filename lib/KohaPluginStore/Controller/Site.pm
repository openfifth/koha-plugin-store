package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Crypt::PK::Ed25519;
use KohaPluginStore::Model::Developer;

sub index {
    my $c = shift;

    $c->render;
}

sub profile ($c) {
    $c->render;
}

sub verification_key ($c) {
    my $key_path = $c->app->config->{signing_key_path};

    my $public_key_pem;
    if ( $key_path && -e $key_path && -r $key_path ) {
        $public_key_pem = eval { Crypt::PK::Ed25519->new($key_path)->export_key_pem('public') };
    }

    $c->stash( public_key => $public_key_pem );
    $c->render;
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

1;
