package KohaPluginStore::Check::ReadmePresence;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;

sub check_name         { 'readme_presence' }
sub required            { 0 }
sub gates_certification { 1 }

# $context->{readme_html} is whatever KohaPluginStore::GitHub::fetch_readme_html
# found via GitHub's own README detection (README.md, README.rst, bare README,
# ...) -- already fetched and sanitized by Task::ProcessPluginVersion before
# checks run, so this doesn't make its own GitHub API call.
sub run ($self, $extract_dir, $metadata, $context) {
    return { passed => 1, message => undef } if $context->{readme_html};

    return { passed => 0, message => 'No README found in the repository' };
}

1;
