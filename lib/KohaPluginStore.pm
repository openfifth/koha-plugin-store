package KohaPluginStore;
use Mojo::Base 'Mojolicious', -signatures;
use Mojo::Pg;
use Mojolicious::Plugin::OAuth2;

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Task::ProcessPluginVersion;
use KohaPluginStore::Task::SyncPluginRelease;

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

    # Explicit, rotatable secret rather than relying on Mojolicious's
    # auto-generated per-process default -- without this, a restart
    # invalidates every session, and in a multi-process prefork deployment
    # each worker could in principle end up with a different secret.
    $self->secrets( $self->config->{secrets} ) if $self->config->{secrets};

    # Session cookie hardening. `secure` is gated on production mode so the
    # plain-HTTP dev Docker Compose setup (and KTD-style local testing)
    # still works -- browsers silently drop Secure cookies over HTTP.
    $self->sessions->secure(1) if $self->mode eq 'production';

    # SameSite=Lax on every outgoing cookie (Mojo::Cookie::Response has no
    # global default for this, so it's set per-response here rather than
    # per-cookie at each call site) -- defense in depth against CSRF
    # alongside the per-form csrf_token check, not a replacement for it: an
    # embedded webview or older client may not enforce SameSite at all.
    $self->hook(
        after_dispatch => sub {
            my $c = shift;
            $_->samesite('Lax') for @{ $c->res->cookies };
        }
    );

    # Validate signing_key_path configuration if present
    if ( my $key_path = $self->config->{signing_key_path} ) {
        unless ( -e $key_path && -r $key_path ) {
            $self->log->warn("Signing key path is configured but does not exist or is not readable: $key_path");
        }
    }

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
    KohaPluginStore::Task::ProcessPluginVersion::register($self);
    KohaPluginStore::Task::SyncPluginRelease::register($self);

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

    # Mojolicious::Plugin::OpenAPI auto-generates an OPTIONS responder for every
    # documented path (returning the path's own spec fragment) that never reaches
    # the controller -- list_all/verify's own CORS headers, set inside their own
    # sub bodies, never apply to a browser's CORS preflight OPTIONS request as a
    # result, only to the real GET. Setting the headers here, unconditionally, for
    # every response under /api/v1/plugins covers both cases without needing to
    # fight or disable OpenAPI's built-in OPTIONS handling.
    $self->hook(
        after_dispatch => sub {
            my $c = shift;
            return unless $c->req->url->path =~ m{^/api/v1/plugins(?:/|$)};
            $c->res->headers->header( 'Access-Control-Allow-Origin'   => '*' );
            $c->res->headers->header( 'Access-Control-Allow-Headers'  => 'content-type,x-koha-request-id' );
            $c->res->headers->header( 'Access-Control-Allow-Methods'  => 'get,options' );
            $c->res->headers->header( 'Access-Control-Expose-Headers' => 'X-Total-Count' );
        }
    );

    my $r = $self->routes;

    $r->any('/')->to('plugins#index');
    $r->any('/developers')->to('site#index');
    $r->get('/developers/checks')->to('site#checks');
    $r->get('/verification-key')->to('site#verification_key');
    $r->get('/authors/:author_slug')->to('site#author');
    $r->get('/profile')->requires( user_authenticated => 1 )->to('site#profile');
    $r->get('/login')->to( template => 'login' );
    $r->get('/auth/github')->to('auth#github');
    $r->get('/logout')->to('site#logout');
    $r->get('/my-plugins')->requires( user_authenticated => 1 )->to('plugins#my_plugins');
    $r->get('/new-plugin')->requires( user_authenticated => 1 )->to('plugins#add_form');
    $r->get('/new-plugin/bulk')->requires( user_authenticated => 1 )->to('plugins#bulk_form');
    $r->post('/developer/repos/refresh')->requires( user_authenticated => 1 )->to('plugins#refresh_repos');
    $r->get('/plugins/:slug')->to('plugins#show');

    # tag_name is constrained to allow '.' (e.g. 'v1.0.0') -- Mojolicious's default
    # placeholder pattern excludes '.' so it can detect a format extension on the
    # last path segment, which would otherwise truncate a dotted tag name.
    $r->get( '/plugins/:slug/v/:tag_name' => [ tag_name => qr/[^\/]+/ ] )->to('plugins#show_version');
    $r->get('/plugins/:slug/manage')->requires( user_authenticated => 1 )->to('plugins#manage');
    $r->post('/plugins/:slug/edit')->to('plugins#update_plugin');
    $r->post('/plugins/:slug/sync-releases')->requires( user_authenticated => 1 )->to('plugins#sync_releases_now');
    $r->post('/plugins/:slug/auto-sync')->requires( user_authenticated => 1 )->to('plugins#toggle_auto_sync');
    $r->post('/new-plugin')->to('plugins#new_plugin');
    $r->post('/new-plugin/bulk')->to('plugins#bulk_import');
    $r->post('/new-plugin-confirm')->to('plugins#new_plugin_confirm');
    $r->post('/new-release')->requires( user_authenticated => 1 )->to('releases#new_release');
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
