package MyApp::Model::Users;

use strict;
use warnings;
use experimental qw(signatures);

use Mojo::Util qw(secure_compare);

use Mojo::Base -base;

use Passwords ();

has 'sqlite';

sub fetch_all {
    my $self = shift;

    #TOOD: Like Koha REST API:
    #TODO: We need embedding
    #TODO: We need paging and sorting
    #TODO: We need searching

    my $users = $self->sqlite->db->select('users')->hashes->to_array;

    return $users;
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
    my $user = $self->sqlite->db->select(
        'users' => ['password'],
        { username => $username },
    )->hash;
    return undef unless $user;
    return Passwords::password_verify( $password, $user->{password}, );
}

sub fetch {
    my ( $self, $username ) = @_;

    my $sql = <<'  SQL';
    select id, email, username
    from users
    where username=?
  SQL
    return $self->sqlite->db->query( $sql, $username )->hash;
}

1;
