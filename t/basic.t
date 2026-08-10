use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

reset_db();

my $t = test_app();

$t->get_ok('/')->status_is(200)->content_like(qr/Koha Plugin Store/i);

done_testing();
