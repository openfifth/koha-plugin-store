package KohaPluginStore::Sanitize;

use Modern::Perl;
use HTML::Scrubber;

# GitHub's markdown-to-HTML rendering (used for READMEs and changelogs, see
# KohaPluginStore::GitHub) is sanitized for GitHub's own hosting context, not
# for being re-embedded on a third-party origin -- and this store has no
# Content-Security-Policy to fall back on if that sanitizer ever has a gap.
# Since the markdown source is fully attacker-controlled (any GitHub user can
# submit a plugin) and the result is shown on a public page before any human
# review, we scrub it ourselves too, rather than treating GitHub's rendering
# alone as the store's only XSS defense. The allow-list below covers what
# GitHub Flavored Markdown actually renders to (headings, lists, tables, task
# list checkboxes, code blocks, the anchor links GitHub attaches to every
# heading) and nothing else -- notably no <script>/<style>/<iframe>/<svg>,
# no inline event handler or style attributes, and no non-http(s)/mailto/
# fragment URLs.
my @SIMPLE_TAGS = qw(
    abbr b blockquote br code dd del details dl dt em h1 h2 h3 h4 h5 h6
    hr i kbd li ol p pre s strong sub summary sup u ul
);

sub _safe_url {
    my ( undef, undef, undef, $value ) = @_;

    return $value if $value =~ m{^https?://}i;
    return $value if $value =~ m{^mailto:}i;
    return $value if $value =~ m{^#};        # GitHub's own heading-anchor links

    return ();                               # javascript:, data:, relative paths, etc.
}

my $scrubber = HTML::Scrubber->new(
    default => [
        0,                                   # deny any tag not listed below
        { '*' => 0, id => 1, class => 1 },   # attributes allowed on simply-allowed tags
    ],
    allow => \@SIMPLE_TAGS,
    rules => [
        a       => { href => \&_safe_url, id => 1, class => 1, name => 1, target => 1, rel => 1, 'aria-hidden' => 1 },
        img     => { src  => \&_safe_url, alt => 1, title => 1, width => 1, height => 1, class => 1 },
        span    => { id => 1, class => 1, 'aria-hidden' => 1 },
        div     => { id => 1, class => 1 },
        input   => { type => qr/^checkbox$/i, disabled => 1, checked => 1 },
        table   => { id => 1, class => 1 },
        thead   => 1,
        tbody   => 1,
        tfoot   => 1,
        tr      => 1,
        th      => { id => 1, class => 1, align => 1, colspan => 1, rowspan => 1 },
        td      => { id => 1, class => 1, align => 1, colspan => 1, rowspan => 1 },
    ],
    comment => 0,
    process => 0,
);

sub html {
    my ($html) = @_;

    return $html unless defined $html && length $html;
    return $scrubber->scrub($html);
}

1;
