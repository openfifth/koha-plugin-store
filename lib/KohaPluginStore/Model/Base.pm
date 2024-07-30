package KohaPluginStore::Model::Base;

use strict;
use warnings;

use KohaPluginStore;

sub new {
    my ($class) = @_;

    my $self = {};
    $self->{_dbh} = KohaPluginStore->new->{_dbh};
    bless( $self, $class );
}

sub create {
    my ($self, $attrs) = @_;

    return $self->{_dbh}->resultset( $self->_type )->create( $attrs );
}

sub search {
    my ( $self, $query, $params ) = @_;

    my $search_params = $params ? { %{ $self->default_query_params }, %{$params} } : { %{ $self->default_query_params } };
    return $self->{_dbh}->resultset($self->_type)->search($query, $search_params);
}

sub find {
    my ( $self, $query, $params ) = @_;

    my $search_params =
        $params ? { %{ $self->default_query_params }, %{$params} } : { %{ $self->default_query_params } };
    return $self->{_dbh}->resultset( $self->_type )->find( $query, $search_params );
}

sub as_hash {
    my ( $self, $row ) = @_;

    my %h = $row->get_columns;
    return \%h;
}

sub default_query_params {
    my ($self) = @_;

    return
    {
        rows => 10,
    };
}

1;
