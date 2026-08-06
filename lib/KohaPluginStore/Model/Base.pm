package KohaPluginStore::Model::Base;

use Mojo::Base -base, -signatures;
use Carp qw( croak );

has 'pg';
has 'data';

sub default_query_params {
    return { limit => 10 };
}

sub create {
    my ( $self, $attrs ) = @_;

    my $row = $self->pg->db->insert(
        $self->_table, $attrs, { returning => $self->_columns }
    )->hash;

    return $self->_new_from_row($row);
}

sub find {
    my ( $self, $query ) = @_;

    my $row = $self->pg->db->select( $self->_table, undef, $query, { limit => 1 } )->hash;
    return unless $row;

    return $self->_new_from_row($row);
}

sub search {
    my ( $self, $query, $params ) = @_;

    $query = {} unless $query;
    my $merged = { %{ $self->default_query_params }, %{ $params || {} } };

    my $rows = $self->pg->db->select( $self->_table, undef, $query, $merged )->hashes;

    return map { $self->_new_from_row($_) } @$rows;
}

sub update {
    my ( $self, $attrs ) = @_;

    $self->pg->db->update( $self->_table, $attrs, { id => $self->id } );
    $self->data->{$_} = $attrs->{$_} for keys %$attrs;

    return $self;
}

sub _new_from_row {
    my ( $self, $row ) = @_;
    return ref($self)->new( pg => $self->pg, data => $row );
}

sub unblessed {
    my ($self) = @_;
    return { %{ $self->data } };
}

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;

    my $method = $AUTOLOAD;
    $method =~ s/.*:://;
    return if $method eq 'DESTROY';

    croak( $method . ' is not a column on ' . $self->_table )
        unless $self->data && exists $self->data->{$method};

    if (@_) {
        $self->data->{$method} = shift;
        return $self;
    }

    return $self->data->{$method};
}

1;
