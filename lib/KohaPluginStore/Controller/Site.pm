package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Crypt::PK::Ed25519;
use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

sub index {
    my $c = shift;

    $c->render;
}

sub profile ($c) {
    $c->render;
}

sub checks ($c) {
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

sub author ($c) {
    my $author_slug = $c->param('author_slug');

    my $plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search_by_author_slug($author_slug);
    return $c->render( text => 'Author not found', status => 404 ) unless @$plugins;

    $c->stash( author_name => $plugins->[0]->author, plugins => $plugins );
    $c->render('site/author');
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

1;
