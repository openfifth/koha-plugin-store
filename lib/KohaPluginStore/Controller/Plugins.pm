package KohaPluginStore::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;
use KohaPluginStore::GitHub;
use JSON;

sub index {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;
    $c->stash( plugins => \@plugins );
    $c->render;
}

sub my_plugins {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search( { developer_id => $c->session->{developer}->{id} } );
    $c->stash( my_plugins => \@plugins );

    my $template = $c->session->{developer} ? 'my-plugins' : 'unauthorized';
    $c->render($template);
}

sub add_form {
    my $c = shift;

    my $template = $c->session->{developer} ? 'new-plugin' : 'unauthorized';
    if ( $template eq 'new-plugin' ) {
        my $developer = $c->logged_in_user;
        unless ( defined $developer->data->{cached_repos} ) {
            my $repos = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
            $developer->refresh_cached_repos($repos);
        }
        $c->stash(
            repos            => $developer->cached_repos,
            repos_fetched_at => $developer->cached_repos_fetched_at,
        );
    }
    $c->render($template);
}

sub refresh_repos {
    my $c = shift;

    my $developer = $c->logged_in_user;
    my $repos      = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
    $developer->refresh_cached_repos($repos);

    $c->redirect_to('/new-plugin');
}

sub edit_form {
    my $c = shift;

    my $plugin_id = $c->param('id');
    my $plugin    = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find(
        {
            id => $plugin_id,
        }
    );

    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized',     status => 401 ) unless $c->session->{developer}->{id} == $plugin->developer_id;

    my $config          = $c->app->plugin('Config');
    my $github_releases = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin->repo_url );

    my $existing_tags = { map { $_->tag_name => 1 } @{ $plugin->releases } };

    foreach my $release (@$github_releases) {
        if ( $existing_tags->{ $release->{tag_name} } ) {
            $release->{message}->{success} = 'Release has already been submitted.';
            next;
        }

        my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
        if ( scalar @kpz_assets != 1 ) {
            $release->{message}->{error} = 'Release must contain one and only one \'.kpz\' asset.';
        }
    }

    $c->stash( plugin          => $plugin );
    $c->stash( github_releases => $github_releases );
    $c->render('plugins/edit');
}

sub show ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'id' } }
    );
    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'contributions_count' } }
    );

    my $still_processing = grep { $_->status eq 'submitted' || $_->status eq 'checks_running' } @versions;

    $c->stash(
        plugin           => $plugin,
        versions         => \@versions,
        contributors     => \@contributors,
        still_processing => $still_processing,
    );
    $c->render('plugins/show');
}

sub list_all ($c) {
    my $koha_version_release = $c->param('koha_version_release');

    return $c->render( text => 'koha_version_release required', status => 400 ) unless $koha_version_release;

    my @plugins = map { $_->unblessed } KohaPluginStore::Model::Plugin->new( pg => $c->pg )->search;

    foreach my $plugin (@plugins) {
        my @releases =
            map { $_->unblessed } KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
                { plugin_id => $plugin->{id} }, { order_by => { -desc => 'date_released' } }
            );

        foreach my $release (@releases) {
            next if( $release->{koha_min_version} > $koha_version_release );
            push(
                @{ $plugin->{releases} },
                $release
            );
        }

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }

    # The following is required for CORS
    # Without this, users won't be able to list from remote locations
    $c->res->headers->header( 'Access-Control-Allow-Origin'  => '*' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type,x-koha-request-id' );
    $c->res->headers->header( 'Access-Control-Allow-Methods' => 'get,options' );

    return $c->render( json => \@plugins, status => 200 );
}

sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');

    my $developer_repos = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
    my $repo_is_owned   = grep { $_->{html_url} eq $plugin_repo } @$developer_repos;
    return $c->_exit_with_error_message(
        'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
    ) unless $repo_is_owned;

    my $config   = $c->app->plugin('Config');
    my $releases = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin_repo );
    return $c->_exit_with_error_message('Could not fetch releases from GitHub for this repository.')
        unless @$releases;

    for my $release (@$releases) {
        my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
        if ( scalar @kpz_assets == 1 ) {
            $release->{eligible} = 1;
        }
        else {
            $release->{eligible}         = 0;
            $release->{ineligible_reason} =
                'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets;
        }
    }

    $c->stash( plugin_repo => $plugin_repo, releases => $releases );
    $c->render('new-plugin-step2');
}

sub new_plugin_confirm ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $tag_name    = $c->param('tag_name');

    unless ( $c->session->{developer} ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    my $developer_repos = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
    my $repo_is_owned   = grep { $_->{html_url} eq $plugin_repo } @$developer_repos;
    return $c->_exit_with_error_message(
        'That repository is not in the list of your public GitHub repositories. Please pick one from the dropdown.'
    ) unless $repo_is_owned;

    my $config  = $c->app->plugin('Config');
    my $token   = $config->{github_app_token};
    my $release = KohaPluginStore::GitHub::fetch_release_by_tag( $token, $plugin_repo, $tag_name );
    return $c->_exit_with_error_message('Could not re-fetch that release from GitHub. Please try again.')
        unless $release;

    my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
    return $c->_exit_with_error_message(
        'Release must contain one and only one \'.kpz\' asset. Found: ' . scalar @kpz_assets )
        unless scalar @kpz_assets == 1;

    my ($repo_name) = $plugin_repo =~ m{([^/]+)/?$};

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->create_with_unique_slug(
        $repo_name,
        {
            repo_url     => $plugin_repo,
            developer_id => $c->session->{developer}->{id},
        }
    );

    my $new_version = eval {
        KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->create(
            {
                plugin_id         => $plugin->id,
                tag_name          => $release->{tag_name},
                name              => $release->{name},
                date_released     => $release->{published_at},
                kpz_url           => $kpz_assets[0]->{browser_download_url},
                author_username   => $release->{author}->{login},
                author_avatar_url => $release->{author}->{avatar_url},
                status            => 'submitted',
            }
        );
    };
    return $c->_exit_with_error_message('That release has already been submitted.')
        if !$new_version && $@ =~ /plugin_versions_plugin_id_tag_name_key/;
    die $@ if !$new_version;

    $c->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}

sub _exit_with_error_message {
    my ( $c, $error_message ) = @_;
    $c->stash( errors => [$error_message] );
    return $c->render('new-plugin-step2');
}

1;
