use Mojo::Base -strict;
use Test::More;

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

done_testing();
