package KohaPluginStore::Model::Release;

use strict;
use warnings;
use base 'KohaPluginStore::Model::Base';

use Mojo::Base -base;

sub _type {
    return 'Release';
}

1;
