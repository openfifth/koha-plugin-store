package KohaPluginStore::Controller::Releases;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use KohaPluginStore::Model::Release;
use JSON;

sub new_release ($c) {

    my $plugin_id                = $c->param('plugin_id');
    my $release_name             = $c->param('release_metadata_name');
    my $release_tag_name         = $c->param('release_metadata_tag_name');
    my $release_date_released    = $c->param('release_metadata_date_released');
    my $release_version          = $c->param('release_metadata_version');
    my $release_koha_min_version = $c->param('release_metadata_koha_min_version');
    my $release_kpz_url          = $c->param('kpz_download');

    my $new_release = KohaPluginStore::Model::Release->new()->create(
        {
            plugin_id        => $plugin_id,
            name             => $release_name,
            tag_name         => $release_tag_name,
            date_released    => $release_date_released,
            version          => $release_version,
            koha_min_version => $release_koha_min_version,
            kpz_url          => $release_kpz_url
        }
    );

    $c->stash( plugin_id => $plugin_id );
    $c->render('releases/new-release-confirm');
}

1;
