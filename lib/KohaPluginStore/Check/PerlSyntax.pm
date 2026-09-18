package KohaPluginStore::Check::PerlSyntax;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(:flock);

# Must be a path that's identical on the true Docker host and inside this
# worker container -- _run_sandboxed bind-mounts it via the host's Docker
# daemon (docker-compose mounts the host socket in, rather than running a
# nested dockerd), which resolves bind-mount sources against the host's own
# filesystem. /app/tmp works because docker-compose.yml bind-mounts the
# whole worktree at /app, so it's the same path on both sides.
my $DEFAULT_CACHE_DIR = '/app/tmp/koha-checkouts';
my $DEFAULT_GIT_URL   = 'https://git.koha-community.org/Koha-community/Koha.git';

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

    # Same validated minimum_version as $tag, just without the git tag's 'v'
    # prefix or patch component -- koha/koha-testing publishes images per
    # major.minor release (e.g. "22.11"), not per patch release.
    my ($image_tag) = $tag =~ /^v(\d+\.\d+)/;

    my $cache_dir     = $context->{koha_checkout_cache_dir} // $DEFAULT_CACHE_DIR;
    my $git_url       = $context->{koha_git_url}            // $DEFAULT_GIT_URL;
    my $checkout_dir  = "$cache_dir/$tag";

    unless ( _ensure_checkout( $tag, $checkout_dir, $git_url ) ) {
        die "check_infrastructure_error: could not prepare Koha checkout for tag $tag\n";
    }

    my @pm_files = $self->find_files( $extract_dir, qr/\.pm$/ );

    return { passed => 1, message => undef } unless @pm_files;

    my $output = _run_sandboxed( $checkout_dir, $extract_dir, \@pm_files, $image_tag );

    my @failures = _parse_sandbox_output($output);

    return { passed => 1, message => undef } unless @failures;
    return { passed => 0, message => join( '; ', @failures ) };
}

sub _resolve_tag {
    my ($minimum_version) = @_;
    return unless $minimum_version;
    return "v$minimum_version" if $minimum_version =~ /^\d+\.\d+(\.\d+)?$/;
    return;
}

# The sandbox wrapper script (see _build_sandbox_cmd) prints one "PASS <file>"
# or "FAIL <file>" line per file, using perl -c's own exit code -- never its
# diagnostic text -- to decide pass/fail. This is deliberate: a real Koha
# checkout's modules (C4::Context, Koha::Config, ...) warn loudly at
# BEGIN-time when there's no koha-conf.xml (there never is one here), and
# those warnings land on the same stream as genuine compile errors. Only the
# lines following a FAIL marker (until the next PASS/FAIL) are treated as
# that file's error detail.
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

# Test seam: overridden in tests to avoid a real git clone.
sub _ensure_checkout {
    my ( $tag, $checkout_dir, $git_url ) = @_;

    return 1 if -d $checkout_dir;

    make_path( dirname($checkout_dir) );
    my $lock_file = "$checkout_dir.lock";
    open my $lock_fh, '>', $lock_file or return 0;
    flock( $lock_fh, LOCK_EX );

    return 1 if -d $checkout_dir;    # another process won the race while we waited

    my $ok = system( 'git', 'clone', '--depth', '1', '--branch', $tag, $git_url, $checkout_dir ) == 0;

    close $lock_fh;
    unlink $lock_file;

    return $ok;
}

# _build_sandbox_cmd's -v sources are resolved by the HOST's Docker daemon
# (docker-compose mounts the host socket into this worker rather than running
# a nested dockerd), against the true host filesystem -- our own /app/...
# paths mean nothing there. HOST_PROJECT_DIR (set in docker-compose.yml from
# ${PWD} at compose-parse time) is the real host path this worktree's /app
# corresponds to, so translate before handing a path to `docker run -v`.
# Falls back to the container path unchanged if unset (e.g. under `prove`,
# where nothing actually shells out to docker).
sub _host_path {
    my ($container_path) = @_;
    my $host_root = $ENV{HOST_PROJECT_DIR} or return $container_path;
    ( my $host_path = $container_path ) =~ s{^/app}{$host_root};
    return $host_path;
}

# Runs inside the sandbox container as `perl -e $SANDBOX_WRAPPER -- <files>`.
# Forks+execs perl -c per file (no shell, same reasoning as _run_sandboxed
# below) and reports PASS/FAIL by that child's exit code, never by scanning
# its output -- a real Koha checkout warns extensively at BEGIN-time with no
# koha-conf.xml present (expected here), and none of that should be mistaken
# for a compile error. Only a FAIL'd file's own output is printed, so
# run()'s parser only ever sees genuine compiler diagnostics.
#
# -I/plugin matters beyond letting one plugin file `use` another: real Koha
# adds its configured pluginsdir (the parent of every installed plugin's own
# Koha::Plugin::* root) to @INC before loading any plugin (see
# Koha::Plugins::Handler's BEGIN block) -- /plugin plays that same role here.
# Plugins that vendor a bundled CPAN dependency under their own package's
# lib/ (a common pattern) locate themselves via Module::Metadata against
# @INC to find it, which only resolves if the plugin's root is on @INC, same
# as in a real install.
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

# Pure command builder, split out from _run_sandboxed so the exact argv list
# handed to exec() can be asserted on without forking/execing docker. Returns
# a flat list -- NOT a shell string -- so no path or generated content is
# ever parsed by a shell, however many quotes or slashes it contains. Plugin
# file names are passed as trailing argv entries (after `--`), read by the
# wrapper via @ARGV -- never interpolated into a generated source string, so
# a filename containing a quote can't corrupt anything either.
sub _build_sandbox_cmd {
    my ( $checkout_dir, $extract_dir, $pm_files, $image_tag ) = @_;

    my @relative = map { my $f = $_; $f =~ s{^\Q$extract_dir\E/?}{}; $f } @$pm_files;

    return (
        'timeout', '--signal=KILL', '60',
        'docker', 'run', '--rm', '--network', 'none',
        '--memory', '512m', '--cpus', '0.5', '--read-only', '--tmpfs', '/tmp',
        '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '-v', _host_path($checkout_dir) . ':/kohadevbox/koha:ro',
        '-v', _host_path($extract_dir) . ':/plugin:ro',
        "koha/koha-testing:$image_tag",
        'perl', '-e', $SANDBOX_WRAPPER, '--', @relative,
    );
}

# Test seam: overridden in tests to avoid needing Docker.
#
# Wrapped in `timeout --signal=KILL` so a plugin file that hangs the compiler
# (e.g. an infinite BEGIN loop) can't tie up a Minion worker forever -- a
# timeout here surfaces as a FAIL for whichever file was running when it hit,
# same as any other non-zero exit, not as a check_infrastructure_error. Known
# follow-up: a hard-killed `docker run` client can in rare cases leave the
# container itself running past the timeout since --rm only cleans up on
# normal exit; revisit with an explicit `docker kill` sweep if that's
# observed in practice. 60s (not 30s) because a real Koha checkout's module
# tree is far larger than the old bare perl:slim sandbox's -- each file
# re-compiles it from scratch, with no bytecode cache shared across files.
#
# Runs docker directly via fork+exec (no shell) -- an earlier version built
# this as one big backtick-executed shell string, and generated script
# content containing single quotes broke out of the outer shell's quoting
# for any plugin at all, corrupting the command the sandbox actually ran.
sub _run_sandboxed {
    my ( $checkout_dir, $extract_dir, $pm_files, $image_tag ) = @_;

    my @cmd = _build_sandbox_cmd( $checkout_dir, $extract_dir, $pm_files, $image_tag );

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
