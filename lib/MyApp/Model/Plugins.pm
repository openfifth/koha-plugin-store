package MyApp::Model::Plugins;

use strict;
use warnings;
use experimental qw(signatures);

use Mojo::Util qw(secure_compare);

my $PLUGINS = {
    abc      => 'abc',
    def    => 'def'
};

sub new ($class) { bless {}, $class }

1;
