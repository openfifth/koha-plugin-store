use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::DependencyAllowlist;

subtest 'passes plain plugin code' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nsub install { return 1 }\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and names the file when system() is called' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nsystem('rm -rf /tmp/x');\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Widget\.pm/,    'message names the file' );
    like( $result->{message}, qr/system\(\)/,    'message names the pattern' );
};

subtest 'fails on filesystem access outside the plugin directory' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\nopen(my \$fh, '<', '../../etc/passwd');\n1;\n" );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

subtest 'a mention of system() in a comment, POD, or a string literal is not a false positive' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file(
        "$dir/Widget.pm",
        <<'PERL'
package Widget;
use Modern::Perl;

# system('this is only a comment, not a real call')

=head1 DESCRIPTION

This plugin does not call system().

=cut

my $note = 'do not use system() here';
sub install { return 1 }
1;
PERL
    );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed -- no real system()/exec() call, just text that mentions it' );
};

subtest 'a method call, hash key, or sub definition named system/exec is not a false positive' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file(
        "$dir/Widget.pm",
        <<'PERL'
package Widget;
use Modern::Perl;

my %opts = ( system => 1, exec => 'foo' );
$self->system();
$self->exec();
sub system { return 1 }
1;
PERL
    );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed -- none of these are an actual system()/exec() builtin call' );
};

subtest 'a real system()/exec() call is still caught even alongside look-alikes' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file(
        "$dir/Widget.pm",
        <<'PERL'
package Widget;
use Modern::Perl;

my %opts = ( system => 1 );
$self->system();
system('rm -rf /tmp/x');
1;
PERL
    );

    my $check  = KohaPluginStore::Check::DependencyAllowlist->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed -- the real call is still caught' );
    like( $result->{message}, qr/system\(\)/, 'message names the pattern' );
};

done_testing();
