package KohaPluginStore::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
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

    my $result          = $c->_get_releases_from_github( $plugin->repo_url );

    #TODO: Handle case: $result is undef
    my $github_releases = decode_json($result);

    my $releases = $plugin->releases;

    foreach my $github_release (@$github_releases) {
        $github_release->{version} = 'N/A';
        $github_release->{koha_minimum_version} = 'N/A';
        my @assets = grep { $_->{name} =~ /\.kpz$/ } @{ $github_release->{assets} };
        if ( scalar @assets ne 1 ) {
            $github_release->{message}->{error} = 'Release must contain one and only one \'.kpz\' asset.';
            next;
        }

        foreach my $release (@$releases) {
            if ( $release->tag_name eq $github_release->{tag_name} ) {
                $github_release->{message}->{success} = 'Release has already been submitted.';
                next;
            }
        }

        my $plugin_dir        = _download_plugin( $assets[0]->{browser_download_url} );
        my ( $plugin_class_file, $plugin_class_name ) = _get_plugin_class_file_and_name($plugin_dir);

        if( !$plugin_class_file ) {
            $github_release->{message}->{error} = 'Plugin class file not found.';
            next;
        }

        if ( !$plugin_class_name ) {
            $github_release->{message}->{error} = 'Plugin class name not found.';
            next;
        }

        my $plugin_metadata = _get_plugin_metadata($plugin_class_file);
        if(!$plugin_metadata) {
            $github_release->{message}->{error} = 'Plugin metadata not found.';
            next;
        }

        if(!$plugin_metadata->{minimum_version}) {
            $github_release->{message}->{error} = 'Plugin metadata missing \'minimum_version\'.';
            next;
        }
        $github_release->{version} = $plugin_metadata->{version};
        $github_release->{koha_minimum_version} = $plugin_metadata->{minimum_version};
    }

    $c->stash( plugin          => $plugin );
    $c->stash( github_releases => $github_releases );
    $c->render('plugins/edit');
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

    my $developer_repos = KohaPluginStore::GitHub::fetch_public_repos( $c->session->{github_access_token} );
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

sub _get_releases_from_github {
    my ( $c, $plugin_repo ) = @_;

    my $config          = $c->app->plugin('Config');
    my $plugin_api_repo = $plugin_repo =~ s/https:\/\/github.com\//https:\/\/api.github.com\/repos\//r;
    my $ua              = Mojo::UserAgent->new( max_redirects => 5 );
    my $request         = $ua->get(
        $plugin_api_repo . '/releases?per_page=5&page=1' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $config->{github_user_access_token}
        }
    );

    #TOOD: Write a unit test for this
    if ( $request->result->code != 200 ) {
        $c->stash(
            errors => [
                      'Unable to get releases from github. Error: {code: '
                    . $request->result->code
                    . ', message: '
                    . $request->result->message . '}'
            ]
        );
        return;
    }

    return $request->result->body;
}

sub _get_plugin_class_file_and_name {
    my ($plugin_dir) = @_;

    return unless $plugin_dir;

    use File::Find;
    use String::Util 'trim';
    my $plugin_class_file;
    my $plugin_class_name;

    find(
        {
            wanted => sub {
                return unless -f $_ && -T _;
                open my $fh, '<', $_ or die "Could not open file: $!";
                while ( my $line = <$fh> ) {
                    $line = trim($line);
                    if ( $line =~ /use (?:base|parent)/ && $line =~ /Koha::Plugins::Base/ ) {
                        $plugin_class_file = $File::Find::name;

                        my $plugin_class_file_h;
                        open $plugin_class_file_h, '<', $plugin_class_file or die "Could not open file: $plugin_class_file";
                        while ( my $line = <$plugin_class_file_h> ) {
                            if ( $line =~ /^package/ ) {
                                $plugin_class_name = $line;
                                $plugin_class_name =~ s/^package\s+//;
                                $plugin_class_name =~ s/;$//;
                                $plugin_class_name =~ s/\s+//g;
                            }
                        }
                        close $plugin_class_file_h;
                        last;
                    }

                }
                close $fh;
            },
            no_chdir => 1,
        },
        $plugin_dir
    );

    return ($plugin_class_file, $plugin_class_name);
}

sub _get_plugin_metadata {
    my ($plugin_class_file) = @_;

    return unless $plugin_class_file;

    use File::Slurp;

    my $metadata_contents = read_file($plugin_class_file);
    my $plugin_metadata;

    if ( $metadata_contents =~ /our \$metadata = (\{.*?\});(?!\w)/si ) {

        my $extracted_metadata = $1;
        my $metadata_variables;
        while ( $extracted_metadata =~ /\$([a-zA-Z_]+)\b/g ) {
            my $variable = $1;
            if ( $metadata_contents =~ /(our \$$variable.*?= .*?;)/si ) {
                my $value = $1;
                $value =~ s/our \$$variable.*?= //;
                $value =~ s/;//;
                $value = trim($value);
                $metadata_variables->{ '$' . $variable } = $value;
            }
        }

        foreach my $key ( keys %$metadata_variables ) {
            $extracted_metadata =~ s/\Q$key\E/$metadata_variables->{$key}/;
        }

        eval( '$plugin_metadata = ' . $extracted_metadata . ';' );
        if ($@) {
            print "Error evaluating metadata: $@";
        }
    }

    return unless ref($plugin_metadata) eq 'HASH' && scalar keys %$plugin_metadata > 0;
    return $plugin_metadata;
}

sub _download_plugin {
    my ($kpz_download) = @_;

    my $kpz_name = ( split '/', $kpz_download )[-1];
    my $dir      = 'kpz_packages/' . substr( $kpz_name, 0, -4 );
    my $file     = 'kpz_packages/' . $kpz_name;

    return $dir if -e $file;

    my $ua      = Mojo::UserAgent->new( max_redirects => 5 );
    my $request = $ua->get($kpz_download);

    $ua->get($kpz_download)->res->content->asset->move_to($file);

    use Archive::Zip;
    my $zip = Archive::Zip->new($file);

    foreach my $zip_file ( $zip->members ) {
        $zip_file->extractToFileNamed( "$dir/" . $zip_file->fileName );
    }

    return $dir;
}

sub _exit_with_error_message {
    my ( $c, $error_message ) = @_;
    $c->stash( errors => [$error_message] );
    return $c->render('new-plugin-step2');
}

1;
