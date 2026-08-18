package KohaPluginStore::Model::Plugin;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

use KohaPluginStore::Model::PluginVersion;

sub _table {
    return 'plugins';
}

sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url)];
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

sub create_with_unique_slug {
    my ( $self, $slug_source, $attrs ) = @_;

    my $base = lc($slug_source);
    $base =~ s/[^a-z0-9]+/-/g;
    $base =~ s/^-+|-+$//g;

    for my $attempt ( 1 .. 10 ) {
        my $candidate = $attempt == 1 ? $base : "$base-$attempt";
        my $plugin = eval { $self->create( { %$attrs, slug => $candidate } ) };
        return $plugin if $plugin;
        die $@ unless $@ =~ /plugins_slug_key/;
    }

    die "Could not generate a unique slug for '$slug_source' after 10 attempts";
}

my %ORDER_BY = (
    'name'  => 'p.name ASC',
    '-name' => 'p.name DESC',
);

sub _compatible_where_and_binds {
    my ( $self, $args ) = @_;

    my @clauses = ( "v.status = 'published'", 'v.koha_min_version <= ?', '(v.koha_max_version IS NULL OR v.koha_max_version >= ?)' );
    my @binds   = ( $args->{koha_version}, $args->{koha_version} );

    if ( defined $args->{q} && length $args->{q} ) {
        push @clauses, '(p.name ILIKE ? OR p.description ILIKE ? OR p.author ILIKE ?)';
        push @binds, ( '%' . $args->{q} . '%' ) x 3;
    }

    return ( join( ' AND ', @clauses ), \@binds );
}

sub search_compatible {
    my ( $self, $args ) = @_;

    my ( $where, $binds ) = $self->_compatible_where_and_binds($args);
    my $order_by = $ORDER_BY{ $args->{order_by} // '' } // $ORDER_BY{name};

    my $rows = $self->pg->db->query(
        qq{
            SELECT DISTINCT p.*
            FROM plugins p
            JOIN plugin_versions v ON v.plugin_id = p.id
            WHERE $where
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
