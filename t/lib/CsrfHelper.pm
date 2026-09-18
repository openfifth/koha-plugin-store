package CsrfHelper;

use Modern::Perl;
use Exporter 'import';

our @EXPORT_OK = qw(csrf_token);

# Every page carries a valid token via the <meta name="csrf-token"> tag in
# the shared layout (see templates/layouts/default.html.ep), so any GET
# reachable in the test's current session works as a source -- it doesn't
# need to be the page the real form lives on.
sub csrf_token {
    my ( $t, $path ) = @_;
    $path //= '/my-plugins';
    return $t->get_ok($path)->tx->res->dom->at('meta[name="csrf-token"]')->{content};
}

1;
