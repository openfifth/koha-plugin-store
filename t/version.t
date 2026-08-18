use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Version qw(normalize);

subtest 'normalizes a full 4-segment version' => sub {
    is( normalize('26.06.00.011'), '26.06.00.011', 'already-canonical input is unchanged' );
};

subtest 'zero-pads missing trailing segments' => sub {
    is( normalize('23.11'), '23.11.00.000', 'a 2-segment version gets padded to 4' );
    is( normalize('23'), '23.00.00.000', 'a 1-segment version gets padded to 4' );
};

subtest 'normalizes inconsistent zero-padding to the canonical width' => sub {
    is( normalize('9.5.0.0'), '09.05.00.000', 'single-digit segments get padded' );
};

subtest 'rejects non-numeric segments' => sub {
    is( normalize('23.11.beta'), undef, 'a non-numeric segment is rejected' );
    is( normalize('not-a-version'), undef, 'non-numeric input is rejected' );
};

subtest 'rejects more than 4 segments' => sub {
    is( normalize('23.11.00.000.1'), undef, 'a 5-segment version is rejected' );
};

subtest 'rejects empty or undef input' => sub {
    is( normalize(''), undef, 'empty string is rejected' );
    is( normalize(undef), undef, 'undef is rejected' );
};

done_testing();
