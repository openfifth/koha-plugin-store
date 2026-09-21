use Mojo::Base -strict;

use Test::More;
use Test::Mojo;
use File::Temp qw(tempfile);
use Crypt::PK::Ed25519;

use lib 't/lib';
use TestDB qw(reset_db test_app);

reset_db();

subtest 'a configured, readable signing key renders its derived public key' => sub {
    my ( $fh, $key_path ) = tempfile( SUFFIX => '.pem', UNLINK => 1 );
    my $pk = Crypt::PK::Ed25519->new;
    $pk->generate_key;
    print $fh $pk->export_key_pem('private');
    close $fh;

    my $t = test_app();
    $t->app->config->{signing_key_path} = $key_path;

    my $expected_public_key = Crypt::PK::Ed25519->new($key_path)->export_key_pem('public');

    $t->get_ok('/verification-key')->status_is(200)
        ->content_like(qr/Verification key/i)
        ->content_like(qr/\Q$expected_public_key\E/);
};

subtest 'no signing_key_path configured renders a clear message, not a crash' => sub {
    my $t = test_app();
    delete $t->app->config->{signing_key_path};

    $t->get_ok('/verification-key')->status_is(200)
        ->content_like(qr/No signing key is configured/i)
        ->content_unlike(qr/BEGIN PUBLIC KEY/);
};

subtest 'a configured but unreadable/missing signing key file renders the same message' => sub {
    my $t = test_app();
    $t->app->config->{signing_key_path} = '/nonexistent/path/to/signing_key.pem';

    $t->get_ok('/verification-key')->status_is(200)
        ->content_like(qr/No signing key is configured/i)
        ->content_unlike(qr/BEGIN PUBLIC KEY/);
};

done_testing();
