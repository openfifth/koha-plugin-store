package KohaPluginStore::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Plugins;
use JSON;

sub index {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugins->new()->search;
    $c->stash( plugins => \@plugins );
    $c->render;
}

sub my_plugins {
    my $c = shift;

    my @plugins = KohaPluginStore::Model::Plugins->new()->search({user_id => $c->session->{user}->{id}});
    $c->stash( my_plugins => \@plugins );
    
    my $template = $c->session->{user} ? 'my-plugins' : 'unauthorized';
    $c->render($template);
}

sub add_form {
    my $c = shift;

    my $template = $c->session->{user} ? 'new-plugin' : 'unauthorized';
    $c->render($template);
}

sub list_all ($c) {

    my @plugins = map { my %h = $_->get_columns; \%h }
        KohaPluginStore::Model::Plugins->new()->search;

    foreach my $plugin (@plugins) {
        my @versions =
          map { my %h = $_->get_columns; \%h }
          $c->app->{_dbh}->resultset('Version')
          ->search( { plugin_id => $plugin->{id} } );

        foreach my $version (@versions) {
            push(
                @{ $plugin->{versions} },
                {
                    koha_version   => $version->{koha_version},
                    plugin_version => $version->{plugin_version}
                }
            );
        }

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }

    # The following is required for CORS. same-origin Dev only (?)
    $c->res->headers->header(
        'Access-Control-Allow-Origin' => 'http://localhost:8081' );
    $c->res->headers->header(
        'Access-Control-Allow-Headers' => 'content-type' );
    $c->res->headers->header(
        'Access-Control-Allow-Headers' => 'x-koha-request-id' );

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

    # TODO: Validate that $config->{github_user_access_token} exists
    my $plugin_api_repo = $plugin_repo =~
      s/https:\/\/github.com\//https:\/\/api.github.com\/repos\//r;
    my $ua      = Mojo::UserAgent->new;
    my $request = $ua->get(
        $plugin_api_repo
          . '/releases/latest' => {
            Accept        => 'application/vnd.github+json',
            Authorization => 'Bearer ' . $config->{github_user_access_token}
          }
    );

    # TODO: We need a try/catch here
    my $result         = $request->result->body;
    my $latest_release = decode_json $result;

    my @assets = grep { $_->{name} =~ /\.kpz$/ } @{ $latest_release->{assets} };

    # TODO: Write a unit test for this
    unless ( scalar @assets eq 1 ) {
        push @errors,
'Latest release must contain one and only one \'.kpz\' asset. Number of \'.kpz\' assets found: '
          . scalar @assets;
    }

    $c->stash( errors => \@errors );
    if ( scalar @errors eq 0 ) {
        $c->stash( latest_release => $latest_release );
        $c->stash( kpz_asset      => $assets[0] );
    }
    $c->render('new-plugin-step2');
}

sub new_plugin_confirm ($c) {
    my $kpz_download = $c->param('kpz_download');

    # TODO: Write a test for this
    unless ( $c->logged_in_user ) {
        return $c->render( text => 'Unauthorized', status => 401 );
    }

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

#THIS IS WHERE I LEFT OFF - READ $METADATA FROM PLUGIN CLASS TO EXTRACT KOHA MAX VERSION

    $c->render('new-plugin-confirm');

}

1;
