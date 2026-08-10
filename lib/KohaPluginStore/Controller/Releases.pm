package KohaPluginStore::Controller::Releases;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::GitHub;

sub new_release ($c) {
    my $plugin_id = $c->param('plugin_id');
    my $tag_name  = $c->param('tag_name');

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $c->pg )->find( { id => $plugin_id } );
    return $c->render( text => 'Plugin not found', status => 404 ) unless $plugin;
    return $c->render( text => 'Unauthorized', status => 401 )
        unless $c->session->{developer}->{id} == $plugin->developer_id;

    my $config  = $c->app->plugin('Config');
    my $token   = $config->{github_app_token};
    my $release = KohaPluginStore::GitHub::fetch_release_by_tag( $token, $plugin->repo_url, $tag_name );
    return $c->render( text => 'Could not re-fetch that release from GitHub', status => 502 ) unless $release;

    my @kpz_assets = grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
    return $c->render( text => 'Release must contain one and only one \'.kpz\' asset', status => 422 )
        unless scalar @kpz_assets == 1;

    my $new_version = eval {
        KohaPluginStore::Model::PluginVersion->new( pg => $c->pg )->create(
            {
                plugin_id         => $plugin_id,
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
    return $c->render( text => 'That release has already been submitted', status => 409 )
        if !$new_version && $@ =~ /plugin_versions_plugin_id_tag_name_key/;
    die $@ if !$new_version;

    $c->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );

    return $c->redirect_to( '/plugins/' . $plugin->slug );
}

1;
