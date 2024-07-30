package KohaPluginStore;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::SQLite;

use KohaPluginStore::Model::User;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Schema;
use KohaPluginStore::Model::DB;

has site_name => sub {
    my $app = shift;
    return $app->config->{site_name} || 'Koha Plugin Store';
};

sub startup ($self) {

    $self->{_dbh} = KohaPluginStore::Model::DB->new();

    $self->helper(
        logged_in_user => sub {
            my ( $c, $user ) = @_;
            $user ||= $c->stash->{user} || $c->session->{user};
            return unless $user;
            return KohaPluginStore::Model::User->new()->find( { username => $user->{username} } )
              || undef;
        }
    );

    $self->helper(
        sqlite => sub { state $sql = Mojo::SQLite->new('sqlite:database.db') }
    );

    my $r = $self->routes;

    $r->any('/')->to('site#index');
    $r->any('/plugins')->to('plugins#index');
    $r->any('/users')->to('users#index');
    $r->get('/login')->to( template => 'login' );
    $r->post('/login')->to('site#login');
    $r->get('/register')->to( template => 'register' );
    $r->post('/register')->to('site#register');
    $r->get('/logout')->to('site#logout');
    $r->get('/my-plugins')->to('plugins#my_plugins');
    $r->get('/new-plugin')->to('plugins#add_form');
    $r->get('/plugins/edit/:id')->to('plugins#edit_form');
    $r->post('/new-plugin')->to('plugins#new_plugin');
    $r->post('/new-plugin-confirm')->to('plugins#new_plugin_confirm');

    #TODO: Use OpenAPI mojolicious plugin?
    $r->get('/api/plugins')->to('plugins#list_all');
    $r->options('/api/plugins')->to('plugins#list_all');

}

1;
