package KohaPluginStore::Command::reset_test_data;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::Developer;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

has description => 'Wipe and reseed demo developers/plugins/releases';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = $self->app->pg;

    $pg->db->query(
        'TRUNCATE plugin_versions, plugins, developers RESTART IDENTITY CASCADE'
    );

    # Developers data (OAuth):
    # admin (GitHub)
    # John (GitHub)
    my $admin = KohaPluginStore::Model::Developer->new( pg => $pg )->create(
        { oauth_provider_key => 'github', provider_user_id => '1', username => 'admin', avatar_url => 'https://example.com/admin.png' }
    );
    KohaPluginStore::Model::Developer->new( pg => $pg )->create(
        { oauth_provider_key => 'github', provider_user_id => '2', username => 'John', avatar_url => 'https://example.com/john.png' }
    );

    my $coverflow = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'Kyle M Hall',
            class_name  => 'Koha::Plugin::Com::ByWaterSolutions::CoverFlow',
            description => 'Convert a report into a coverflow style widget!',
            name        => 'CoverFlow plugin',
            repo_url    => 'https://github.com/bywatersolutions/koha-plugin-coverflow',
            thumbnail   => 'coverflow.png',
            timestamp   => '2024-09-17 09:34:22',
            developer_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $coverflow->id,
            name             => 'v2.5.7',
            tag_name         => 'v2.5.7',
            version          => '2.5.7',
            koha_min_version => '19.05',
            kpz_url          => 'https://github.com/bywatersolutions/koha-plugin-coverflow/releases/download/v2.5.7/koha-plugin-coverflow-2.5.7.kpz',
            date_released    => '2024-07-01T15:34:06Z',
        }
    );

    my $ill_actions = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'PTFS-Europe',
            class_name  => 'Koha::Plugin::Com::PTFSEurope::IllActions',
            description => 'ILL Actions',
            name        => 'IllActions',
            repo_url    => 'https://github.com/PTFS-Europe/koha-plugin-ill-actions',
            thumbnail   => 'ill_actions.png',
            timestamp   => '2024-09-17 09:53:10',
            developer_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $ill_actions->id,
            name             => 'v1.3.1',
            tag_name         => '1.3.1',
            version          => '1.3.1',
            koha_min_version => '23.11.00.000',
            kpz_url          => 'https://github.com/PTFS-Europe/koha-plugin-ill-actions/releases/download/1.3.1/koha-ill-actions-plugin-1.3.1.kpz',
            date_released    => '2024-03-27T15:56:15Z',
        }
    );

    my $pdf_to_cover = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'Mehdi Hamidi, Bouzid Fergani, Arthur Bousquet, The Minh Luong, Matthias Le Gac',
            class_name  => 'Koha::Plugin::PDFtoCover',
            description => 'Creates cover images for documents missing one',
            name        => 'PDFtoCover',
            repo_url    => 'https://github.com/inLibro/koha-plugin-pdftocover',
            thumbnail   => 'pdftocover.png',
            timestamp   => '2024-09-17 10:12:51',
            developer_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $pdf_to_cover->id,
            name             => 'v2.1',
            tag_name         => 'v2.1',
            version          => '2.1',
            koha_min_version => '23.05.08',
            kpz_url          => 'https://github.com/inLibro/koha-plugin-pdftocover/releases/download/v2.1/koha-plugin-pdftocover-2.1.kpz',
            date_released    => '2024-07-30T19:18:58Z',
        }
    );

    my $lms_event_management = KohaPluginStore::Model::Plugin->new( pg => $pg )->create(
        {
            author      => 'LMSCloud GmbH',
            class_name  => 'Koha::Plugin::Com::LMSCloud::EventManagement',
            description => 'This plugin makes managing events with koha a breeze!',
            name        => 'LMSEventManagement',
            repo_url    => 'https://github.com/LMSCloud/LMSEventManagement',
            thumbnail   => 'lmscloudevent.png',
            timestamp   => '2024-09-17 11:29:28',
            developer_id     => $admin->id,
        }
    );
    KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
        {
            plugin_id        => $lms_event_management->id,
            name             => 'Carnival',
            tag_name         => 'v1.6.12-beta.14',
            version          => '1.6.12',
            koha_min_version => '18.05',
            kpz_url          => 'https://github.com/LMSCloud/LMSEventManagement/releases/download/v1.6.12-beta.14/lms-event-management-v1.6.12.kpz',
            date_released    => '2024-03-04T12:32:26Z',
        }
    );

    say 'Test data reset.';
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::reset_test_data - Wipe and reseed demo data

=head1 SYNOPSIS

  Usage: APPLICATION reset_test_data

=cut
