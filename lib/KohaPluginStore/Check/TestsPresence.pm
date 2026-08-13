package KohaPluginStore::Check::TestsPresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use KohaPluginStore::GitHub;

sub check_name         { 'tests_presence' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    # .kpz archives deliberately don't package t/*.t (they're for developer/CI
    # use, not the unpacked runtime), so the extracted archive can never show
    # tests even when the plugin has them -- look at the tagged source tree
    # on GitHub instead.
    my $has_tests = KohaPluginStore::GitHub::fetch_tag_has_test_files(
        $context->{github_token}, $context->{repo_url}, $context->{tag_name}
    );

    return { passed => 1, message => undef } if $has_tests;
    return { passed => 0, message => 'No test files (t/*.t) found in the tagged source repository' };
}

1;
