package KohaPluginStore::Model::Plugin;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginMaintainer;

sub _table {
    return 'plugins';
}

sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url readme_html issue_tracker_url changelog_html)];
}

sub releases {
    my ($self) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $self->pg )->search( { plugin_id => $self->id } );
    return \@versions;
}

# The most recently *created* version, not the most recently released one --
# a re-submission of an older GitHub release would otherwise sort behind a
# newer one by date_released despite being the newest submission attempt.
sub latest_version {
    my ($self) = @_;

    my ($version) = KohaPluginStore::Model::PluginVersion->new( pg => $self->pg )
      ->search( { plugin_id => $self->id }, { order_by => { -desc => 'id' }, limit => 1 } );
    return $version;
}

sub latest_published_version {
    my ($self) = @_;

    my ($version) = KohaPluginStore::Model::PluginVersion->new( pg => $self->pg )
      ->search( { plugin_id => $self->id, status => 'published' }, { order_by => { -desc => 'id' }, limit => 1 } );
    return $version;
}

sub slugify {
    my ($string) = @_;

    my $slug = lc( $string // '' );
    $slug =~ s/[^a-z0-9]+/-/g;
    $slug =~ s/^-+|-+$//g;
    return $slug;
}

sub create_with_unique_slug {
    my ( $self, $slug_source, $attrs ) = @_;

    my $base = slugify($slug_source);

    for my $attempt ( 1 .. 10 ) {
        my $candidate = $attempt == 1 ? $base : "$base-$attempt";
        my $plugin = eval { $self->create( { %$attrs, slug => $candidate } ) };
        return $plugin if $plugin;
        die $@ unless $@ =~ /plugins_slug_key/;
    }

    die "Could not generate a unique slug for '$slug_source' after 10 attempts";
}

sub is_maintained_by {
    my ( $self, $developer_id ) = @_;

    return 0 unless $developer_id;
    return 1 if $self->developer_id && $self->developer_id == $developer_id;

    return KohaPluginStore::Model::PluginMaintainer->new( pg => $self->pg )
      ->find( { plugin_id => $self->id, developer_id => $developer_id } ) ? 1 : 0;
}

sub for_developer {
    my ( $self, $developer_id ) = @_;

    my $rows = $self->pg->db->query(
        q{
            SELECT DISTINCT p.*
            FROM plugins p
            LEFT JOIN plugin_maintainers pm ON pm.plugin_id = p.id
            WHERE p.developer_id = ? OR pm.developer_id = ?
            ORDER BY p.name
        },
        $developer_id, $developer_id
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}

sub search_by_author_slug {
    my ( $self, $author_slug ) = @_;

    my $rows = $self->pg->db->query(
        q{
            SELECT DISTINCT p.*
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE v.status = 'published' AND p.author IS NOT NULL AND p.author != ''
            ORDER BY p.name
        }
    )->hashes;

    my @plugins = map { $self->_new_from_row($_) } @$rows;
    return [ grep { slugify( $_->author ) eq $author_slug } @plugins ];
}

my %ORDER_BY = (
    'name'     => 'p.name ASC',
    '-name'    => 'p.name DESC',
    'author'   => 'p.author ASC',
    '-author'  => 'p.author DESC',
    'updated'  => 'MAX(v.date_released) ASC',
    '-updated' => 'MAX(v.date_released) DESC',
);

sub _compatible_where_and_binds {
    my ( $self, $args ) = @_;

    my @clauses = ("v.status = 'published'");
    my @binds;

    unless ( $args->{include_unsupported} ) {
        push @clauses, 'v.koha_min_version <= ?', '(v.koha_max_version IS NULL OR v.koha_max_version >= ?)';
        push @binds, ( $args->{koha_version} ) x 2;
    }

    if ( defined $args->{q} && length $args->{q} ) {
        push @clauses, '(p.name ILIKE ? OR p.description ILIKE ? OR p.author ILIKE ? OR p.slug ILIKE ?)';
        push @binds, ( '%' . $args->{q} . '%' ) x 4;
    }

    if ( defined $args->{certification_tier} && length $args->{certification_tier} ) {
        push @clauses, 'v.certification_tier = ?';
        push @binds, $args->{certification_tier};
    }

    return ( join( ' AND ', @clauses ), \@binds );
}

sub search_compatible {
    my ( $self, $args ) = @_;

    my ( $where, $binds ) = $self->_compatible_where_and_binds($args);
    my $order_by = $ORDER_BY{ $args->{order_by} // '' } // $ORDER_BY{name};

    my $rows = $self->pg->db->query(
        qq{
            SELECT p.*
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE $where
            GROUP BY p.id
            ORDER BY $order_by
            LIMIT ? OFFSET ?
        },
        @$binds, $args->{limit}, $args->{offset}
    )->hashes;

    return [ map { $self->_new_from_row($_) } @$rows ];
}

sub count_compatible {
    my ( $self, $args ) = @_;

    my ( $where, $binds ) = $self->_compatible_where_and_binds($args);

    my $count = $self->pg->db->query(
        qq{
            SELECT COUNT(DISTINCT p.id)
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE $where
        },
        @$binds
    )->array->[0];

    return $count;
}

1;
