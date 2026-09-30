package KohaPluginStore::Markdown;

use Modern::Perl;
use CommonMark qw(:opt);

# Renders raw markdown to HTML ourselves, rather than trusting GitHub's own
# rendering pipeline (see KohaPluginStore::GitHub) -- see
# docs/superpowers/specs/2026-09-30-markdown-rendering-design.md.
#
# OPT_UNSAFE keeps raw HTML embedded in the source (badges, <details> blocks,
# centered images) passing through into the output, exactly as GitHub's own
# renderer did -- KohaPluginStore::Sanitize is what actually enforces safety
# on the result, same as it does today for GitHub's output; this module is
# not a security boundary on its own.
#
# OPT_VALIDATE_UTF8 is a deliberate defensive addition beyond what GitHub's
# pipeline needed: this now renders arbitrary community-submitted markdown
# directly, rather than markdown GitHub's own pipeline had already absorbed.
sub render {
    my ($markdown) = @_;

    return $markdown unless defined $markdown && length $markdown;
    return CommonMark->markdown_to_html( $markdown, OPT_UNSAFE | OPT_VALIDATE_UTF8 );
}

1;
