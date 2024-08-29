package KohaPluginStore::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Plugin;
use JSON;

sub index {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugin->new()->search;
    $c->stash( plugins => \@plugins );
    $c->render;
}

sub my_plugins {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugin->new()->search( { user_id => $c->session->{user}->{id} } );
    $c->stash( my_plugins => \@plugins );

    my $template = $c->session->{user} ? 'my-plugins' : 'unauthorized';
    $c->render($template);
}

sub add_form {
    my $c = shift;

    my $template = $c->session->{user} ? 'new-plugin' : 'unauthorized';
    $c->render($template);
}

sub edit_form {
    my $c = shift;

    my $plugin_id = $c->param('id');
    my $plugin    = KohaPluginStore::Model::Plugin->new()->find(
        {
            id => $plugin_id,
        }
    );

    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized',     status => 401 ) unless $c->session->{user}->{id} == $plugin->user_id;

    my $result          = $c->_get_releases_from_github( $plugin->repo_url );
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

    my @plugins = map { $_->unblessed } KohaPluginStore::Model::Plugin->new()->search;

    foreach my $plugin (@plugins) {
        my @releases =
            map { $_->unblessed } KohaPluginStore::Model::Release->new()->search( { plugin_id => $plugin->{id} } );

        foreach my $release (@releases) {
            push(
                @{ $plugin->{releases} },
                $release
            );
        }

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }

    # The following is required for CORS. same-origin Dev only (?)
    $c->res->headers->header( 'Access-Control-Allow-Origin'  => 'http://localhost:8081' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type,x-koha-request-id' );

    return $c->render( json => \@plugins, status => 200 );
}

sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $config      = $c->app->plugin('Config');
    my @errors;

    my $result = $c->_get_latest_release_from_github($plugin_repo);
    return $c->render('new-plugin-step2') unless $result;

    my $latest_release = decode_json $result;
    my @assets         = grep { $_->{name} =~ /\.kpz$/ } @{ $latest_release->{assets} };
    return $c->_exit_with_error_message(
        'Latest release must contain one and only one \'.kpz\' asset. Number of \'.kpz\' assets found: '.scalar @assets)
        unless ( scalar @assets eq 1 );

    my $plugin_dir        = _download_plugin( $assets[0]->{browser_download_url} );
    my ( $plugin_class_file, $plugin_class_name ) = _get_plugin_class_file_and_name($plugin_dir);
    return $c->_exit_with_error_message(
        'Plugin class file not found. Make sure the plugin has a class containing \'use base qw(Koha::Plugins::Base)\'?'
    ) unless $plugin_class_file;

    return $c->_exit_with_error_message(
        'Plugin class name not found. Make sure the plugin has a class file containing \'package \'?'
    ) unless $plugin_class_name;

    my $plugin_metadata = _get_plugin_metadata($plugin_class_file);
    return $c->_exit_with_error_message(
        'Plugin metadata not found. Make sure the plugin class contains \'our $metadata = { ... } ?\'')
        unless $plugin_metadata;

    return $c->_exit_with_error_message('Plugin metadata missing \'minimum_version\'. Make sure this value is set.')
        unless $plugin_metadata->{minimum_version};

    my $existing_plugin = KohaPluginStore::Model::Plugin->new()->find(
        {
            name     => $plugin_metadata->{name},
            repo_url => $plugin_repo
        }
    );

    return $c->_exit_with_error_message( 'A plugin with the name \''
            . $plugin_metadata->{name}
            . '\' or the URL \''
            . $plugin_repo
            . '\' already exists.' )
        if $existing_plugin;

    $plugin_metadata->{repo_url} = $plugin_repo;
    $plugin_metadata->{class_name} = $plugin_class_name;
    $c->stash( latest_release  => $latest_release );
    $c->stash( kpz_asset       => $assets[0] );
    $c->stash( plugin_metadata => $plugin_metadata );
    return $c->render('new-plugin-step2');
}

sub new_plugin_confirm ($c) {
    my $name        = $c->param('plugin_metadata_name');
    my $repo_url    = $c->param('plugin_metadata_repo_url');
    my $class_name  = $c->param('plugin_metadata_class_name');
    my $description = $c->param('plugin_metadata_description');
    my $author      = $c->param('plugin_metadata_author');

    my $release_name             = $c->param('release_metadata_name');
    my $release_tag_name         = $c->param('release_metadata_tag_name');
    my $release_date_released    = $c->param('release_metadata_date_released');
    my $release_version          = $c->param('release_metadata_version');
    my $release_koha_min_version = $c->param('release_metadata_koha_min_version');
    my $release_kpz_url          = $c->param('kpz_download');

    # TODO: Write a test for this
    unless ( $c->logged_in_user ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    my $new_plugin = KohaPluginStore::Model::Plugin->new()->create(
        {
            name        => $name,
            description => $description,
            author      => $author,
            repo_url    => $repo_url,
            class_name  => $class_name,
            user_id     => $c->session->{user}->{id}
        }
    );

    my $new_release = KohaPluginStore::Model::Release->new()->create(
        {
            plugin_id        => $new_plugin->id,
            name             => $release_name,
            tag_name         => $release_tag_name,
            date_released    => $release_date_released,
            version          => $release_version,
            koha_min_version => $release_koha_min_version,
            kpz_url          => $release_kpz_url
        }
    );

    $c->stash( new_plugin_id => $new_plugin->id );
    $c->render('new-plugin-confirm');
}

sub _get_latest_release_from_github {
    my ( $c, $plugin_repo ) = @_;

    my $config          = $c->app->plugin('Config');
    my $plugin_api_repo = $plugin_repo =~ s/https:\/\/github.com\//https:\/\/api.github.com\/repos\//r;
    my $ua              = Mojo::UserAgent->new;
    my $request         = $ua->get(
        $plugin_api_repo . '/releases/latest' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $config->{github_user_access_token}
        }
    );

    #TOOD: Write a unit test for this
    if ( $request->result->code != 200 ) {
        $c->stash(
            errors => [
                      'Unable to get latest release from github. Error: {code: '
                    . $request->result->code
                    . ', message: '
                    . $request->result->message . '}'
            ]
        );
        return;
    }

    return $request->result->body;
}

sub _get_releases_from_github {
    my ( $c, $plugin_repo ) = @_;

    my $config          = $c->app->plugin('Config');
    my $plugin_api_repo = $plugin_repo =~ s/https:\/\/github.com\//https:\/\/api.github.com\/repos\//r;
    my $ua              = Mojo::UserAgent->new;
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
                    if ( $line =~ /use base/ && $line =~ /Koha::Plugins::Base/ ) {
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

    if ( lc($metadata_contents) =~ /our \$metadata = (\{.*?\});(?!\w)/s ) {

        my $extracted_metadata = $1;
        my $metadata_variables;
        while ( $extracted_metadata =~ /\$([a-zA-Z_]+)\b/g ) {
            my $variable = $1;
            if ( lc($metadata_contents) =~ /(our \$$variable.*?= .*?;)/s ) {
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
