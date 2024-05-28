package MyApp;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::SQLite;

use MyApp::Model::Users;
use MyApp::Model::Plugins;

sub startup ($self) {

    $self->secrets( ['Mojolicious rocks'] );
    $self->helper( users => sub { state $users = MyApp::Model::Users->new } );

    $self->helper(
        sqlite => sub { state $sql = Mojo::SQLite->new('sqlite:database.db') }
    );
    $self->helper(
        plugins => sub {
            state $plugins = MyApp::Model::Plugins->new(
                sqlite => shift->sqlite );
        }
    );

    my $r = $self->routes;
    # $r->any('/')->to('login#index')->name('index');

    # my $logged_in = $r->under('/')->to('login#logged_in');
    # $logged_in->get('/protected')->to('login#protected');

    # $r->get('/logout')->to('login#logout');

    $r->get('/plugins')->to('plugins#list_all');

}

1;
