package KohaPluginStore::Model::Base;

use strict;
use warnings;

use Carp qw( croak );

use KohaPluginStore;

sub new {
    my ($class) = @_;

    my $self = {};
    $self->{_dbh} = KohaPluginStore->new->{_dbh};
    bless( $self, $class );
}

sub _new_from_dbic {
    my ( $class, $dbic_row ) = @_;
    my $self = {};

    # DBIC result row
    $self->{_result} = $dbic_row;

    croak("No _type found! Koha::Object must be subclassed!")
        unless $class->_type();

    croak( "DBIC result _type " . ref( $self->{_result} ) . " isn't of the _type " . $class->_type() )
        unless ref( $self->{_result} ) eq "KohaPluginStore::Schema::Result::" . $class->_type();

    bless( $self, $class );

}

sub create {
    my ($self, $attrs) = @_;

    return $self->{_dbh}->resultset( $self->_type )->create( $attrs );
}

sub search {
    my ( $self, $query, $params ) = @_;

    my $search_params = $params ? { %{ $self->default_query_params }, %{$params} } : { %{ $self->default_query_params } };

    my $rs = $self->{_dbh}->resultset( $self->_type )->search( $query, $search_params );
    my @array = map { $self->object_class()->_new_from_dbic($_) } $rs->all;

    return @array;
}

sub find {
    my ( $self, $query, $params ) = @_;

    my $search_params =
        $params ? { %{ $self->default_query_params }, %{$params} } : { %{ $self->default_query_params } };

    my $rs = $self->{_dbh}->resultset( $self->_type )->find( $query, $search_params );
    return unless $rs;

    my $model_object = $self->object_class()->_new_from_dbic($rs);
    return $model_object;
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

sub _columns {
    my ($self) = @_;

    # If we don't have a dbic row at this point, we need to create an empty one
    $self->{_columns} ||= [ $self->_result()->result_source()->columns() ];

    return $self->{_columns};
}

sub _result {
    my ($self) = @_;

    # If we don't have a dbic row at this point, we need to create an empty one
    $self->{_result} ||=
        KohaPluginStore::Model::DB->new()->resultset( $self->_type() )->new( {} );

    return $self->{_result};
}

sub AUTOLOAD {
    my $self = shift;

    my $method = our $AUTOLOAD;
    $method =~ s/.*://;
    my @columns = @{ $self->_columns() };


    if ( grep { $_ eq $method } @columns ) {

        # Lazy definition of get/set accessors like $item->barcode; note that it contains $method
        my $accessor = sub {
            my $self = shift;
            if (@_) {
                $self->_result()->set_column( $method, @_ );
                return $self;
            } else {
                return $self->_result()->get_column($method);
            }
        };

        # If called from child class as $self->SUPER-><accessor_name>
        # $AUTOLOAD will contain ::SUPER which breaks method lookup
        # therefore we cannot write those entries into the symbol table
        unless ( $AUTOLOAD =~ /::SUPER::/ ) {
            no strict 'refs';    ## no critic (strict)
            *{$AUTOLOAD} = $accessor;
        }
        return $accessor->( $self, @_ );
    }

    my $r = eval { $self->_result->$method(@_) };
    return $r;
}

sub unblessed {
    my ($self) = @_;

    return { $self->_result->get_columns };
}

1;
