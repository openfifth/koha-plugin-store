package KohaPluginStore::Model::Plugin;

use strict;
use warnings;
use base 'KohaPluginStore::Model::Base';
use KohaPluginStore::Model::Release;

use Mojo::Base -base;

sub releases {
    my ( $self ) = @_;

    my @releases = KohaPluginStore::Model::Release->new()->search( { plugin_id => $self->id } );
    return \@releases;
}
sub _type {
    return 'Plugin';
}

1;
