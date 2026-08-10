package KohaPluginStore;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Pg;
use Mojolicious::Plugin::OAuth2;

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;

has site_name => sub {
    my $app = shift;
    return $app->config->{site_name} || 'Koha Plugin Store';
};

has pg => sub {
    my $self = shift;
    return Mojo::Pg->new( $self->config->{pg_dsn} );
};

sub startup ($self) {

    $self->plugin('Config');

    my %oauth2_providers;
    for my $provider ( @{ $self->config->{oauth_providers} || [] } ) {
        if ( $provider->{kind} eq 'github' ) {
            $oauth2_providers{ $provider->{key} } = {
                key    => $provider->{client_id},
                secret => $provider->{client_secret},
            };
        }
    }
    $self->plugin( OAuth2 => \%oauth2_providers );

    $self->plugin( Minion => { Pg => $self->pg } );

    push @{ $self->commands->namespaces }, 'KohaPluginStore::Command';

    $self->helper( pg => sub { shift->app->pg } );

    $self->helper(
        logged_in_user => sub {
            my ( $c, $developer ) = @_;
            $developer ||= $c->stash->{developer} || $c->session->{developer};
            return unless $developer;
            return KohaPluginStore::Model::Developer->new( pg => $c->pg )->find( { id => $developer->{id} } )
              || undef;
        }
    );

    $self->helper(
        log_in_developer => sub {
            my ( $c, $developer, $access_token ) = @_;

            # Only the id -- never the whole row. logged_in_user() always re-fetches
            # fresh from the DB anyway, and the session cookie is capped at 4KiB by
            # Mojolicious, so storing more risks silently losing the session.
            $c->session->{developer} = { id => $developer->id };
            $c->session->{github_access_token} = $access_token if $access_token;
        }
    );

    $self->_add_routes_authorization();

    $self->plugin( 'OpenAPI', {
        url      => $self->home->child(qw(lib KohaPluginStore OpenAPI spec.yaml)),
        route    => $self->routes->any('/api/v1'),
        security => {
            session_auth => sub {
                my ( $c, $definition, $scopes, $cb ) = @_;
                return $c->$cb() if $c->session->{developer};
                return $c->$cb('Not logged in');
            },
        },
    } );

    my $r = $self->routes;

    $r->any('/')->to('site#index');
    $r->any('/plugins')->to('plugins#index');
    $r->get('/login')->to( template => 'login' );
    $r->get('/auth/github')->to('auth#github');
    $r->get('/logout')->to('site#logout');
    $r->get('/my-plugins')->requires( user_authenticated => 1 )->to('plugins#my_plugins');
    $r->get('/new-plugin')->requires( user_authenticated => 1 )->to('plugins#add_form');
    $r->post('/developer/repos/refresh')->requires( user_authenticated => 1 )->to('plugins#refresh_repos');
    $r->get('/plugins/edit/:id')->requires( user_authenticated => 1 )->to('plugins#edit_form');
    $r->post('/new-plugin')->to('plugins#new_plugin');
    $r->post('/new-plugin-confirm')->to('plugins#new_plugin_confirm');
    $r->post('/new-release')->requires( user_authenticated => 1 )->to('releases#new_release');

    #TODO: Use OpenAPI mojolicious plugin?
    $r->any('/api/plugins')->to('plugins#list_all');
}

sub _add_routes_authorization {
	my $self = shift;

    $self->routes->add_condition(
    	user_authenticated => sub {
    	my ( $r, $c ) = @_;

        if ( defined(  $c->session->{developer}->{id} ) ) {
            return 1;
        }

        #TODO: This is currently returning 404. It'd be cool if we could return 401 instead
        return;
    })
}

1;
