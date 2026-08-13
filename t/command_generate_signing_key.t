use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use Crypt::PK::Ed25519;

use KohaPluginStore;
use KohaPluginStore::Command::generate_signing_key;

my $dir  = tempdir( CLEANUP => 1 );
my $path = "$dir/signing_key.pem";
my $app  = KohaPluginStore->new;

subtest 'writes a valid Ed25519 keypair to the given path' => sub {
    KohaPluginStore::Command::generate_signing_key->new( app => $app )->run($path);
    ok( -e $path, 'key file was created' );

    my $pk = Crypt::PK::Ed25519->new($path);
    ok( $pk->is_private, 'loaded key is a private key' );
};

subtest 'refuses to overwrite an existing file without --force' => sub {
    my $original_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };

    eval { KohaPluginStore::Command::generate_signing_key->new( app => $app )->run($path) };
    like( $@, qr/already exists/, 'dies with a clear message' );

    my $unchanged_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };
    is( $unchanged_contents, $original_contents, 'the existing key file was not touched' );
};

subtest '--force does overwrite' => sub {
    my $original_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };

    KohaPluginStore::Command::generate_signing_key->new( app => $app )->run( $path, '--force' );

    my $new_contents = do { local $/; open my $fh, '<', $path or die $!; <$fh> };
    isnt( $new_contents, $original_contents, 'the key file now contains a freshly generated, different key' );
};

done_testing();
