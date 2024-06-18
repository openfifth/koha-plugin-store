package MyApp::Controller::Plugins;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use JSON;

sub list_all ($c) {
    my $plugins = $c->plugins;

    #TODO: Check for auth?

    # The following is required for CORS. Dev only (?)
    $c->res->headers->header( 'Access-Control-Allow-Origin' => 'http://localhost:8081' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'content-type' );
    $c->res->headers->header( 'Access-Control-Allow-Headers' => 'x-koha-request-id' );

    return $c->render( json => $plugins, status => 200 );
}

sub new_plugin ($c) {
    my $plugin_repo = $c->param('plugin_repo');
    my $config = $c->app->plugin('Config');
    my @errors;

    # TODO: Write a test for this
    unless ( $c->logged_in_user ){
        return $c->render( text => 'Unauthorized', status => 401 );
    }

    my $plugin_api_repo = $plugin_repo =~ s/https:\/\/github.com\//https:\/\/api.github.com\/repos\//r;
    my $ua  = Mojo::UserAgent->new;
    my $request = $ua->get(
        $plugin_api_repo.'/releases/latest'
        => { Accept => 'application/vnd.github+json', Authorization => 'Bearer ' . $config->{github_user_access_token} } );

    # TODO: We need a try/catch here
    my $result = $request->result->body;
    my $latest_release = decode_json $result;

    my @assets =  grep { $_->{name} =~ /\.kpz$/ } @{$latest_release->{assets}};

    # TODO: Write a test for this
    unless ( scalar @assets eq 1 ) {
        push @errors, 'Latest release must contain one and only one \'.kpz\' asset. Number of \'.kpz\' assets found: ' . scalar @assets;
    }

    $c->stash( errors => \@errors );
    if ( scalar @errors eq 0 ) {
        $c->stash( latest_release => $latest_release );
        $c->stash( kpz_asset      => $assets[0] );
    }
    $c->render('new-plugin-confirm');
}

1;
