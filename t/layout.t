use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app);

reset_db();

my $t = test_app();

subtest 'Bootstrap is pinned to a version that actually supports .text-bg-* (added in 5.2) -- badges everywhere use it' => sub {
    $t->get_ok('/developers')->status_is(200);

    my $body = $t->tx->res->body;
    my ( $major, $minor ) = $body =~ m{bootstrap\@(\d+)\.(\d+)\.\d+/dist/css/bootstrap\.min\.css};
    ok( defined $major, 'found the Bootstrap CSS CDN link' );

    ok(
        $major > 5 || ( $major == 5 && $minor >= 2 ),
        "Bootstrap $major.$minor supports .text-bg-success/-warning/-danger/-info/-secondary -- "
            . "on an older version those classes don't exist, so a badge's base white text renders on "
            . "no background at all (white on white)"
    );
};

done_testing();
