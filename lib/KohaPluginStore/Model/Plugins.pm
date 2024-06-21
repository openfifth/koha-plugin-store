package KohaPluginStore::Model::Plugins;

use strict;
use warnings;
use experimental qw(signatures);

use Mojo::Util qw(secure_compare);

use Mojo::Base -base;

has 'sqlite';

sub fetch {
    my $self = shift;
    #TODO: Fix this
    return $self->sqlite->db->select( 'plugins', undef,
        [ { has_new_screenshot => 1 }, { test_failure => { '!=' => undef } } ] )
      ->hashes->to_array;
}

sub fetch_all {
    my $self = shift;
    my $user_id = shift;

    #TOOD: Like Koha REST API:
    #TODO: We need embedding
    #TODO: We need paging and sorting
    #TODO: We need searching

    my $user_query = $user_id ? ' where user_id = '.$user_id : '';

    my $plugins =
      $self->sqlite->db->query( 'select * from plugins' . $user_query )
      ->hashes->to_array;
    foreach my $plugin ( @{$plugins}) {
        $plugin->{versions} =
          $self->sqlite->db->query('select koha_version,plugin_version from versions where plugin_id ='.$plugin->{id})->hashes->to_array;

        $plugin->{thumbnail} ||= 'no_img.jpg';
    }

    return $plugins;
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
