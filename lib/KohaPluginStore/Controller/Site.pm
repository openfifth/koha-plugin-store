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

sub login {
    my $c        = shift;
    my $username = $c->param('username');
    my $password = $c->param('password');

    my $user = KohaPluginStore::Model::Developer->new( pg => $c->pg )->find( { username => $username } );

    if ( $user && $user->check_password($password) ) {
        $c->_log_in_user($user);
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
    my $created_user;
    unless (
        eval {
            $created_user = KohaPluginStore::Model::Developer->new( pg => $c->pg )->create($user);
            1;
        }
      )
    {
        $c->app->log->error($@) if $@;
        return $c->render( text => 'Could not create user', status => 400 );
    }
    $c->_log_in_user($created_user);
    $c->redirect_to('/');
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

sub _log_in_user {
    my ( $c, $user ) = @_;
    $c->session->{user} = $user->unblessed;
}
1;
