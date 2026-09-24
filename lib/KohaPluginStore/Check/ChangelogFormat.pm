package KohaPluginStore::Check::ChangelogFormat;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use KohaPluginStore::Changelog;

sub check_name         { 'changelog_format' }
sub required            { 0 }
sub gates_certification { 1 }

# $context->{changelog_html} is whatever KohaPluginStore::GitHub::fetch_changelog_html
# found (CHANGELOG.md, falling back to CHANGES.md) -- already fetched and
# sanitized by Task::ProcessPluginVersion before checks run, so this doesn't
# make its own GitHub API call. Not a full Keep a Changelog / Common Changelog
# validator (section names, dates, "Unreleased" aren't checked) -- just "is
# there at least one recognizable version heading," the same heading shape
# KohaPluginStore::Changelog::extract_section needs to excerpt a release's
# notes, so this also acts as a canary for that feature.
sub run ($self, $extract_dir, $metadata, $context) {
    my $changelog_html = $context->{changelog_html};

    return { passed => 0, message => 'No CHANGELOG.md or CHANGES.md found in the repository' }
        unless $changelog_html;

    return { passed => 1, message => undef }
        if KohaPluginStore::Changelog::has_version_heading($changelog_html);

    return {
        passed  => 0,
        message => 'CHANGELOG.md/CHANGES.md found, but no recognizable version heading '
            . '(e.g. "## [1.2.0] - 2026-01-01") in Keep a Changelog / Common Changelog style',
    };
}

1;
