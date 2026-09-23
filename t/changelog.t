use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Changelog;

subtest 'extracts a "Keep a Changelog"-style [x.y.z] heading, stopping before the next heading' => sub {
    my $html = '<h2>[1.1.0] - 2026-02-01</h2><p>Added a widget.</p><h2>[1.0.0] - 2026-01-01</h2><p>Initial release.</p>';

    my $section = KohaPluginStore::Changelog::extract_section( $html, 'v1.1.0' );
    like( $section, qr/Added a widget\./, 'matched entry included' );
    unlike( $section, qr/Initial release\./, 'older entry not included' );
};

subtest 'matches a bare vX.Y.Z heading with no brackets' => sub {
    my $html = '<h2>v2.0.0</h2><p>Rewrote the thing.</p>';

    my $section = KohaPluginStore::Changelog::extract_section( $html, 'v2.0.0' );
    like( $section, qr/Rewrote the thing\./ );
};

subtest 'matches when the tag has no leading v but the heading does, and vice versa' => sub {
    my $html = '<h2>1.2.0</h2><p>No leading v anywhere.</p>';

    is( KohaPluginStore::Changelog::extract_section( $html, 'v1.2.0' ), '<h2>1.2.0</h2><p>No leading v anywhere.</p>' );
};

subtest 'returns undef, not a die, when no heading matches (non-standard changelog format)' => sub {
    my $html = '<p>Just a paragraph, no version headings at all.</p>';

    is( KohaPluginStore::Changelog::extract_section( $html, 'v1.0.0' ), undef );
};

subtest 'returns undef on missing inputs' => sub {
    is( KohaPluginStore::Changelog::extract_section( undef, 'v1.0.0' ), undef );
    is( KohaPluginStore::Changelog::extract_section( '<h2>1.0.0</h2>', undef ), undef );
};

done_testing();
