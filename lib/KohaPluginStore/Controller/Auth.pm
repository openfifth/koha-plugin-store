package KohaPluginStore::Controller::Auth;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Developer;

sub github ($c) {
    if ( $c->app->config->{oauth_mock} ) {
        my $developer = KohaPluginStore::Model::Developer->new( pg => $c->pg )->find_or_create_from_oauth(
            {
                oauth_provider_key => 'github',
                provider_user_id   => 'mock',
                username           => 'mockdev',
                avatar_url         => undef,
            }
        );
        $c->log_in_developer($developer);
        return $c->redirect_to('/my-plugins');
    }

    $c->_get_oauth_token_p('github')->then(
        sub {
            my $provider_res = shift;
            return unless $provider_res; # plugin already redirected to GitHub

            return $c->render( text => 'GitHub login was not completed', status => 400 )
                unless $provider_res->{access_token};

            my $profile = $c->_fetch_github_profile( $provider_res->{access_token} );
            return $c->render( text => 'Could not fetch GitHub profile', status => 502 )
                unless $profile;

            my $developer = KohaPluginStore::Model::Developer->new( pg => $c->pg )->find_or_create_from_oauth(
                {
                    oauth_provider_key => 'github',
                    provider_user_id   => $profile->{id},
                    username           => $profile->{login},
                    avatar_url         => $profile->{avatar_url},
                }
            );

            $c->log_in_developer($developer);
            $c->redirect_to('/my-plugins');
        }
    )->catch(
        sub {
            my $err = shift;
            $c->app->log->error("GitHub OAuth failed: $err");
            $c->render( text => 'GitHub login failed', status => 502 );
        }
    );
}

sub _get_oauth_token_p {
    my ( $c, $provider ) = @_;
    return $c->oauth2->get_token_p($provider);
}

sub _fetch_github_profile {
    my ( $c, $access_token ) = @_;

    my $tx = Mojo::UserAgent->new->get(
        'https://api.github.com/user' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $access_token,
        }
    );

    return unless $tx->result->code == 200;

    return $tx->result->json;
}

1;
