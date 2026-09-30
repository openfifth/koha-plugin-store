use Mojo::Base -strict;
use Test::More;
use Encode ();

use KohaPluginStore::Markdown;

subtest 'renders a heading alone' => sub {
    is( KohaPluginStore::Markdown::render("# Widget\n"), "<h1>Widget</h1>\n" );
};

subtest 'renders a heading and a paragraph' => sub {
    is(
        KohaPluginStore::Markdown::render("# Widget\n\nDocs.\n"),
        "<h1>Widget</h1>\n<p>Docs.</p>\n"
    );
};

subtest 'renders a list' => sub {
    is(
        KohaPluginStore::Markdown::render("- one\n- two\n"),
        "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n"
    );
};

subtest 'renders a link' => sub {
    is(
        KohaPluginStore::Markdown::render("[docs](https://example.com/docs)\n"),
        qq{<p><a href="https://example.com/docs">docs</a></p>\n}
    );
};

subtest 'passes raw HTML through unchanged -- unsafe mode; Sanitize.pm is the actual safety boundary, not this module' => sub {
    my $md = qq{<div align="center">\n<img src="https://example.com/badge.png" alt="badge">\n</div>\n};
    is( KohaPluginStore::Markdown::render($md), $md );
};

subtest 'passes a javascript: URI through unchanged -- Sanitize.pm strips it downstream, not this module' => sub {
    is(
        KohaPluginStore::Markdown::render("[click](javascript:alert(1))\n"),
        qq{<p><a href="javascript:alert(1)">click</a></p>\n}
    );
};

subtest 'does not render GFM tables specially -- plain CommonMark, no GFM extensions' => sub {
    my $md = "| a | b |\n|---|---|\n| 1 | 2 |\n";
    is(
        KohaPluginStore::Markdown::render($md),
        "<p>| a | b |\n|---|---|\n| 1 | 2 |</p>\n"
    );
};

subtest 'does not render strikethrough specially -- plain CommonMark, no GFM extensions' => sub {
    is( KohaPluginStore::Markdown::render("~~gone~~\n"), "<p>~~gone~~</p>\n" );
};

subtest 'undef and empty string pass through unchanged, same convention as Sanitize::html' => sub {
    is( KohaPluginStore::Markdown::render(undef), undef );
    is( KohaPluginStore::Markdown::render(''), '' );
};

# UTF-8 edge cases -- per the design spec's Testing plan (docs/superpowers/specs/
# 2026-09-30-markdown-rendering-design.md) and the regression that motivated it:
# CommonMark's XS binding reads the argument via SvPVutf8, which *upgrades* an
# unflagged (byte) string on the assumption it's Latin-1 before treating it as
# UTF-8. A proper Perl character string (UTF8 flag on, from decoding real input)
# is passed through as-is and renders correctly; a raw UTF-8-encoded byte string
# with no UTF8 flag gets Latin-1-upgraded and double-encoded ("mojibake").
# GitHub.pm's fetch_readme_markdown/fetch_changelog_markdown use ->text (not
# ->body) specifically so real callers only ever hand this module the former.

subtest 'a proper Perl character string containing non-ASCII renders correctly' => sub {
    my $md = "caf\x{e9}\n";    # "café" as a genuine Unicode code point, not a byte sequence
    utf8::upgrade($md);       # what GitHub.pm's ->text (a real decode) produces
    is( KohaPluginStore::Markdown::render($md), "<p>caf\x{e9}</p>\n", 'renders the accented character correctly' );
};

subtest 'a raw UTF-8 byte string (no UTF8 flag) is NOT this module\'s input contract -- pins the double-encoding failure mode' => sub {
    # Mirrors how GitHub.pm used to hand data to this module before the
    # ->text fix (Mojo::Message::Response->body returns undecoded bytes).
    # This is deliberately NOT "the fix should make this work" -- render()'s
    # contract is character strings in, not byte strings; this test exists to
    # fail loudly if some future call site regresses back to passing raw
    # bytes, same bug as the one this test suite caught in GitHub.pm.
    my $bytes = Encode::encode_utf8("caf\x{e9}\n");
    ok( !utf8::is_utf8($bytes), 'sanity: a genuine byte string, UTF8 flag off' );
    is(
        KohaPluginStore::Markdown::render($bytes),
        "<p>caf\x{c3}\x{a9}</p>\n",
        'byte input is Latin-1-upgraded then treated as UTF-8, double-encoding non-ASCII ("caf\x{c3}\x{a9}" == "cafÃ©")'
    );
};

subtest 'genuinely invalid UTF-8 is replaced with U+FFFD under OPT_VALIDATE_UTF8, not thrown' => sub {
    # An ordinary (unflagged) byte string can never trigger this path -- see
    # the previous subtest, SvPVutf8 always upgrades unflagged bytes from
    # Latin-1, which is always valid UTF-8 once re-encoded. To exercise
    # OPT_VALIDATE_UTF8's actual behaviour we need content that is genuinely
    # invalid UTF-8 *and* already flagged, which Encode::_utf8_on forces
    # (bypassing the normal encode/decode API, deliberately, for this test).
    my $bad = "caf\xff\xfeend\n";
    Encode::_utf8_on($bad);

    my $out = eval { KohaPluginStore::Markdown::render($bad) };
    is( $@, '', 'does not throw' );
    is(
        $out, "<p>caf\x{fffd}\x{fffd}end</p>\n",
        'each invalid byte is replaced with the Unicode replacement character, rendering continues normally'
    );
};

done_testing();
