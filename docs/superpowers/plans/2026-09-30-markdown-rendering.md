# Markdown Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop trusting GitHub's HTML rendering pipeline for README/CHANGELOG display — fetch raw markdown ourselves and render it locally with a real CommonMark implementation, with `KohaPluginStore::Sanitize` kept as the scrubbing layer on top.

**Architecture:** `GitHub.pm` fetches raw `.md` bytes (same endpoints, `Accept: application/vnd.github.raw+json`). A new `KohaPluginStore::Markdown` module renders that markdown to HTML via `CommonMark->markdown_to_html($md, OPT_UNSAFE | OPT_VALIDATE_UTF8)`. `Sanitize.pm` scrubs the result exactly as it does today, just fed CommonMark's output instead of GitHub's. `Changelog.pm`'s heading-based excerpting is verified against real CommonMark output, not rewritten.

**Tech Stack:** Perl, Mojolicious, `CommonMark` (CPAN, wraps the C `libcmark` library), `HTML::Scrubber` (existing).

**Spec:** `docs/superpowers/specs/2026-09-30-markdown-rendering-design.md` — read it alongside this plan; this plan implements it task-by-task.

## Global Constraints

- New dependency: `CommonMark` (CPAN, author NWELLNHOF) — **not** `CommonMark::XS`, which does not exist. No exact version pin (nothing in the spec requires one).
- System dependency: `libcmark-dev` (Debian package, confirmed present in Debian 12's repos as `libcmark-dev` 0.30.2-6) must be installed wherever this is built — the Docker dev image, and the production app/worker host.
- Rendering always runs in `OPT_UNSAFE | OPT_VALIDATE_UTF8` mode — never CommonMark's default safe mode. Raw HTML in submitted markdown must keep reaching `Sanitize::html()`, unchanged, for scrubbing.
- No GFM extensions (tables/task-lists/strikethrough) — plain CommonMark only, per the spec's decision.
- `Sanitize.pm`'s allowlist itself does not change in this plan.
- `Changelog.pm`'s heading-matching regex is not rewritten unless a test proves it must be.

---

### Task 1: Add the `CommonMark` dependency and a `KohaPluginStore::Markdown` render module

**Files:**
- Modify: `cpanfile`
- Modify: `Dockerfile:12-18`
- Modify: `DEPLOYMENT.md` (System packages section, around line 19)
- Create: `lib/KohaPluginStore/Markdown.pm`
- Test: `t/markdown.t`

**Interfaces:**
- Produces: `KohaPluginStore::Markdown::render($markdown) -> $html_or_undef` — later tasks (`ProcessPluginVersion.pm`, the backfill command) call this exactly as shown.

- [ ] **Step 1: Add the `libcmark-dev` system package to the Dockerfile**

`libcmark-dev` provides the C headers/library the `CommonMark` Perl module's `Makefile.PL` needs to build against. Without it, `cpanm --installdeps .` in the Docker image will fail once `cpanfile` requires `CommonMark`.

Edit `Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    libssl-dev \
    zlib1g-dev \
    libcmark-dev \
    git \
    && rm -rf /var/lib/apt/lists/*
```

- [ ] **Step 2: Add the same system package to `DEPLOYMENT.md`**

Edit the "System packages" section's app/worker host block (around line 19):

```bash
sudo apt-get update
sudo apt-get install -y perl build-essential libpq-dev libssl-dev zlib1g-dev libcmark-dev git cpanminus
```

Add a bullet immediately after the existing one explaining `build-essential`/`libpq-dev`/etc (around line 28), matching that paragraph's style:

```markdown
- `libcmark-dev` — C headers and shared library the `CommonMark` Perl module
  (used to render README/CHANGELOG markdown, see `KohaPluginStore::Markdown`)
  builds against. Confirmed present in Debian 12's own repos (package
  `libcmark-dev`, version `0.30.2-6` at time of writing) — no third-party
  repo needed.
```

- [ ] **Step 3: Add `CommonMark` to `cpanfile`**

Edit `cpanfile`, adding after the existing `HTML::Scrubber` line (around line 17):

```perl
# Renders README/CHANGELOG markdown to HTML ourselves rather than trusting
# GitHub's own rendering pipeline -- see KohaPluginStore::Markdown and
# docs/superpowers/specs/2026-09-30-markdown-rendering-design.md. Needs the
# system libcmark-dev package to build (see DEPLOYMENT.md/Dockerfile).
requires 'CommonMark';
```

- [ ] **Step 4: Install the dependency locally and regenerate `cpanfile.snapshot`**

Per `DEVELOPMENT.md`'s documented convention for any `cpanfile` change:

```bash
cpanm --notest Carton && carton install
```

Run this somewhere `libcmark-dev` is installed (the project's Docker `app`/`worker` image after Step 1's Dockerfile change, or a host with it installed per Step 2). Commit the regenerated `cpanfile.snapshot`.

- [ ] **Step 5: Write the failing test for `KohaPluginStore::Markdown::render`**

Create `t/markdown.t`:

```perl
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
```

All expected strings above were verified against real `libcmark`/`cmark` output (version 0.30.2, the same version Debian 12 ships) before being written into this plan — they are not guesses.

- [ ] **Step 6: Run the test to verify it fails**

Run: `prove -l t/markdown.t`
Expected: FAIL — `Can't locate KohaPluginStore/Markdown.pm`.

- [ ] **Step 7: Create `lib/KohaPluginStore/Markdown.pm`**

```perl
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
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `prove -l t/markdown.t`
Expected: PASS (all subtests).

- [ ] **Step 9: Commit**

```bash
git add cpanfile cpanfile.snapshot Dockerfile DEPLOYMENT.md lib/KohaPluginStore/Markdown.pm t/markdown.t
git commit -m "Add KohaPluginStore::Markdown, rendering README/CHANGELOG ourselves via CommonMark"
```

---

### Task 2: Switch `GitHub.pm`'s README/CHANGELOG fetch to raw markdown

**Files:**
- Modify: `lib/KohaPluginStore/GitHub.pm:136-173`
- Modify: `lib/KohaPluginStore/Check/ReadmePresence.pm:9` (comment only)
- Modify: `lib/KohaPluginStore/Check/ChangelogFormat.pm:10` (comment only)
- Test: `t/github.t:336-435`

**Interfaces:**
- Consumes: nothing new from Task 1.
- Produces: `KohaPluginStore::GitHub::fetch_readme_markdown($token, $owner_repo) -> $markdown_or_undef` and `KohaPluginStore::GitHub::fetch_changelog_markdown($token, $owner_repo) -> $markdown_or_undef` (renamed from `fetch_readme_html`/`fetch_changelog_html`) — Task 3 calls these by their new names.

- [ ] **Step 1: Update the failing/renamed tests in `t/github.t` first**

Replace the six subtests spanning lines 336-435 (`'fetch_readme_html returns the raw HTML body on success'` through `'fetch_changelog_html returns undef when neither file exists'`) with:

```perl
subtest 'fetch_readme_markdown returns the raw markdown body on success' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_raw_markdown = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body("# Widget\n\nDocs.\n");
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_readme_markdown( 'token', 'https://github.com/dev/widget' ),
        "# Widget\n\nDocs.\n",
        'raw markdown returned as-is, not JSON-decoded'
    );
};

subtest 'fetch_readme_markdown returns undef on a non-200 response (no README, rate-limited, ...)' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_raw_markdown = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_readme_markdown( 'token', 'https://github.com/dev/widget' ), undef, 'undef, not a die' );
};

subtest 'fetch_readme_markdown still makes a request with no token configured' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_args;
    *KohaPluginStore::GitHub::_get_raw_markdown = sub { push @seen_args, [@_]; return _fake_tx(); };

    KohaPluginStore::GitHub::fetch_readme_markdown( undef, 'https://github.com/a/b' );
    is( scalar @seen_args, 1, 'the request was made' );
    is( $seen_args[0][1], undef, 'with no token' );
};

subtest 'fetch_changelog_markdown tries CHANGELOG.md first and returns its raw markdown body on success' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_paths;
    *KohaPluginStore::GitHub::_get_raw_markdown = sub {
        my ($url) = @_;
        push @seen_paths, $url;
        my $res = Mojo::Message::Response->new;
        $res->code(200);
        $res->body("## 1.0.0\n\nInitial release.\n");
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_changelog_markdown( 'token', 'https://github.com/dev/widget' ),
        "## 1.0.0\n\nInitial release.\n",
        'raw markdown returned as-is'
    );
    is( $seen_paths[0], 'https://api.github.com/repos/dev/widget/contents/CHANGELOG.md', 'CHANGELOG.md tried first' );
    is( scalar @seen_paths, 1, 'stops after the first successful path' );
};

subtest 'fetch_changelog_markdown falls back to CHANGES.md when CHANGELOG.md is missing' => sub {
    no strict 'refs';
    no warnings 'redefine';
    my @seen_paths;
    *KohaPluginStore::GitHub::_get_raw_markdown = sub {
        my ($url) = @_;
        push @seen_paths, $url;
        my $res = Mojo::Message::Response->new;
        $res->code( $url =~ /CHANGES\.md/ ? 200 : 404 );
        $res->body("## 1.0.0\n") if $url =~ /CHANGES\.md/;
        return bless { result => $res }, 'FakeTx';
    };

    is(
        KohaPluginStore::GitHub::fetch_changelog_markdown( 'token', 'https://github.com/dev/widget' ),
        "## 1.0.0\n"
    );
    is_deeply(
        \@seen_paths,
        [
            'https://api.github.com/repos/dev/widget/contents/CHANGELOG.md',
            'https://api.github.com/repos/dev/widget/contents/CHANGES.md',
        ],
        'both paths tried, in order'
    );
};

subtest 'fetch_changelog_markdown returns undef when neither file exists' => sub {
    no strict 'refs';
    no warnings 'redefine';
    *KohaPluginStore::GitHub::_get_raw_markdown = sub {
        my $res = Mojo::Message::Response->new;
        $res->code(404);
        return bless { result => $res }, 'FakeTx';
    };

    is( KohaPluginStore::GitHub::fetch_changelog_markdown( 'token', 'https://github.com/dev/widget' ), undef );
};
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `prove -l t/github.t`
Expected: FAIL — `undefined subroutine &KohaPluginStore::GitHub::fetch_readme_markdown` (and similarly for `fetch_changelog_markdown`/`_get_raw_markdown`).

- [ ] **Step 3: Rename the functions and change the Accept header in `GitHub.pm`**

Replace lines 136-173 of `lib/KohaPluginStore/GitHub.pm`:

```perl
sub fetch_readme_markdown {
    my ( $access_token, $owner_repo ) = @_;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;
    my $tx = _get_raw_markdown( "$api_repo/readme", $access_token );

    return unless $tx->result->code == 200;

    return $tx->result->body;
}

# Test seam, separate from _get: the README/changelog endpoints' raw-markdown
# Accept header is unique to this call, and the response body is used as-is
# (not ->json-decoded like every other _get call). We fetch raw markdown and
# render it ourselves (see KohaPluginStore::Markdown) rather than trusting
# GitHub's own rendering -- see
# docs/superpowers/specs/2026-09-30-markdown-rendering-design.md.
sub _get_raw_markdown {
    my ( $url, $access_token ) = @_;

    return Mojo::UserAgent->new->get(
        $url => { Accept => 'application/vnd.github.raw+json', _auth_header($access_token) }
    );
}

# Tries CHANGELOG.md first (the more common convention), then CHANGES.md. Reuses
# _get_raw_markdown's raw-markdown Accept header via GitHub's Contents API, which
# (unlike the README-specific /readme endpoint) returns *any* file at a given
# path when asked for the same media type.
sub fetch_changelog_markdown {
    my ( $access_token, $owner_repo ) = @_;

    my $api_repo = $owner_repo =~ s{^https://github\.com/}{https://api.github.com/repos/}r;

    for my $filename (qw(CHANGELOG.md CHANGES.md)) {
        my $tx = _get_raw_markdown( "$api_repo/contents/$filename", $access_token );
        return $tx->result->body if $tx->result->code == 200;
    }

    return;
}
```

- [ ] **Step 4: Update the two stale doc comments that name the old function**

In `lib/KohaPluginStore/Check/ReadmePresence.pm:9`, change:
```perl
# $context->{readme_html} is whatever KohaPluginStore::GitHub::fetch_readme_html
```
to:
```perl
# $context->{readme_html} is whatever KohaPluginStore::GitHub::fetch_readme_markdown
```

In `lib/KohaPluginStore/Check/ChangelogFormat.pm:10`, change:
```perl
# $context->{changelog_html} is whatever KohaPluginStore::GitHub::fetch_changelog_html
```
to:
```perl
# $context->{changelog_html} is whatever KohaPluginStore::GitHub::fetch_changelog_markdown
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `prove -l t/github.t`
Expected: PASS (all subtests, including the ones untouched by this task).

- [ ] **Step 6: Commit**

```bash
git add lib/KohaPluginStore/GitHub.pm lib/KohaPluginStore/Check/ReadmePresence.pm lib/KohaPluginStore/Check/ChangelogFormat.pm t/github.t
git commit -m "GitHub.pm: fetch raw README/CHANGELOG markdown instead of GitHub's pre-rendered HTML"
```

---

### Task 3: Wire fetch → render → sanitize into `ProcessPluginVersion.pm`

**Files:**
- Modify: `lib/KohaPluginStore/Task/ProcessPluginVersion.pm:159-164`
- Test: `t/task_process_plugin_version.t` (six mock sites: ~399-400, ~789, ~822, ~858-859, ~892-893)

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_readme_markdown`/`fetch_changelog_markdown` (Task 2), `KohaPluginStore::Markdown::render` (Task 1).
- Produces: nothing new — this task only changes how `$plugin->readme_html`/`changelog_html` are computed before storage; the stored column shapes are unchanged.

- [ ] **Step 1: Update the mocked function names and fixtures in `t/task_process_plugin_version.t`**

In the `'a fully compliant version reaches CERTIFIED'` subtest (around line 399-400), replace:

```perl
*KohaPluginStore::GitHub::fetch_readme_html            = sub { return '<h1>Widget</h1><p>Docs.</p>' };
*KohaPluginStore::GitHub::fetch_changelog_html         = sub { return '<h2>[1.0.0] - 2026-01-01</h2><p>Initial release.</p>' };
```
with:
```perl
*KohaPluginStore::GitHub::fetch_readme_markdown    = sub { return "# Widget\n\nDocs.\n" };
*KohaPluginStore::GitHub::fetch_changelog_markdown = sub { return "## [1.0.0] - 2026-01-01\n\nInitial release.\n" };
```

In the `'successful processing fetches and stores the README HTML'` subtest (around line 789), replace:
```perl
*KohaPluginStore::GitHub::fetch_readme_html        = sub { return '<h1>Widget</h1>'; };
```
with:
```perl
*KohaPluginStore::GitHub::fetch_readme_markdown = sub { return "# Widget\n"; };
```
and update its final assertion from:
```perl
is( $reloaded_plugin->readme_html, '<h1>Widget</h1>', 'readme_html populated from the README fetch' );
```
to:
```perl
is( $reloaded_plugin->readme_html, "<h1>Widget</h1>\n", 'readme_html populated from the README fetch, rendered via CommonMark and sanitized' );
```

In the `'a failed README fetch does not fail processing...'` subtest (around line 822), replace:
```perl
*KohaPluginStore::GitHub::fetch_readme_html        = sub { die "network error\n" };
```
with:
```perl
*KohaPluginStore::GitHub::fetch_readme_markdown = sub { die "network error\n" };
```
(assertions in this subtest are unchanged — it checks the *prior* stored value is untouched, not a new rendered value.)

In the `'successful processing fetches and stores the changelog HTML'` subtest (around line 858-859), replace:
```perl
*KohaPluginStore::GitHub::fetch_readme_html        = sub { return undef };
*KohaPluginStore::GitHub::fetch_changelog_html     = sub { return '<h2>1.0.0</h2><p>Initial release.</p>'; };
```
with:
```perl
*KohaPluginStore::GitHub::fetch_readme_markdown    = sub { return undef };
*KohaPluginStore::GitHub::fetch_changelog_markdown = sub { return "## 1.0.0\n\nInitial release.\n"; };
```
and update its final assertion from:
```perl
is( $reloaded_plugin->changelog_html, '<h2>1.0.0</h2><p>Initial release.</p>', 'changelog_html populated from the fetch' );
```
to:
```perl
is( $reloaded_plugin->changelog_html, "<h2>1.0.0</h2>\n<p>Initial release.</p>\n", 'changelog_html populated from the fetch, rendered via CommonMark and sanitized' );
```

In the `'a failed changelog fetch does not fail processing...'` subtest (around line 892-893), replace:
```perl
*KohaPluginStore::GitHub::fetch_readme_html        = sub { return undef };
*KohaPluginStore::GitHub::fetch_changelog_html     = sub { die "network error\n" };
```
with:
```perl
*KohaPluginStore::GitHub::fetch_readme_markdown    = sub { return undef };
*KohaPluginStore::GitHub::fetch_changelog_markdown = sub { die "network error\n" };
```
(assertions unchanged.)

All new expected HTML strings above were verified against real `libcmark`/`cmark` 0.30.2 output before being written into this plan.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `prove -l t/task_process_plugin_version.t`
Expected: FAIL on the two updated `is(...)` assertions (the mocked functions being renamed means `ProcessPluginVersion.pm` — still calling the old `fetch_readme_html`/`fetch_changelog_html` names at this point — won't hit these mocks at all, so it'll fall through to the real, unmocked function and get `undef` back from a live 404 against `https://github.com/dev/widget`; the two updated assertions will fail with `readme_html`/`changelog_html` being `undef` instead of the expected rendered string).

- [ ] **Step 3: Wire fetch → render → sanitize in `ProcessPluginVersion.pm`**

Replace lines 163-164 of `lib/KohaPluginStore/Task/ProcessPluginVersion.pm`:

```perl
    # Fetch raw markdown, render it ourselves, then scrub the result before
    # storing -- this is attacker-controlled content (any GitHub user can
    # submit a plugin) shown on a public page before any human review; see
    # KohaPluginStore::Markdown and KohaPluginStore::Sanitize for why neither
    # GitHub's rendering nor CommonMark's own output alone is treated as
    # sufficient on its own.
    my $readme_html = eval {
        KohaPluginStore::Sanitize::html(
            KohaPluginStore::Markdown::render(
                KohaPluginStore::GitHub::fetch_readme_markdown( $token, $plugin->repo_url )
            )
        )
    };
    my $changelog_html = eval {
        KohaPluginStore::Sanitize::html(
            KohaPluginStore::Markdown::render(
                KohaPluginStore::GitHub::fetch_changelog_markdown( $token, $plugin->repo_url )
            )
        )
    };
```

Add the new `use` line near the top of the file, alongside the existing `use KohaPluginStore::Sanitize;` (around line 16):

```perl
use KohaPluginStore::Markdown;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `prove -l t/task_process_plugin_version.t`
Expected: PASS (all subtests).

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Task/ProcessPluginVersion.pm t/task_process_plugin_version.t
git commit -m "ProcessPluginVersion: render fetched markdown via CommonMark before sanitizing"
```

---

### Task 4: Verify `Sanitize.pm` and `Changelog.pm` against real CommonMark output

**Files:**
- Test only: `t/sanitize.t`
- Test only: `t/changelog.t`

No production code in this task — its purpose is to confirm (with an executable test, not just reasoning) that both modules still behave correctly once fed CommonMark's output shape instead of GitHub's. Per the design spec, no rewrite is expected; this task's job is to prove that, and to leave a permanent regression test behind either way.

**Interfaces:** none — pure test additions against existing `KohaPluginStore::Sanitize::html` and `KohaPluginStore::Changelog::extract_section`/`has_version_heading`.

- [ ] **Step 1: Add a CommonMark-output regression subtest to `t/sanitize.t`**

Add before `done_testing();`:

```perl
subtest 'scrubs a CommonMark-rendered raw-HTML centered badge (unsafe-mode output), stripping the disallowed align attribute but keeping the tag and the allowed img attributes' => sub {
    # This is real KohaPluginStore::Markdown::render() output for:
    #   <div align="center">
    #   <img src="https://example.com/badge.png" alt="badge">
    #   </div>
    # (verified separately in t/markdown.t) -- fed through Sanitize::html here
    # to confirm the existing allowlist still behaves correctly once GitHub's
    # renderer is no longer the thing producing this HTML.
    my $html = qq{<div align="center">\n<img src="https://example.com/badge.png" alt="badge">\n</div>\n};

    is(
        KohaPluginStore::Sanitize::html($html),
        qq{<div>\n<img src="https://example.com/badge.png" alt="badge">\n</div>\n},
        'div\'s disallowed align attribute is dropped (div\'s rule only permits id/class), img is kept as-is'
    );
};
```

- [ ] **Step 2: Run it to confirm it passes as-is (no `Sanitize.pm` change expected)**

Run: `prove -l t/sanitize.t`
Expected: PASS. If this fails, stop and re-open the design's "raw HTML support" decision with the user before touching `Sanitize.pm` — that would mean the allowlist doesn't behave the way the spec assumed against CommonMark's actual output shape.

- [ ] **Step 3: Add a CommonMark-output regression subtest to `t/changelog.t`**

Add before `done_testing();`:

```perl
subtest 'extracts a section from real CommonMark-rendered output (not GitHub-anchor-wrapped HTML)' => sub {
    # This is real KohaPluginStore::Markdown::render() output for:
    #   ## [1.1.0] - 2026-02-01
    #
    #   Added a widget.
    #
    #   ## [1.0.0] - 2026-01-01
    #
    #   Initial release.
    # (verified separately) -- CommonMark's headings carry no GitHub anchor
    # wrapper, unlike the fixtures above -- this confirms extract_section
    # still works against that simpler shape without any code change.
    my $html = "<h2>[1.1.0] - 2026-02-01</h2>\n<p>Added a widget.</p>\n"
        . "<h2>[1.0.0] - 2026-01-01</h2>\n<p>Initial release.</p>\n";

    my $section = KohaPluginStore::Changelog::extract_section( $html, 'v1.1.0' );
    like( $section, qr/Added a widget\./, 'matched entry included' );
    unlike( $section, qr/Initial release\./, 'older entry not included' );
};

subtest 'has_version_heading recognizes a real CommonMark-rendered heading' => sub {
    ok(
        KohaPluginStore::Changelog::has_version_heading("<h2>[1.2.0] - 2026-01-01</h2>\n<p>Notes.</p>\n"),
        'CommonMark output (no GitHub anchor wrapper) is recognized'
    );
};
```

- [ ] **Step 4: Run it to confirm it passes as-is (no `Changelog.pm` change expected)**

Run: `prove -l t/changelog.t`
Expected: PASS. If this fails, stop — it means CommonMark's heading output doesn't match what `extract_section`'s regex expects, and `Changelog.pm` needs a real fix, which is bigger than this task's scope; re-open that with the user rather than improvising a fix here.

- [ ] **Step 5: Commit**

```bash
git add t/sanitize.t t/changelog.t
git commit -m "Add regression coverage: Sanitize and Changelog against real CommonMark output"
```

---

### Task 5: One-off backfill command for already-stored plugins

**Files:**
- Create: `lib/KohaPluginStore/Command/backfill_markdown_rendering.pm`
- Test: `t/command_backfill_markdown_rendering.t`

**Interfaces:**
- Consumes: `KohaPluginStore::GitHub::fetch_readme_markdown`/`fetch_changelog_markdown` (Task 2), `KohaPluginStore::Markdown::render` (Task 1), `KohaPluginStore::Sanitize::html` (existing).
- Produces: nothing consumed by later tasks — this is the last task in the plan.

Correction versus the design spec's wording: the spec says "iterate all existing `plugin_versions` rows" — this is imprecise. `readme_html`/`changelog_html` are columns on `plugins` (confirmed in `lib/KohaPluginStore/Model/Plugin.pm:15`'s `_columns` list and `ProcessPluginVersion.pm`'s `$plugin->update(...)` call), not on `plugin_versions`. This task iterates `plugins` rows.

- [ ] **Step 1: Write the failing test**

Create `t/command_backfill_markdown_rendering.t`, modeled directly on the existing `t/command_backfill_koha_versions.t` pattern:

```perl
use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore;
use KohaPluginStore::Command::backfill_markdown_rendering;
use KohaPluginStore::Model::Plugin;

reset_db();

my $plugin = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'Widget', repo_url => 'https://github.com/dev/widget', readme_html => '<p>Old readme</p>' }
);
my $plugin_no_readme = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->create(
    { name => 'NoReadme', repo_url => 'https://github.com/dev/noreadme' }
);

no strict 'refs';
no warnings 'redefine';
*KohaPluginStore::GitHub::fetch_readme_markdown = sub {
    my ( $token, $owner_repo ) = @_;
    return "# Widget\n\nDocs.\n" if $owner_repo eq 'https://github.com/dev/widget';
    return undef;
};
*KohaPluginStore::GitHub::fetch_changelog_markdown = sub {
    my ( $token, $owner_repo ) = @_;
    return "## 1.0.0\n\nInitial release.\n" if $owner_repo eq 'https://github.com/dev/widget';
    return undef;
};

my $app = KohaPluginStore->new;
$app->pg( test_pg() );

KohaPluginStore::Command::backfill_markdown_rendering->new( app => $app )->run;

my $reloaded = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin->id } );
is( $reloaded->readme_html, "<h1>Widget</h1>\n<p>Docs.</p>\n", 'readme_html re-rendered through the new pipeline' );
is( $reloaded->changelog_html, "<h2>1.0.0</h2>\n<p>Initial release.</p>\n", 'changelog_html re-rendered through the new pipeline' );

my $reloaded_no_readme = KohaPluginStore::Model::Plugin->new( pg => test_pg() )->find( { id => $plugin_no_readme->id } );
is( $reloaded_no_readme->readme_html, undef, 'a plugin with no fetchable README is left with no readme_html' );

done_testing();
```

- [ ] **Step 2: Run it to verify it fails**

Run: `prove -l t/command_backfill_markdown_rendering.t`
Expected: FAIL — `Can't locate KohaPluginStore/Command/backfill_markdown_rendering.pm`.

- [ ] **Step 3: Write the command, modeled on `KohaPluginStore::Command::backfill_koha_versions`**

Create `lib/KohaPluginStore/Command/backfill_markdown_rendering.pm`:

```perl
package KohaPluginStore::Command::backfill_markdown_rendering;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::GitHub;
use KohaPluginStore::Markdown;
use KohaPluginStore::Sanitize;

has description => 'Re-render existing plugins\' README/CHANGELOG through fetch->render->sanitize';
has usage       => sub { shift->extract_usage };

# One-shot, run manually post-deploy (not scheduled) -- see
# docs/superpowers/specs/2026-09-30-markdown-rendering-design.md. Existing
# plugins.readme_html/changelog_html were rendered by the old GitHub-HTML
# pipeline; this re-fetches raw markdown and re-renders it through the new
# one, so stored HTML doesn't lag behind until each plugin's next release.
sub run ($self, @args) {
    my $pg    = $self->app->pg;
    my $token = $self->app->config->{github_app_token};

    my $rows = $pg->db->query('SELECT id, repo_url FROM plugins')->hashes;

    my $updated = 0;
    for my $row (@$rows) {
        my $readme_md    = eval { KohaPluginStore::GitHub::fetch_readme_markdown( $token, $row->{repo_url} ) };
        my $changelog_md = eval { KohaPluginStore::GitHub::fetch_changelog_markdown( $token, $row->{repo_url} ) };

        my $readme_html =
            defined $readme_md ? KohaPluginStore::Sanitize::html( KohaPluginStore::Markdown::render($readme_md) ) : undef;
        my $changelog_html =
            defined $changelog_md
            ? KohaPluginStore::Sanitize::html( KohaPluginStore::Markdown::render($changelog_md) )
            : undef;

        next unless defined $readme_html || defined $changelog_html;

        $pg->db->update(
            'plugins',
            {
                ( defined $readme_html    ? ( readme_html    => $readme_html )    : () ),
                ( defined $changelog_html ? ( changelog_html => $changelog_html ) : () ),
            },
            { id => $row->{id} }
        );
        $updated++;
    }

    say "Re-rendered README/CHANGELOG for $updated of " . scalar(@$rows) . " plugin(s).";
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::backfill_markdown_rendering - Re-render existing README/CHANGELOG through the CommonMark pipeline

=head1 SYNOPSIS

  Usage: APPLICATION backfill_markdown_rendering

=cut
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `prove -l t/command_backfill_markdown_rendering.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/KohaPluginStore/Command/backfill_markdown_rendering.pm t/command_backfill_markdown_rendering.t
git commit -m "Add backfill_markdown_rendering command for existing plugins"
```

- [ ] **Step 6: Run the full test suite once, to confirm nothing else broke**

Run: `prove -l t/`
Expected: PASS (aside from the pre-existing, already-known-stale `t/login.t`, per `CLAUDE.md`'s note that it tests a login flow that no longer matches the app).

Before running this against a live shared dev database, check the project's existing shared-test-DB caution (`t/lib/TestDB.pm`'s `reset_db()` truncates `plugins`/`plugin_versions`/etc. — coordinate with anyone else using the same worktree's Postgres instance first, same as any other `prove -l t/` run in this project).

- [ ] **Step 7: Run the manual production backfill (post-deploy, not part of this test run)**

Once deployed: `script/koha_plugin_store backfill_markdown_rendering`. Not something to run against the shared dev database as part of this plan's implementation — this step is documentation of the real one-time production action the spec called for, to run only after this code has actually shipped to production.

---

## Self-Review Notes

- **Spec coverage:** library choice (Task 1), raw-HTML-kept-via-Sanitize (Tasks 1+3+4), module boundary (Task 1: `Markdown.pm` separate from `GitHub.pm`/`Sanitize.pm`), fetch path change (Task 2), `Changelog.pm` verified-not-rewritten (Task 4), backfill (Task 5), `DEPLOYMENT.md`/system dependency (Task 1) — all covered.
- **Correction applied:** the spec's backfill description said `plugin_versions`; Task 5 corrects this to `plugins`, the table that actually holds these columns.
- **Type/name consistency check:** `fetch_readme_markdown`/`fetch_changelog_markdown` (Task 2) are the exact names used by Task 3 and Task 5; `KohaPluginStore::Markdown::render` (Task 1) is the exact name used by Task 3 and Task 5; `_get_raw_markdown` (Task 2, renamed from `_get_readme`) is used consistently across all of `t/github.t`'s mocks in Task 2.
