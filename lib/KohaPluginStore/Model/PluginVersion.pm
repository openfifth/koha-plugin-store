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

    my @clauses = ( "status = 'published'", "plugin_id IN ($placeholders)" );
    my @binds   = @$plugin_ids;

    unless ( $args->{include_unsupported} ) {
        push @clauses, 'koha_min_version <= ?', '(koha_max_version IS NULL OR koha_max_version >= ?)';
        push @binds, ( $args->{koha_version} ) x 2;
    }

    my $where = join ' AND ', @clauses;

    my $rows = $self->pg->db->query(
        qq{
            SELECT *
            FROM plugin_versions
            WHERE $where
            ORDER BY date_released DESC
        },
        @binds
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}

# Every tag_name already recorded for a plugin, as a { tag_name => 1 }
# lookup hash -- a raw query, not search(), since search()'s default
# limit of 10 rows would silently miss tags on a plugin with more than
# 10 versions.
sub existing_tags {
    my ( $self, $plugin_id ) = @_;

    my $rows = $self->pg->db->query(
        q{SELECT tag_name FROM plugin_versions WHERE plugin_id = ?}, $plugin_id
    )->hashes;

    return { map { $_->{tag_name} => 1 } @$rows };
}

1;
