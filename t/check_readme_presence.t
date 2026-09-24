use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Check::ReadmePresence;

subtest 'passes when readme_html is present in the check context' => sub {
    my $check  = KohaPluginStore::Check::ReadmePresence->new;
    my $result = $check->run( '/unused', {}, { readme_html => '<h1>Widget</h1><p>Docs.</p>' } );
    ok( $result->{passed}, 'passed' );
};

subtest 'fails, and gates certification, when readme_html is missing' => sub {
    my $check  = KohaPluginStore::Check::ReadmePresence->new;
    my $result = $check->run( '/unused', {}, {} );
    ok( !$result->{passed},          'failed' );
    like( $result->{message}, qr/No README/ );
    ok( $check->gates_certification, 'gates certification' );
    ok( !$check->required,           'not a required (publish-blocking) check' );
};

done_testing();
