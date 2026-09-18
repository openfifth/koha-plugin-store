package SandboxBroker;

# This is the ONLY service in the stack that holds the host's Docker
# socket. It is deliberately small, self-contained, and doesn't load any
# KohaPluginStore::* code, DB credentials, GitHub token, or signing key --
# its entire job is "compile-check these files against this Koha version,
# in a locked-down one-shot container" and nothing else. The main app's
# worker (which does handle untrusted plugin content -- parsing metadata,
# unzipping submitted .kpz archives) talks to it over a narrow HTTP API on
# a Unix socket instead of holding the socket itself, so an RCE in the
# worker no longer means host root by construction.
use Mojo::Base 'Mojolicious', -signatures;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Fcntl qw(:flock);

my $DEFAULT_CHECKOUT_DIR = '/data/checkouts';
my $DEFAULT_SCRATCH_DIR  = '/data/scratch';
my $DEFAULT_GIT_URL      = 'https://git.koha-community.org/Koha-community/Koha.git';

sub startup ($self) {
    $self->routes->post('/check')->to( cb => \&_check );
}

sub _check ($c) {
    my $body = $c->req->json;
    return $c->render( json => { error => 'minimum_version required' }, status => 400 )
        unless $body && $body->{minimum_version};

    my $tag = _resolve_tag( $body->{minimum_version} );
    return $c->render(
        json => { error => "Could not resolve a Koha release tag for minimum_version '$body->{minimum_version}'" },
        status => 422
    ) unless $tag;

    my $files = $body->{files} // [];
    return $c->render( json => { passed => 1, message => undef } ) unless @$files;

    my ($image_tag) = $tag =~ /^v(\d+\.\d+)/;
    my $checkout_dir = _checkout_dir($tag);

    unless ( _ensure_checkout( $tag, $checkout_dir, _git_url() ) ) {
        return $c->render( json => { error => "could not prepare Koha checkout for tag $tag" }, status => 502 );
    }

    my $request_id = _request_id();
    my $stage_dir  = _scratch_dir() . "/$request_id";
    make_path($stage_dir);

    my @relative;
    for my $file (@$files) {
        my $path = "$stage_dir/$file->{path}";
        make_path( dirname($path) );
        open my $fh, '>', $path or die "Could not write $path: $!";
        print $fh $file->{content};
        close $fh;
        push @relative, $file->{path};
    }

    my $output = eval { _run_sandboxed( $checkout_dir, $stage_dir, \@relative, $image_tag ) };
    my $err    = $@;

    remove_tree($stage_dir);

    if ($err) {
        return $c->render( json => { error => "sandbox execution failed: $err" }, status => 502 );
    }

    my @failures = _parse_sandbox_output($output);
    return $c->render( json => { passed => 1, message => undef } ) unless @failures;
    return $c->render( json => { passed => 0, message => join( '; ', @failures ) } );
}

sub _checkout_dir { return ( $ENV{SANDBOX_CHECKOUT_DIR} // $DEFAULT_CHECKOUT_DIR ) . "/$_[0]" }
sub _scratch_dir  { return $ENV{SANDBOX_SCRATCH_DIR}  // $DEFAULT_SCRATCH_DIR }
sub _git_url      { return $ENV{SANDBOX_KOHA_GIT_URL} // $DEFAULT_GIT_URL }

sub _resolve_tag {
    my ($minimum_version) = @_;
    return unless $minimum_version;
    return "v$minimum_version" if $minimum_version =~ /^\d+\.\d+(\.\d+)?$/;
    return;
}

sub _request_id {
    return sprintf( '%08x%08x', int( rand(2**32) ), int( rand(2**32) ) );
}

# Test seam: overridden in tests to avoid a real git clone.
sub _ensure_checkout {
    my ( $tag, $checkout_dir, $git_url ) = @_;

    return 1 if -d $checkout_dir;

    make_path( dirname($checkout_dir) );
    my $lock_file = "$checkout_dir.lock";
    open my $lock_fh, '>', $lock_file or return 0;
    flock( $lock_fh, LOCK_EX );

    return 1 if -d $checkout_dir;    # another request won the race while we waited

    my $ok = system( 'git', 'clone', '--depth', '1', '--branch', $tag, $git_url, $checkout_dir ) == 0;

    close $lock_fh;
    unlink $lock_file;

    return $ok;
}

# The sandbox wrapper script (see _build_sandbox_cmd) prints one "PASS
# <file>" or "FAIL <file>" line per file, using perl -c's own exit code --
# never its diagnostic text -- to decide pass/fail. This is deliberate: a
# real Koha checkout's modules (C4::Context, Koha::Config, ...) warn loudly
# at BEGIN-time when there's no koha-conf.xml (there never is one here),
# and those warnings land on the same stream as genuine compile errors.
# Only the lines following a FAIL marker (until the next PASS/FAIL) are
# treated as that file's error detail.
sub _parse_sandbox_output {
    my ($output) = @_;

    my @failures;
    my $current;
    for my $line ( split /\n/, $output ) {
        if ( $line =~ /^FAIL (.+)$/ ) {
            $current = { file => $1, lines => [] };
            push @failures, $current;
        }
        elsif ( $line =~ /^PASS / ) {
            $current = undef;
        }
        elsif ($current) {
            push @{ $current->{lines} }, $line;
        }
    }

    return map { "$_->{file}: " . join( ' ', @{ $_->{lines} } ) } @failures;
}

# Runs inside the sandbox container as `perl -e $SANDBOX_WRAPPER -- <files>`.
# Each request's checkout and staged plugin files are bind-mounted at their
# own precise, single-purpose paths (see _build_sandbox_cmd), so unlike a
# shared whole-volume mount, one request's sandbox container never sees
# another's in-flight files.
my $SANDBOX_WRAPPER = <<'PERL';
my $failures = 0;
for my $rel (@ARGV) {
    my $pid = open( my $fh, '-|' );
    die "Could not fork: $!\n" unless defined $pid;

    if ( $pid == 0 ) {
        open( STDERR, '>&STDOUT' ) or die "Could not redirect STDERR: $!\n";
        exec( 'perl', '-I/kohadevbox/koha', '-I/plugin', '-cw', "/plugin/$rel" ) or die "Could not exec perl: $!\n";
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;

    if ( $? == 0 ) {
        print "PASS $rel\n";
    }
    else {
        $failures++;
        print "FAIL $rel\n$output";
    }
}
exit( $failures ? 1 : 0 );
PERL

# _build_sandbox_cmd's -v sources are resolved by the HOST's Docker daemon
# (Docker-outside-of-Docker: this container talks to the host's socket, not
# a nested dockerd it started itself), against the true host filesystem --
# this container's own /data/... paths mean nothing there. HOST_PROJECT_DIR
# (set in docker-compose.yml from ${PWD} at compose-parse time) is the real
# host path this worktree's sandbox_broker/tmp bind-mount corresponds to,
# so translate before handing a path to `docker run -v`. Falls back to the
# container path unchanged if unset (e.g. under `prove`, where nothing
# actually shells out to docker).
sub _host_path {
    my ($container_path) = @_;
    my $host_root = $ENV{HOST_PROJECT_DIR} or return $container_path;
    ( my $host_path = $container_path ) =~ s{^/data}{$host_root/sandbox_broker/tmp};
    return $host_path;
}

# Pure command builder, split out from _run_sandboxed so the exact argv list
# handed to exec() can be asserted on without forking/execing docker.
# Returns a flat list -- NOT a shell string -- so no path or generated
# content is ever parsed by a shell.
sub _build_sandbox_cmd {
    my ( $checkout_dir, $stage_dir, $relative, $image_tag ) = @_;

    return (
        'timeout', '--signal=KILL', '60',
        'docker', 'run', '--rm', '--network', 'none',
        '--memory', '512m', '--cpus', '0.5', '--read-only', '--tmpfs', '/tmp',
        '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '-v', _host_path($checkout_dir) . ':/kohadevbox/koha:ro',
        '-v', _host_path($stage_dir) . ':/plugin:ro',
        "koha/koha-testing:$image_tag",
        'perl', '-e', $SANDBOX_WRAPPER, '--', @$relative,
    );
}

# Test seam: overridden in tests to avoid needing Docker. Wrapped in
# `timeout --signal=KILL` so a plugin file that hangs the compiler can't
# tie up this process forever. Runs docker directly via fork+exec (no
# shell) -- see _build_sandbox_cmd.
sub _run_sandboxed {
    my ( $checkout_dir, $stage_dir, $relative, $image_tag ) = @_;

    my @cmd = _build_sandbox_cmd( $checkout_dir, $stage_dir, $relative, $image_tag );

    my $pid = open( my $fh, '-|' );
    die "Could not fork: $!\n" unless defined $pid;

    if ( $pid == 0 ) {
        open( STDERR, '>&STDOUT' ) or die "Could not redirect STDERR: $!\n";
        exec(@cmd) or die "Could not exec docker: $!\n";
    }

    local $/;
    my $output = <$fh> // '';
    close $fh;

    return $output;
}

1;
