package MyApp::Model::Plugins;

use strict;
use warnings;
use experimental qw(signatures);

use Mojo::Util qw(secure_compare);

use Mojo::Base -base;

has 'sqlite';

sub fetch {
    my $self = shift;
    return $self->sqlite->db->select( 'plugins', undef,
        [ { has_new_screenshot => 1 }, { test_failure => { '!=' => undef } } ] )
      ->hashes->to_array;
}

sub fetch_all {
    my $self = shift;
    return $self->sqlite->db->select('plugins')->hashes->to_array;
}

sub get {
    my $self = shift;
    my $name = shift;
    return $self->sqlite->db->select( 'plugins', undef, { name => $name } )
      ->hash;
}

sub update {
    my $self = shift;
    my $name = shift;
    my $info = shift;
    $self->sqlite->db->update( 'plugins', $info, { name => $name } );
}

1;
