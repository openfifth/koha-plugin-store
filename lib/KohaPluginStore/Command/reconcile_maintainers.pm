package KohaPluginStore::Command::reconcile_maintainers;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::GitHub;
use KohaPluginStore::Model::PluginMaintainer;

has description => 'Revoke stale github_access-granted plugin_maintainers rows';
has usage       => sub { shift->extract_usage };

# Circuit breaker thresholds -- see the "not_found rate" comment in run()
# below and this file's own POD for why this exists.
use constant BREAKER_MIN_ROWS  => 3;
use constant BREAKER_THRESHOLD => 0.9;

sub run ($self, @args) {
    my $pg    = $self->app->pg;
    my $token = $self->app->config->{github_app_token};

    my $maintainer_model = KohaPluginStore::Model::PluginMaintainer->new( pg => $pg );
    my $rows             = $maintainer_model->for_reconciliation;
    my $total            = scalar @$rows;

    # First pass: resolve every row's GitHub check (same one fetch per row as
    # before -- no double-fetching), without acting on any of them yet, so the
    # aggregate not_found rate can be judged before any revocation happens.
    my @checked;
    my $skipped = 0;
    for my $row (@$rows) {
        my $result;
        eval {
            $result = KohaPluginStore::GitHub::fetch_collaborator_permission( $token, $row->{repo_url}, $row->{username} );
        };
        if ($@) {
            warn "plugin_maintainers.id=$row->{id}: exception checking '$row->{username}' on $row->{repo_url}: $@";
            $skipped++;
            next;
        }
        push @checked, { row => $row, result => $result };
    }

    # GitHub returns the same 404 (surfaced here as not_found) both for a
    # genuinely-gone repo/user AND for a resource the configured
    # github_app_token simply can't see (e.g. a fine-grained PAT whose
    # repository selection doesn't include it). If the token were ever
    # misconfigured that way, every row checked here would 404, and treating
    # that as "everyone lost access" would revoke every github_access-granted
    # maintainer in one unattended run. Below BREAKER_MIN_ROWS, skip the check
    # entirely -- a coincidence of a couple of genuinely-gone repos in a small
    # batch is plausible and shouldn't trip a global breaker.
    my $not_found = grep { $_->{result}->{ok} && $_->{result}->{not_found} } @checked;
    if ( $total >= BREAKER_MIN_ROWS && $total > 0 && ( $not_found / $total ) >= BREAKER_THRESHOLD ) {
        my $pct = int( ( $not_found / $total ) * 100 );
        warn "reconcile_maintainers: ABORTING -- $not_found/$total rows checked ($pct%) resolved to 'not_found'. "
            . "This looks like a systemically mis-scoped github_app_token (unable to see the repos/users it's "
            . "checking) rather than incidental gone repos or users. NO revocations were performed this run -- "
            . "any genuine revocations are deferred to the next successful run. Fix the token/config and re-run.\n";
        die "reconcile_maintainers: aborted by circuit breaker ($not_found/$total not_found)\n";
    }

    my ( $kept, $revoked ) = ( 0, 0 );
    for my $entry (@checked) {
        my ( $row, $result ) = @{$entry}{qw(row result)};

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

        eval {
            $maintainer_model->revoke( $row->{id} );
        };
        if ($@) {
            warn "plugin_maintainers.id=$row->{id}: exception revoking access: $@";
            $skipped++;
            next;
        }
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

  Circuit breaker: a 404 from GitHub is treated as "gone" (revoke-worthy), but GitHub
  also returns 404 when the github_app_token itself can't see a resource (e.g. a
  fine-grained PAT with the wrong repository selection) -- which would otherwise look
  identical to every maintainer having lost access at once. When at least 3 rows are
  checked and 90% or more of them resolve to "not found", the whole run aborts with no
  revocations performed at all (deferring any genuine revocations to the next successful
  run) and exits non-zero, rather than risk a mass false-positive wipe. Below 3 rows the
  breaker never trips, since a coincidence of a couple of genuinely-gone repos in a small
  batch is plausible.

=cut
