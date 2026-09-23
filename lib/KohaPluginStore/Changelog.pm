package KohaPluginStore::Changelog;

use Modern::Perl;

# Matches a "Keep a Changelog"-style version heading -- tolerant of an optional
# leading 'v' and optional surrounding brackets, e.g. "## [1.2.0] - 2026-01-01",
# "## v1.2.0", or "## 1.2.0" (rendered as <h1>-<h6> by GitHub's markdown-to-HTML
# conversion). Also tolerant of GitHub's rendered anchor-link element between
# the heading tag and the version text, e.g.
# "<h2><a id=\"user-content-...\" class=\"anchor\" href=\"...\" aria-hidden=\"true\">
# <span aria-hidden=\"true\" class=\"octicon octicon-link\"></span></a>[1.2.0] - ...</h2>"
# -- this is what GitHub's Contents API HTML rendering actually produces for
# every heading, so without this the regex would never match real-world input.
# A changelog that doesn't follow this convention simply won't match -- callers
# fall back to a plain link to the full changelog, same "regex over real-world
# text, expect rough edges" posture the rest of this store already takes with
# plugin metadata parsing.
sub extract_section {
    my ( $changelog_html, $tag_name ) = @_;

    return unless $changelog_html && $tag_name;

    ( my $version = $tag_name ) =~ s/^v//i;
    my $version_re = quotemeta($version);

    if ( $changelog_html =~ m{
            (<h[1-6][^>]*>\s*(?:<a\b[^>]*>.*?</a>\s*)?\[?v?$version_re\]?\b.*?</h[1-6]>)
            (.*?)
            (?=<h[1-6][^>]*>|\z)
        }isx
    ) {
        return $1 . $2;
    }

    return;
}

1;
