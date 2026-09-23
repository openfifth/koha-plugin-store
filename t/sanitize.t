use Mojo::Base -strict;
use Test::More;

use KohaPluginStore::Sanitize;

subtest 'passes through safe GitHub-rendered structure untouched' => sub {
    my $html = '<h1>Widget</h1><p>Docs with <strong>bold</strong> and <code>inline code</code>.</p>'
        . '<ul><li>one</li><li>two</li></ul>';

    is( KohaPluginStore::Sanitize::html($html), $html );
};

subtest 'keeps a normal external link and an in-page anchor link' => sub {
    my $html = '<p><a href="https://example.com/docs">docs</a></p>'
        . '<h2><a id="user-content-100" class="anchor" href="#user-content-100" aria-hidden="true">'
        . '<span aria-hidden="true" class="octicon octicon-link"></span></a>1.0.0</h2>';

    is( KohaPluginStore::Sanitize::html($html), $html );
};

subtest 'strips <script> tags and their content entirely' => sub {
    my $html = '<p>before</p><script>alert(document.cookie)</script><p>after</p>';

    is( KohaPluginStore::Sanitize::html($html), '<p>before</p><p>after</p>' );
};

subtest 'strips a javascript: URI from an <a href>, keeping the link text' => sub {
    my $html = '<a href="javascript:alert(document.cookie)">click me</a>';

    is( KohaPluginStore::Sanitize::html($html), '<a>click me</a>' );
};

subtest 'strips a javascript: URI from an <img src>' => sub {
    my $html = '<img src="javascript:alert(1)" alt="evil">';

    is( KohaPluginStore::Sanitize::html($html), '<img alt="evil">' );
};

subtest 'strips inline event handler and style attributes' => sub {
    my $html = '<p onclick="alert(1)" style="background:url(javascript:alert(1))">text</p>';

    is( KohaPluginStore::Sanitize::html($html), '<p>text</p>' );
};

subtest 'strips unknown/unsafe elements like iframe and svg, keeping any inner text' => sub {
    my $html = '<iframe src="https://evil.example"></iframe><svg onload="alert(1)"></svg><p>safe</p>';

    is( KohaPluginStore::Sanitize::html($html), '<p>safe</p>' );
};

subtest 'keeps a GitHub Flavored Markdown task-list checkbox' => sub {
    my $html = '<ul><li><input type="checkbox" disabled checked> done</li></ul>';

    is( KohaPluginStore::Sanitize::html($html), $html );
};

subtest 'undef and empty string pass through unchanged' => sub {
    is( KohaPluginStore::Sanitize::html(undef), undef );
    is( KohaPluginStore::Sanitize::html(''),    '' );
};

done_testing();
