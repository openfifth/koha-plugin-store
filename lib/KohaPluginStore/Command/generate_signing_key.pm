package KohaPluginStore::Command::generate_signing_key;
use Mojo::Base 'Mojolicious::Command', -signatures;

use Crypt::PK::Ed25519;
use Getopt::Long qw(GetOptionsFromArray);

has description => 'Generate an Ed25519 signing keypair';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $force;
    GetOptionsFromArray( \@args, 'force' => \$force );

    my ($path) = @args;
    die "Usage: script/koha_plugin_store generate_signing_key <path> [--force]\n" unless $path;

    die "$path already exists. Use --force to overwrite.\n" if -e $path && !$force;

    my $pk = Crypt::PK::Ed25519->new;
    $pk->generate_key;

    open my $fh, '>', $path or die "Could not write $path: $!\n";
    print $fh $pk->export_key_pem('private');
    close $fh;

    say "Wrote a new Ed25519 signing keypair to $path";
}

1;

__END__

=encoding utf8

=head1 NAME

KohaPluginStore::Command::generate_signing_key - Generate an Ed25519 signing keypair

=head1 SYNOPSIS

  Usage: APPLICATION generate_signing_key <path> [--force]

  The private key alone is written -- it's sufficient to both sign (this app) and,
  via Crypt::PK::Ed25519->new($path)->export_key_pem('public'), derive the public
  key to bake into a verifier (e.g. Koha-core).

=cut
