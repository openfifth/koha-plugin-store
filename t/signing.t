use Mojo::Base -strict;
use Test::More;
use Crypt::PK::Ed25519;

use KohaPluginStore::Signing;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;

my $keypair = Crypt::PK::Ed25519->new;
$keypair->generate_key;
my $private_key_pem = $keypair->export_key_pem('private');
my $public_key_pem   = $keypair->export_key_pem('public');

my $plugin = KohaPluginStore::Model::Plugin->new( pg => undef, data => { slug => 'widget' } );
my $version = KohaPluginStore::Model::PluginVersion->new(
    pg   => undef,
    data => {
        version        => '1.0.0',
        kpz_url        => 'https://example.com/widget.kpz',
        content_digest => 'abc123',
    },
);

subtest 'build_manifest produces the expected shape' => sub {
    my $manifest = KohaPluginStore::Signing::build_manifest( $plugin, $version );

    like(
        delete $manifest->{published_at}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
        'published_at looks like an RFC3339 timestamp'
    );
    is_deeply(
        $manifest,
        {
            slug    => 'widget',
            version => '1.0.0',
            kpz_url => 'https://example.com/widget.kpz',
            digest  => 'abc123',
        },
        'remaining fields match plugin/version data, and certification_tier is not present'
    );
};

subtest 'canonical_json is deterministic regardless of input hash key order' => sub {
    my $a = {
        slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc',
        published_at => '2026-01-01T00:00:00Z',
    };
    my $b = {
        published_at => '2026-01-01T00:00:00Z', digest => 'abc', kpz_url => 'https://x',
        version => '1.0.0', slug => 'widget',
    };
    is(
        KohaPluginStore::Signing::canonical_json($a), KohaPluginStore::Signing::canonical_json($b),
        'same content, different key order, same output'
    );
};

subtest 'sign then verify round-trips successfully' => sub {
    my $json = KohaPluginStore::Signing::canonical_json(
        { slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc', published_at => '2026-01-01T00:00:00Z' }
    );
    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );
    ok( KohaPluginStore::Signing::verify( $json, $signature, $public_key_pem ), 'verifies against the matching public key' );
};

subtest 'verify fails against a wrong public key' => sub {
    my $other_keypair = Crypt::PK::Ed25519->new;
    $other_keypair->generate_key;
    my $wrong_public_key_pem = $other_keypair->export_key_pem('public');

    my $json = KohaPluginStore::Signing::canonical_json(
        { slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc', published_at => '2026-01-01T00:00:00Z' }
    );
    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );
    ok( !KohaPluginStore::Signing::verify( $json, $signature, $wrong_public_key_pem ), 'fails against a different keypair\'s public key' );
};

subtest 'verify fails against a tampered JSON string' => sub {
    my $json = KohaPluginStore::Signing::canonical_json(
        { slug => 'widget', version => '1.0.0', kpz_url => 'https://x', digest => 'abc', published_at => '2026-01-01T00:00:00Z' }
    );
    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );
    ( my $tampered = $json ) =~ s/widget/tampered/;
    ok( !KohaPluginStore::Signing::verify( $tampered, $signature, $public_key_pem ), 'fails when the signed content is altered' );
};

done_testing();
