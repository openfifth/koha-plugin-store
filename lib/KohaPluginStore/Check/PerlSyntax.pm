package KohaPluginStore::Check::PerlSyntax;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);
use Mojo::UserAgent;
use Mojo::Util qw(url_escape);

# The actual compile-check runs in a separate syntax-sandbox service (see
# sandbox_broker/) reached over a Unix socket -- that service is the only
# thing in the stack holding the host's Docker socket, deliberately kept
# out of this process, which handles untrusted plugin content (parsing
# submitted metadata, unzipping a submitted .kpz) earlier in the same job.
# Reached over a socket shared via a Docker volume between this container
# and the broker's, not a host path or TCP port.
my $SOCKET_PATH        = $ENV{SANDBOX_BROKER_SOCKET} // '/run/broker/broker.sock';
my $DEFAULT_BROKER_URL = 'http+unix://' . url_escape($SOCKET_PATH) . '/check';

sub check_name         { 'perl_syntax' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my $tag = _resolve_tag( $metadata->{minimum_version} );
    unless ($tag) {
        return {
            passed  => 0,
            message => "Could not resolve a Koha release tag for minimum_version '"
                . ( $metadata->{minimum_version} // '' ) . "'",
        };
    }

    my @pm_files = $self->find_files( $extract_dir, qr/\.pm$/ );
    return { passed => 1, message => undef } unless @pm_files;

    my $broker_url = $context->{sandbox_broker_url} // $DEFAULT_BROKER_URL;
    return _call_broker( $broker_url, $metadata->{minimum_version}, $extract_dir, \@pm_files );
}

sub _resolve_tag {
    my ($minimum_version) = @_;
    return unless $minimum_version;
    return "v$minimum_version" if $minimum_version =~ /^\d+\.\d+(\.\d+)?$/;
    return;
}

# Test seam: overridden in tests to avoid a real broker call. A connection
# failure, or the broker itself reporting it couldn't prepare the Koha
# checkout or run the sandbox, is a check_infrastructure_error (same
# semantics as the old direct-exec version's checkout-preparation failure)
# -- infrastructure trouble, not the plugin's own fault.
sub _call_broker {
    my ( $broker_url, $minimum_version, $extract_dir, $pm_files ) = @_;

    my @files = map {
        my $path = $_;
        ( my $relative = $path ) =~ s{^\Q$extract_dir\E/?}{};
        { path => $relative, content => scalar read_file($path) };
    } @$pm_files;

    my $tx = eval {
        Mojo::UserAgent->new->post(
            $broker_url => json => { minimum_version => $minimum_version, files => \@files }
        );
    };
    if ($@) {
        my $reason = $@;
        chomp $reason;
        die "check_infrastructure_error: sandbox broker request failed: $reason\n";
    }

    my $res = $tx->result;
    unless ( $res && $res->is_success ) {
        my $detail =
              $res              ? ( eval { $res->json->{error} } // $res->body )
            : $tx->error         ? $tx->error->{message}
            :                      'unreachable';
        die "check_infrastructure_error: sandbox broker request failed: $detail\n";
    }

    my $json = $res->json;
    return { passed => $json->{passed} ? 1 : 0, message => $json->{message} };
}

1;
