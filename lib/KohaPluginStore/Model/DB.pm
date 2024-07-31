package KohaPluginStore::Model::DB;

use KohaPluginStore::Schema;
use DBIx::Class ();

use strict;

my ( $schema_class, $connect_info );

#TODO: Move this to koha_plugin_store.conf (?)

BEGIN {
    # $ENV{DBIC_TRACE} = 1;
    $schema_class = 'KohaPluginStore::Schema';
    $connect_info = {
        dsn      => 'dbi:SQLite:database.db',
        user     => '',
        password => '',
    };
}

sub new {
    return __PACKAGE__->config( $schema_class, $connect_info );
}

sub config {
    my $class = shift;

    my $self = {
        schema       => shift,
        connect_info => shift,
    };

    my $dbh = $self->{schema}->connect(
        $self->{connect_info}->{dsn},
        $self->{connect_info}->{user},
        $self->{connect_info}->{password}
    );

    return $dbh;
}

1;
