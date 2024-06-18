package MyApp;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::SQLite;

use MyApp::Model::Users;
use MyApp::Model::Plugins;

has site_name => sub {
    my $app = shift;
    return $app->config->{site_name} || 'Koha Plugin Store';
};

sub startup ($self) {

    $self->helper(
        logged_in_user => sub {
            my ( $c, $user ) = @_;
            $user ||= $c->stash->{user} || $c->session->{user};
            return unless $user;
            return MyApp::Model::Users->new( sqlite => $c->app->sqlite )
              ->fetch($user->{username}) || undef;
        }
    );

    $self->helper(
        sqlite => sub { state $sql = Mojo::SQLite->new('sqlite:database.db') }
    );

    $self->helper(
        users => sub {
            my $c = shift;
            state $users =
              MyApp::Model::Users->new( sqlite => $c->app->sqlite )
              ->fetch_all();
        }
    );
    $self->helper(
        plugins => sub {
            my $c = shift;
            state $plugins =
            MyApp::Model::Plugins->new( sqlite => $c->app->sqlite )
              ->fetch_all();
        }
    );

    $self->helper(
        plugins => sub {
            my $c = shift;
            state $plugins =
                MyApp::Model::Plugins->new( sqlite => $c->app->sqlite )
                ->fetch_all();
        }
    );

    my $r = $self->routes;
    # $r->any('/')->to('login#index')->name('index');

    # my $logged_in = $r->under('/')->to('login#logged_in');
    # $logged_in->get('/protected')->to('login#protected');


    $r->any('/')->to( template => 'index' );
    $r->any('/plugins')->to( template => 'plugins');
    $r->any('/users')->to( template => 'users' );
    $r->get('/login')->to( template => 'login' );
    $r->post('/login')->to( 'login#login' );
    $r->get('/register')->to( template => 'register' );
    $r->post('/register')->to('login#register');
    $r->get('/logout')->to('login#logout');

    $r->get(
        '/my-plugins' => sub {
            my $c        = shift;
            my $template = $c->session->{user} ? 'my-plugins' : 'unauthorized';
            $c->stash(
                my_plugins =>
                  MyApp::Model::Plugins->new( sqlite => $c->app->sqlite )->fetch_all( $c->session->{user}->{id} )
            );
            $c->render($template);
        }
    );

    $r->get(
        '/new-plugin' => sub {
            my $c        = shift;
            my $template = $c->session->{user} ? 'new-plugin' : 'unauthorized';
            $c->render($template);
        }
    );
    $r->post('/new-plugin')->to('plugins#new_plugin');

    #TODO: Use OpenAPI mojolicious plugin?
    $r->get('/api/plugins')->to('plugins#list_all');
    $r->options('/api/plugins')->to('plugins#list_all');

}

1;
