use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::HardcodedCredentials;

subtest 'passes plain plugin code' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nuse Modern::Perl;\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails on a hardcoded password literal' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \%opts = ( password => 'sup3rSecret!' );\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Widget\.pm/, 'message names the file' );
};

subtest 'fails on an AWS-access-key-shaped string' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \$key = 'AKIAABCDEFGHIJKLMNOP';\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

subtest 'a string, comment, or POD that only describes a credential-shaped assignment is not a false positive' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file(
        "$dir/Widget.pm",
        <<'PERL'
package Widget;
use Modern::Perl;

# password => 'not-a-real-secret-just-a-comment'

my $note = 'this string mentions api_key => "not-real" but is just text';

=head1 CONFIGURATION

Set password => "yourpasswordhere" in koha-conf.xml.

=cut

1;
PERL
    );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( $result->{passed}, 'passed -- no real credential assignment, just text describing one' );
};

subtest 'a hash-key credential assignment is still caught' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\nmy \%opts = ( api_key => 'sup3rSecretApiKey' );\n1;\n" );

    my $check  = KohaPluginStore::Check::HardcodedCredentials->new;
    my $result = $check->run( $dir, {}, {} );
    ok( !$result->{passed}, 'failed' );
};

done_testing();
