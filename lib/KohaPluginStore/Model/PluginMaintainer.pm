package KohaPluginStore::Model::PluginMaintainer;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_maintainers';
}

sub _columns {
    return [qw(id plugin_id developer_id role granted_via granted_at last_verified_at)];
}

# Upserts on (plugin_id, developer_id) -- an existing row only ever has its
# last_verified_at bumped, never its role/granted_via overwritten, so a later
# sync pass can never silently downgrade an owner to a plain maintainer.
sub grant {
    my ( $self, $attrs ) = @_;

    my $row = $self->pg->db->query(
        q{
            INSERT INTO plugin_maintainers (plugin_id, developer_id, role, granted_via)
            VALUES (?, ?, ?, ?)
            ON CONFLICT (plugin_id, developer_id)
            DO UPDATE SET last_verified_at = now()
            RETURNING *
        },
        $attrs->{plugin_id}, $attrs->{developer_id}, $attrs->{role}, $attrs->{granted_via}
    )->hash;

    return $self->_new_from_row($row);
}

# Cross-table rows for the reconciliation job (Phase 2) -- plain hashes, not
# blessed Model::PluginMaintainer objects, since the shape spans three tables
# and doesn't correspond to any one of them.
sub for_reconciliation {
    my ($self) = @_;

    return $self->pg->db->query(
        q{
            SELECT pm.id, pm.plugin_id, pm.developer_id, p.repo_url, d.username
            FROM plugin_maintainers pm
            JOIN plugins p ON p.id = pm.plugin_id
            JOIN developers d ON d.id = pm.developer_id
            WHERE pm.granted_via = 'github_access'
        }
    )->hashes;
}

sub revoke {
    my ( $self, $id ) = @_;

    $self->pg->db->delete( 'plugin_maintainers', { id => $id } );
    return;
}

1;
