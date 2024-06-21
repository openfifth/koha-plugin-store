package KohaPluginStore::Model::Plugins;

use strict;
use warnings;
use base 'KohaPluginStore::Model::Base';

use Mojo::Base -base;

sub _type {
    return 'Plugin';
}

1;
