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
        # Each field's fetch, render, and sanitize are wrapped in one eval --
        # not just the fetch -- so a single plugin's malformed content (e.g.
        # a network-layer exception from the fetch, or any other die in this
        # chain) can't abort the whole run; that field is just left as-is,
        # same as ProcessPluginVersion.pm's own per-field guard. Note that
        # invalid UTF-8 on its own does NOT hit this path -- Markdown::render's
        # OPT_VALIDATE_UTF8 replaces invalid bytes with U+FFFD and returns
        # normally, it does not make CommonMark throw.
        my $readme_html = eval {
            my $readme_md = KohaPluginStore::GitHub::fetch_readme_markdown( $token, $row->{repo_url} );
            defined $readme_md ? KohaPluginStore::Sanitize::html( KohaPluginStore::Markdown::render($readme_md) ) : undef;
        };
        warn "plugins.id=$row->{id} ($row->{repo_url}): README re-render failed: $@" if $@;

        my $changelog_html = eval {
            my $changelog_md = KohaPluginStore::GitHub::fetch_changelog_markdown( $token, $row->{repo_url} );
            defined $changelog_md ? KohaPluginStore::Sanitize::html( KohaPluginStore::Markdown::render($changelog_md) ) : undef;
        };
        warn "plugins.id=$row->{id} ($row->{repo_url}): CHANGELOG re-render failed: $@" if $@;

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
