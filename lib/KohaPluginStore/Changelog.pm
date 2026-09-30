package KohaPluginStore::Changelog;

use Modern::Perl;

# Matches a "Keep a Changelog"-style version heading's *plain-text* rendering
# -- tolerant of an optional leading 'v' and optional surrounding brackets,
# e.g. "[1.2.0] - 2026-01-01", "v1.2.0", or "1.2.0 (2026-01-01)". Anchored to
# the start of the heading's text so a heading like "Version 1.2 update"
# doesn't count.
#
# Matched against tag-stripped heading text rather than the heading's raw
# HTML: GitHub's Contents API has rendered a version heading two different
# ways seen in the wild -- "<h2><a ...>(permalink icon)</a>[1.2.0] - ...</h2>"
# (an anchor *before* the version text) and, once a changelog has enough
# history to link each version to its compare view, "<h2><a
# href=\".../compare/...\">1.2.0</a> - ...</h2>" (the version text itself
# *inside* the anchor). Matching HTML structure directly means picking one of
# those shapes and breaking on the other; stripping tags first and checking
# the resulting text sidesteps needing to track GitHub's exact markup at all.
my $VERSION_TEXT_RE = qr{^\[?v?(\d+(?:\.\d+){1,3})\]?\b}i;

# Returns each heading in $html as { level, text (tags stripped), start, end },
# in document order. Shared by extract_section and has_version_heading so both
# recognize the same heading shape.
sub _headings {
    my ($html) = @_;

    my @headings;
    while ( $html =~ m{<h([1-6])[^>]*>(.*?)</h\1>}gis ) {
        # Capture match boundaries before running any other regex below --
        # @-/@+ are global and a later substitution would overwrite them.
        my ( $level, $inner, $start, $end ) = ( $1, $2, $-[0], $+[0] );
        ( my $text = $inner ) =~ s/<[^>]+>//g;
        $text =~ s/^\s+//;
        push @headings, { level => $level, text => $text, start => $start, end => $end };
    }

    return @headings;
}

# A changelog that doesn't follow this convention simply won't match --
# callers fall back to a plain link to the full changelog, same "regex over
# real-world text, expect rough edges" posture the rest of this store already
# takes with plugin metadata parsing.
sub extract_section {
    my ( $changelog_html, $tag_name ) = @_;

    return unless $changelog_html && $tag_name;

    ( my $version = $tag_name ) =~ s/^v//i;

    my @headings = _headings($changelog_html);

    for my $i ( 0 .. $#headings ) {
        my $heading = $headings[$i];
        next unless $heading->{text} =~ $VERSION_TEXT_RE && $1 eq $version;

        # The section runs until the next heading at the same or shallower
        # level -- not just the next heading of any level, which would stop
        # at this version's own "### Added"/"### Fixed" subsections and
        # excerpt nothing but the heading itself.
        my $end = length($changelog_html);
        for my $j ( $i + 1 .. $#headings ) {
            if ( $headings[$j]{level} <= $heading->{level} ) {
                $end = $headings[$j]{start};
                last;
            }
        }

        return substr( $changelog_html, $heading->{start}, $end - $heading->{start} );
    }

    return;
}

# Generic counterpart to extract_section's per-version heading match -- any
# semver-shaped heading, not one tied to a specific tag. Used by
# KohaPluginStore::Check::ChangelogFormat to check "is this recognizable as a
# Keep a Changelog / Common Changelog style changelog at all" without trying
# to validate every rule of either spec (section names, dates, "Unreleased").
# A changelog with no heading matching this can't be excerpted by
# extract_section either, so this doubles as a canary for that feature.
sub has_version_heading {
    my ($html) = @_;

    return 0 unless defined $html && length $html;

    for my $heading ( _headings($html) ) {
        return 1 if $heading->{text} =~ $VERSION_TEXT_RE;
    }

    return 0;
}

1;
