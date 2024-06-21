package KohaPluginStore::Model::Users;

use strict;
use warnings;
use base 'KohaPluginStore::Model::Base';
use Mojo::Base -base;

use Data::Structure::Util qw( unbless );
use Passwords ();

has '_dbh';

sub new {
    my ( $class, $params ) = @_;
    my $self = $class->SUPER::new();
    return $self;
}

sub add_user {
    my ( $self, $user ) = @_;
    Carp::croak 'password is required'
      unless $user->{password};
    $user->{password} = Passwords::password_hash( $user->{password} );
    return $self->sqlite->db->insert( users => $user )->last_insert_id;
}

sub check_password {
    my ( $self, $username, $password ) = @_;
    return undef unless $password;
    my $user = $self->search({ username => $username } )->first;
    return undef unless $user;
    return Passwords::password_verify( $password, $user->password, );
}

sub _type {
    return 'User';
}

1;
