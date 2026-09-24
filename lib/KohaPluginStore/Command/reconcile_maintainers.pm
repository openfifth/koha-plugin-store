package KohaPluginStore::Command::reconcile_maintainers;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::GitHub;
use KohaPluginStore::Model::PluginMaintainer;

has description => 'Revoke stale github_access-granted plugin_maintainers rows';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg    = $self->app->pg;
    my $token = $self->app->config->{github_app_token};

    my $maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => $pg );
    my $rows             = $maintainer_model->for_reconciliation;

    my ( $kept, $revoked, $skipped ) = ( 0, 0, 0 );
    for my $row (@$rows) {
        my $result = KohaPluginStore::GitHub::fetch_collaborator_permission( $token, $row->{repo_url}, $row->{username} );

        unless ( $result->{ok} ) {
            warn "plugin_maintainers.id=$row->{id}: could not verify '$row->{username}' on $row->{repo_url}, leaving unchanged\n";
            $skipped++;
            next;
        }

        my $permission = $result->{permission} // 'none';
        if ( $permission eq 'admin' || $permission eq 'write' ) {
            $kept++;
            next;
        }

        $maintainer_model->revoke( $row->{id} );
        $revoked++;
    }

    say "Reconciled maintainers: $kept kept, $revoked revoked, $skipped skipped (could not verify).";
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::reconcile_maintainers - Revoke stale plugin_maintainers rows

=head1 SYNOPSIS

  Usage: APPLICATION reconcile_maintainers

  Re-checks every github_access-granted plugin_maintainers row against GitHub's current
  per-repo collaborator permission for that developer, using github_app_token. Below
  write/admin, or the repo/user no longer resolves at all, revokes the row. A row granted
  'creator' or 'manual' is never touched. An API call that fails outright (rate limit,
  network error, insufficient app-token scope) leaves that row unchanged rather than
  guessing.

=cut
