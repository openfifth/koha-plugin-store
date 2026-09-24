package KohaPluginStore::Task::SyncPluginRelease;

use Modern::Perl;

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::GitHub;

sub register {
    my ($app) = @_;
    $app->minion->add_task( sync_plugin_release => \&run );
}

sub run {
    my ( $job, $plugin_id ) = @_;

    my $app    = $job->app;
    my $pg     = $app->pg;
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $pg )->find( { id => $plugin_id } );
    return $job->fail("plugin_id=$plugin_id not found") unless $plugin;

    my $token    = $app->config->{github_app_token};
    my $releases = KohaPluginStore::GitHub::fetch_releases( $token, $plugin->repo_url );

    my $existing_tags = KohaPluginStore::Model::PluginVersion->new( pg => $pg )->existing_tags( $plugin->id );
    my $eligible       = KohaPluginStore::GitHub::new_releases( $releases, $existing_tags );

    for my $release (@$eligible) {
        my @kpz_assets  = KohaPluginStore::GitHub::kpz_assets($release);
        my $new_version = eval {
            KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
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
        unless ($new_version) {
            warn "sync_plugin_release: plugin_id=$plugin_id tag=$release->{tag_name}: $@";
            next;
        }
        $app->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );
    }
}

1;
