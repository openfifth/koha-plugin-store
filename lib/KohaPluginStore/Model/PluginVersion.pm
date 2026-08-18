package KohaPluginStore::Model::PluginVersion;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_versions';
}

sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version koha_max_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier signed_manifest signature)];
}

sub for_plugin_ids {
    my ( $self, $plugin_ids, $args ) = @_;

    return [] unless @$plugin_ids;

    my $placeholders = join ',', ('?') x scalar(@$plugin_ids);

    my $rows = $self->pg->db->query(
        qq{
            SELECT *
            FROM plugin_versions
            WHERE status = 'published'
              AND plugin_id IN ($placeholders)
              AND koha_min_version <= ?
              AND (koha_max_version IS NULL OR koha_max_version >= ?)
            ORDER BY date_released DESC
        },
        @$plugin_ids, $args->{koha_version}, $args->{koha_version}
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}

1;
