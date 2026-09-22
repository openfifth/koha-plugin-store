package KohaPluginStore::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;
use KohaPluginStore::Model::ReviewCheck;
use KohaPluginStore::GitHub;
use JSON;

sub index {
    my $c = shift;

    my $q                  = $c->param('q');
    my $order_by           = $c->param('_order_by') || 'name';
    my $certification_tier = $c->param('certification_tier');
    my $page               = $c->param('_page') || 1;
    my $per_page           = 24;

    my $args = {
        q                   => $q,
        order_by            => $order_by,
        certification_tier  => $certification_tier,
        include_unsupported => 1,
    };

    my $plugin_model = KohaPluginStore::Model::Plugin->new( pg => $c->pg );
    my $total        = $plugin_model->count_compatible($args);
    my $plugins      = $plugin_model->search_compatible(
        { %$args, limit => $per_page, offset => ( $page - 1 ) * $per_page }
    );

    my $total_pages = int( ( $total + $per_page - 1 ) / $per_page );

    $c->stash(
        plugins            => $plugins,
        q                  => $q,
        order_by           => $order_by,
        certification_tier => $certification_tier,
        page               => $page,
        total_pages        => $total_pages,
    );
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

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    my $developer = $c->logged_in_user;
    my $repos      = KohaPluginStore::GitHub::fetch_all_repos( $c->session->{github_access_token} );
    $developer->refresh_cached_repos($repos);

    $c->redirect_to('/new-plugin');
}


sub _plugin_page_stash {
    my ( $c, $plugin ) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'id' } }
    );
    my @contributors = KohaPluginStore::Model::PluginContributor->new( pg => $c->pg )->search(
        { plugin_id => $plugin->id }, { order_by => { -desc => 'contributions_count' } }
    );

    my $still_processing = grep { $_->status eq 'submitted' || $_->status eq 'checks_running' } @versions;

    my %checks_by_version;
    if (@versions) {
        # search()'s default_query_params applies a limit => 10 unless overridden --
        # fine for a paginated listing, but here we want every check for every version
        # on this page. Each version has a fixed, small number of checks (currently 11),
        # so a generous fixed limit comfortably covers any plugin's full version history.
        my @checks = KohaPluginStore::Model::ReviewCheck->new( pg => $c->pg )->search(
            { plugin_version_id => [ map { $_->id } @versions ] }, { order_by => 'check_name', limit => 1000 }
        );
        push @{ $checks_by_version{ $_->plugin_version_id } }, $_ for @checks;
    }

    my $is_owner = $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id ? 1 : 0;

    my $github_releases;
    if ($is_owner) {
        my $config = $c->app->plugin('Config');
        $github_releases = KohaPluginStore::GitHub::fetch_releases( $config->{github_app_token}, $plugin->repo_url );

        my $existing_tags = { map { $_->tag_name => 1 } @versions };
        # Annotate each release with submission status; no-op if github_releases is empty.
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
    }

    return {
        plugin            => $plugin,
        versions          => \@versions,
        contributors      => \@contributors,
        still_processing  => $still_processing,
        checks_by_version => \%checks_by_version,
        is_owner          => $is_owner,
        github_releases   => $github_releases,
    };
}

sub show ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;

    $c->stash( %{ $c->_plugin_page_stash($plugin) } );
    $c->render('plugins/show');
}

sub update_plugin ($c) {
    my $slug = $c->param('slug');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { slug => $slug } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer} && $c->session->{developer}->{id} == $plugin->developer_id;

    # Checked after the ownership check, not before -- an unauthenticated or
    # non-owner request is already rejected on its own merits above, and a
    # 404/401 there shouldn't become a CSRF-shaped 403 instead.
    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

    my %fields = map { $_ => $c->param($_) } qw(name description repo_url author issue_tracker_url);

    for my $field (qw(name description repo_url author)) {
        next if defined $fields{$field} && length $fields{$field};

        $c->stash( %{ $c->_plugin_page_stash($plugin) } );
        $c->stash( errors => ['All fields are required.'], form_values => \%fields );
        return $c->render('plugins/show');
    }

    $plugin->update( \%fields );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}

sub list_all ($c) {
    my $koha_version = $c->param('koha_version');

    return $c->render( openapi => { error => 'koha_version required' }, status => 400 ) unless $koha_version;

    my $q                   = $c->param('q');
    my $page                = $c->param('_page') || 1;
    my $per_page            = $c->param('_per_page') || 20;
    my $order_by            = $c->param('_order_by');
    my $include_unsupported = $c->param('include_unsupported') ? 1 : 0;

    my $args = {
        koha_version        => $koha_version,
        q                   => $q,
        order_by            => $order_by,
        include_unsupported => $include_unsupported,
    };

    my $plugin_model = KohaPluginStore::Model::Plugin->new( pg => $c->pg );
    my $total        = $plugin_model->count_compatible($args);

    my @plugins;
    if ( $per_page == -1 ) {
        @plugins = @{ $plugin_model->search_compatible( { %$args, limit => $total, offset => 0 } ) };
    }
    else {
        @plugins = @{ $plugin_model->search_compatible( { %$args, limit => $per_page, offset => ( $page - 1 ) * $per_page } ) };
    }

    my @plugin_hashes = map { $_->unblessed } @plugins;
    my $releases      = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->for_plugin_ids(
        [ map { $_->{id} } @plugin_hashes ],
        { koha_version => $koha_version, include_unsupported => $include_unsupported }
    );

    my %releases_by_plugin_id;
    push @{ $releases_by_plugin_id{ $_->plugin_id } }, $_ for @$releases;

    for my $plugin (@plugin_hashes) {
        for my $release ( @{ $releases_by_plugin_id{ $plugin->{id} } // [] } ) {
            push(
                @{ $plugin->{releases} },
                {
                    name               => $release->name,
                    tag_name           => $release->tag_name,
                    version            => $release->version,
                    koha_min_version   => $release->koha_min_version,
                    koha_max_version   => $release->koha_max_version,
                    kpz_url            => $release->kpz_url,
                    date_released      => $release->date_released,
                    content_digest     => $release->content_digest,
                    certification_tier => $release->certification_tier,
                    author_username    => $release->author_username,
                    author_avatar_url  => $release->author_avatar_url,
                    signed_manifest    => $release->signed_manifest,
                    signature          => $release->signature,
                }
            );
        }

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }

    # The following is required for CORS
    # Without this, users won't be able to list from remote locations
    $c->res->headers->header( 'Access-Control-Allow-Origin'  => '*' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type,x-koha-request-id' );
    $c->res->headers->header( 'Access-Control-Allow-Methods' => 'get,options' );
    $c->res->headers->header( 'X-Total-Count'                => $total );

    return $c->render( openapi => \@plugin_hashes, status => 200 );
}

sub verify ($c) {
    my $digest = $c->param('digest') // '';

    $c->res->headers->header( 'Access-Control-Allow-Origin'  => '*' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type,x-koha-request-id' );
    $c->res->headers->header( 'Access-Control-Allow-Methods' => 'get,options' );

    return $c->render( openapi => { error => 'digest must be a 64-character sha256 hex string' }, status => 400 )
        unless $digest =~ /^[0-9a-f]{64}$/i;

    my ($version) = KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->search(
        { content_digest => $digest, status => 'published' }, { order_by => { -desc => 'id' }, limit => 1 }
    );

    return $c->render( openapi => { error => 'no signed version found for this digest' }, status => 404 ) unless $version;

    return $c->render(
        openapi => {
            signed_manifest    => $version->signed_manifest,
            signature          => $version->signature,
            certification_tier => $version->certification_tier,
        },
        status => 200,
    );
}

sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

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

    return $c->render( text => 'Invalid CSRF token', status => 403 )
        if $c->validation->csrf_protect->has_error('csrf_token');

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
