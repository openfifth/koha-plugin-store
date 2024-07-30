package KohaPluginStore::Model::User;

use strict;
use warnings;
use base 'KohaPluginStore::Model::Base';
use Mojo::Base -base;

use Data::Structure::Util qw( unbless );
use Passwords ();

sub check_password {
    my ( $username, $password ) = @_;

    return undef unless $password;
    my $user = KohaPluginStore::Model::User->new()->find( { username => $username } );

    return undef unless $user;
    return Passwords::password_verify( $password, $user->password, );
}

sub _type {
    return 'User';
}

1;
