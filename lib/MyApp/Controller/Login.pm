package MyApp::Controller::Login;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub login {
    my $c        = shift;
    my $username = $c->param('username');
    my $password = $c->param('password');
    if ( MyApp::Model::Users->new(sqlite => $c->app->sqlite)->check_password( $username, $password ) ) {
        $c->session->{user} = MyApp::Model::Users->new( sqlite => $c->app->sqlite )->fetch($username);
        $c->redirect_to('/my-plugins');
    }
    $c->stash( invalid_login => 1 );
    $c->render('login');
}

sub register {
    my $c        = shift;
    my $username = $c->param('username');
    my $user     = {
        username => $username,
        password => $c->param('password'),
        email    => $c->param('email'),
    };
    warn Mojo::Util::dumper $user;
    unless ( eval { MyApp::Model::Users->new( sqlite => $c->app->sqlite )
              ->add_user($user); 1 } ) {
        $c->app->log->error($@) if $@;
        return $c->render( text => 'Could not create user', status => 400 );
    }
    $c->session->{user} = MyApp::Model::Users->new( sqlite => $c->app->sqlite )->fetch($username);
    $c->redirect_to('/');
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

1;
