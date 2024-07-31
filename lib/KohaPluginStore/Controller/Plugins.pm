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

    $c->stash( plugin => $plugin );
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
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'x-koha-request-id' );

    return $c->render( json => \@plugins, status => 200 );
}

sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $config      = $c->app->plugin('Config');
    my @errors;

    # TODO: Write a unit test for this
    unless ( $c->logged_in_user ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    my $result = $c->_get_latest_release_from_github($plugin_repo);
    if ($result) {
        my $latest_release = decode_json $result;
        my @assets         = grep { $_->{name} =~ /\.kpz$/ } @{ $latest_release->{assets} };

        # TODO: Write a unit test for this
        unless ( scalar @assets eq 1 ) {
            push @errors,
                'Latest release must contain one and only one \'.kpz\' asset. Number of \'.kpz\' assets found: '
                . scalar @assets;
        }

        my $plugin_dir        = _download_plugin( $assets[0]->{browser_download_url} );
        my $plugin_class_file = _get_plugin_class_file($plugin_dir);
        my $plugin_metadata   = _get_plugin_metadata($plugin_class_file);


        my $existing_plugin = KohaPluginStore::Model::Plugin->new()->find(
            {
                name => $plugin_metadata->{name},
            }
        );

        if ($existing_plugin) {
            push @errors, 'A plugin named ' . $plugin_metadata->{name} . ' already exists';
        }



        $plugin_metadata->{repo_url} = $plugin_repo;

        unless ($plugin_class_file) {
            push @errors,
                'Plugin class file not found. Make sure the plugin has a class containing \'use base qw(Koha::Plugins::Base)\'?';
        }

        unless ($plugin_metadata) {
            push @errors,
                'Plugin metadata not found. Make sure the plugin class contains \'our $metadata = { ... } ?\'';
        }


        $c->stash( errors => \@errors );
        if ( scalar @errors eq 0 ) {
            $c->stash( latest_release  => $latest_release );
            $c->stash( kpz_asset       => $assets[0] );
            $c->stash( plugin_metadata => $plugin_metadata );
        }
    }
    $c->render('new-plugin-step2');
}

sub new_plugin_confirm ($c) {
    my $name        = $c->param('plugin_metadata_name');
    my $repo_url    = $c->param('plugin_metadata_repo_url');
    my $description = $c->param('plugin_metadata_description');
    my $author      = $c->param('plugin_metadata_author');

    # TODO: Write a test for this
    unless ( $c->logged_in_user ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    #TODO: Add repo_url here
    my $new_plugin = KohaPluginStore::Model::Plugin->new()->create( {
        name => $name,
        description => $description,
        author => $author,
        user_id => $c->session->{user}->{id}
    } );

    my $new_release = KohaPluginStore::Model::Release->new()->create(
        {
            plugin_id => $new_plugin->id,
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

sub _get_plugin_class_file {
    my ($plugin_dir) = @_;

    return unless $plugin_dir;

    use File::Find;
    use String::Util 'trim';
    my $plugin_class_file;

    find(
        {
            wanted => sub {
                return unless -f $_ && -T _;
                open my $fh, '<', $_ or die "Could not open file: $!";
                while ( my $line = <$fh> ) {
                    $line = trim($line);
                    if ( $line =~ /use base/ && $line =~ /Koha::Plugins::Base/ ) {
                        $plugin_class_file = $File::Find::name;
                        last;
                    }
                }
                close $fh;
            },
            no_chdir => 1,
        },
        $plugin_dir
    );

    return $plugin_class_file;
}

sub _get_plugin_metadata {
    my ($plugin_class_file) = @_;

    return unless $plugin_class_file;

    use File::Slurp;

    my $metadata_contents = read_file($plugin_class_file);
    my $plugin_metadata;

    if ( $metadata_contents =~ /our \$metadata = (\{.*?\});(?!\w)/s ) {

        #TODO: This is hardcoded. Fix this.
        our $VERSION = "2.5.7";

        eval( '$plugin_metadata = ' . $1 . ';' );
        if ($@) {
            print "Error evaluating metadata: $@";
        }
    }

    return $plugin_metadata;
}

sub _download_plugin {
    my ($kpz_download) = @_;

    my $ua      = Mojo::UserAgent->new( max_redirects => 5 );
    my $request = $ua->get($kpz_download);

    my $kpz_name = ( split '/', $kpz_download )[-1];

    my $file = 'kpz_packages/' . $kpz_name;
    $ua->get($kpz_download)->res->content->asset->move_to($file);

    use Archive::Zip;
    my $dir = 'kpz_packages/' . substr( $kpz_name, 0, -4 );
    my $zip = Archive::Zip->new($file);

    # TODO - Check if package/directory doesnt already exist
    foreach my $zip_file ( $zip->members ) {
        $zip_file->extractToFileNamed( "$dir/" . $zip_file->fileName );
    }

    return $dir;
}

1;
