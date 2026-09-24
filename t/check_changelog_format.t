use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::ChangelogFormat;

subtest 'passes when changelog_html has a recognizable version heading' => sub {
    my $check  = KohaPluginStore::Check::ChangelogFormat->new;
    my $result = $check->run(
        '/unused', {},
        { changelog_html => '<h2>[1.0.0] - 2026-01-01</h2><p>Initial release.</p>' }
    );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails, and gates certification, when changelog_html is missing entirely' => sub {
    my $check  = KohaPluginStore::Check::ChangelogFormat->new;
    my $result = $check->run( '/unused', {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/No CHANGELOG\.md or CHANGES\.md/ );
    ok( $check->gates_certification, 'gates certification' );
};

subtest 'fails when changelog_html exists but has no version-shaped heading' => sub {
    my $check  = KohaPluginStore::Check::ChangelogFormat->new;
    my $result = $check->run(
        '/unused', {},
        { changelog_html => '<h2>Recent changes</h2><p>We changed some stuff.</p>' }
    );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/no recognizable version heading/ );
};

done_testing();
