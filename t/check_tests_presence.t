use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::TestsPresence;

subtest 'passes when the tagged source tree has a t/*.t file' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_tag_has_test_files = sub { return 1 };

    my $check = KohaPluginStore::Check::TestsPresence->new;
    my $result =
        $check->run( '/unused', {},
        { github_token => 't', repo_url => 'https://github.com/dev/widget', tag_name => 'v1.0.0' } );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails, and gates certification, when the tagged source tree has no tests' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::fetch_tag_has_test_files = sub { return 0 };

    my $check = KohaPluginStore::Check::TestsPresence->new;
    my $result =
        $check->run( '/unused', {},
        { github_token => 't', repo_url => 'https://github.com/dev/widget', tag_name => 'v1.0.0' } );
    ok( !$result->{passed},         'failed' );
    ok( $check->gates_certification, 'gates certification' );
};

done_testing();
