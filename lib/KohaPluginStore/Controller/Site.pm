package KohaPluginStore::Controller::Site;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::User;

sub index {
    my $c = shift;

    my @users = KohaPluginStore::Model::User->new()->search;
    my @plugins = KohaPluginStore::Model::Plugin->new()->search;
    $c->stash( plugins => \@plugins );
    $c->stash( users   => \@users );
    $c->render;
}

sub login {
    my $c        = shift;
    my $username = $c->param('username');
    my $password = $c->param('password');

    if (
        KohaPluginStore::Model::User::check_password(
            $username, $password
        )
      )
    {
        $c->_log_in_user($username);
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
    unless (
        eval {
            KohaPluginStore::Model::User->new()->create($user);
            1;
        }
      )
    {
        $c->app->log->error($@) if $@;
        return $c->render( text => 'Could not create user', status => 400 );
    }
    $c->_log_in_user($username);
    $c->redirect_to('/');
}

sub logout {
    my $c = shift;
    $c->session( expires => 1 );
    $c->redirect_to('/');
}

sub _log_in_user {
    my $c = shift;
    my $username = shift;
    my $user = KohaPluginStore::Model::User->new->find(
        { username => $username } );
    $c->session->{user} = $user->unblessed;
}
1;
