package KohaPluginStore::Signing;

use Modern::Perl;
use JSON;
use Mojo::Date;
use Crypt::PK::Ed25519;
use MIME::Base64 qw(encode_base64 decode_base64);

sub build_manifest {
    my ( $plugin, $version ) = @_;

    return {
        slug         => $plugin->slug,
        version      => $version->version,
        kpz_url      => $version->kpz_url,
        digest       => $version->content_digest,
        published_at => Mojo::Date->new(time)->to_datetime,
    };
}

sub canonical_json {
    my ($manifest) = @_;
    return JSON->new->canonical->utf8->encode($manifest);
}

sub sign {
    my ( $json_string, $private_key_pem ) = @_;
    my $pk = Crypt::PK::Ed25519->new( \$private_key_pem );
    return encode_base64( $pk->sign_message($json_string), '' );
}

sub verify {
    my ( $json_string, $signature_b64, $public_key_pem ) = @_;
    my $pk = Crypt::PK::Ed25519->new( \$public_key_pem );
    return $pk->verify_message( decode_base64($signature_b64), $json_string ) ? 1 : 0;
}

1;
