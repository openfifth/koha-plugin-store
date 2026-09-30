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
