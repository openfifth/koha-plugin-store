use Mojo::Base -strict;
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);

use KohaPluginStore::Check::PerlSyntax;

# The actual sandboxed-compile-check logic (parsing PASS/FAIL output,
# preparing a Koha checkout, running docker) now lives in the syntax-sandbox
# broker service -- see sandbox_broker/t/broker.t for those tests. This
# file only tests PerlSyntax's own job: resolving a tag, calling the
# broker, and turning its response (or its absence) into a check result.

subtest 'passes when the broker reports passed' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { return { passed => 1, message => undef } };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails and reports the broker\'s message' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget\n1;\n" );    # missing semicolon

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub {
        return { passed => 0, message => 'Widget.pm: syntax error at ... near "1;"' };
    };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/syntax error/, 'message includes the compile error' );
};

subtest 'a minimum_version that cannot be resolved to a tag fails clearly, without calling the broker' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { die 'should not be called' };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => 'not-a-version' }, {} );
    ok( !$result->{passed}, 'failed' );
    like( $result->{message}, qr/Could not resolve/, 'message explains why' );
};

subtest 'no .pm files means an automatic pass, without calling the broker' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub { die 'should not be called' };

    my $check  = KohaPluginStore::Check::PerlSyntax->new;
    my $result = $check->run( $dir, { minimum_version => '23.05' }, {} );
    ok( $result->{passed}, 'passed' );
};

subtest 'a broker failure dies as a check_infrastructure_error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/Widget.pm", "package Widget;\n1;\n" );

    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::Check::PerlSyntax::_call_broker = sub {
        die "check_infrastructure_error: sandbox broker request failed: unreachable\n";
    };

    my $check = KohaPluginStore::Check::PerlSyntax->new;
    eval { $check->run( $dir, { minimum_version => '23.05' }, {} ) };
    like( $@, qr/^check_infrastructure_error/, 'dies with the infrastructure-error prefix' );
};

subtest '_call_broker wraps a raw transport exception as a check_infrastructure_error' => sub {
    # A Unix-socket connect() failure (e.g. wrong permissions on the socket
    # file) makes Mojo::UserAgent's post() throw directly, before a $tx is
    # ever returned to inspect -- this bypasses the ->is_success guard below
    # entirely unless the call itself is wrapped. Point at a nonexistent
    # socket path to provoke the same class of raw exception.
    my $bad_url = 'http+unix://%2Fnonexistent%2Fpath%2Fbroker.sock/check';

    eval { KohaPluginStore::Check::PerlSyntax::_call_broker( $bad_url, '23.05', '/tmp', [] ) };
    like( $@, qr/^check_infrastructure_error/, 'raw connect failure still dies with the infrastructure-error prefix' );
};

done_testing();
