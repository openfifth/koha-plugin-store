use Mojo::Base -strict;
use Test::More;
use Test::Mojo;

use lib 'lib';
use SandboxBroker;

subtest 'a minimum_version that cannot be resolved to a tag fails clearly, without touching Docker' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { die 'should not be called' };
    *SandboxBroker::_run_sandboxed   = sub { die 'should not be called' };

    $t->post_ok(
        '/check' => json => { minimum_version => 'not-a-version', files => [ { path => 'Widget.pm', content => "1;\n" } ] }
    )->status_is(422)->json_like( '/error' => qr/Could not resolve/ );
};

subtest 'no .pm files means an automatic pass, without touching Docker' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { die 'should not be called' };
    *SandboxBroker::_run_sandboxed   = sub { die 'should not be called' };

    $t->post_ok( '/check' => json => { minimum_version => '23.05', files => [] } )
      ->status_is(200)
      ->json_is( '/passed' => 1 );
};

subtest 'a checkout preparation failure is reported as a 502, not a false pass or a crash' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { return 0 };

    $t->post_ok(
        '/check' => json => { minimum_version => '23.05', files => [ { path => 'Widget.pm', content => "1;\n" } ] }
    )->status_is(502)->json_like( '/error' => qr/could not prepare Koha checkout/ );
};

subtest 'passes when the sandbox wrapper reports PASS for every file' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { return 1 };
    *SandboxBroker::_run_sandboxed   = sub { return "PASS Widget.pm\n" };

    $t->post_ok(
        '/check' => json => { minimum_version => '23.05', files => [ { path => 'Widget.pm', content => "package Widget;\n1;\n" } ] }
    )->status_is(200)->json_is( '/passed' => 1 );
};

subtest 'fails and reports the sandboxed compile error' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { return 1 };
    *SandboxBroker::_run_sandboxed   = sub {
        return "FAIL Widget.pm\nsyntax error at /plugin-root/x/Widget.pm line 2, near \"1;\"\n/plugin-root/x/Widget.pm had compilation errors.\n";
    };

    $t->post_ok(
        '/check' => json => { minimum_version => '23.05', files => [ { path => 'Widget.pm', content => "package Widget\n1;\n" } ] }
    )->status_is(200)
      ->json_is( '/passed' => 0 )
      ->json_like( '/message' => qr/syntax error/ );
};

subtest 'runtime warnings from a real Koha checkout (no koha-conf.xml) are not mistaken for a compile error' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { return 1 };
    *SandboxBroker::_run_sandboxed   = sub {
        return "unable to locate Koha configuration file koha-conf.xml at /kohadevbox/koha-all/v23.05.00.000/C4/Context.pm line 171.\n"
            . "PASS Widget.pm\n";
    };

    $t->post_ok(
        '/check' => json => { minimum_version => '23.05', files => [ { path => 'Widget.pm', content => "package Widget;\n1;\n" } ] }
    )->status_is(200)->json_is( '/passed' => 1 );
};

subtest 'a sandbox execution failure is reported as a 502, not a false pass' => sub {
    my $t = Test::Mojo->new('SandboxBroker');

    no strict 'refs';
    no warnings 'redefine';
    *SandboxBroker::_ensure_checkout = sub { return 1 };
    *SandboxBroker::_run_sandboxed   = sub { die "docker: command not found\n" };

    $t->post_ok(
        '/check' => json => { minimum_version => '23.05', files => [ { path => 'Widget.pm', content => "package Widget;\n1;\n" } ] }
    )->status_is(502)->json_like( '/error' => qr/sandbox execution failed/ );
};

done_testing();
