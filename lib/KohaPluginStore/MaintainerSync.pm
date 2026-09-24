package KohaPluginStore::MaintainerSync;

use Modern::Perl;
use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginMaintainer;

# Cross-references $repos (the permissions-carrying shape
# KohaPluginStore::GitHub::fetch_all_repos returns) against every
# plugins.repo_url, granting plugin_maintainers rows for $developer where
# GitHub's own data says they have push/admin access. One SELECT per repo --
# fine at this store's current scale; revisit with a single batched query if
# a developer's repo count ever makes this a real cost.
sub sync_from_repo_list {
    my ( $pg, $developer, $repos ) = @_;

    for my $repo (@$repos) {
        my $plugin = KohaPluginStore::Model::Plugin->new( pg => $pg )->find( { repo_url => $repo->{html_url} } );
        next unless $plugin;

        maybe_grant_for_repo( $pg, $developer, $plugin, $repo );
    }

    return;
}

# GitHub's /user/repos response already resolves org/team-based access into
# a plain permissions object for the token holder -- push or admin true is
# enough to trust automatically, no further API call needed. Returns the
# granted row, or undef if this repo's permissions don't qualify.
sub maybe_grant_for_repo {
    my ( $pg, $developer, $plugin, $repo ) = @_;

    my $permissions = $repo->{permissions} || {};
    return unless $permissions->{push} || $permissions->{admin};

    return KohaPluginStore::Model::PluginMaintainer->new( pg => $pg )->grant(
        {
            plugin_id    => $plugin->id,
            developer_id => $developer->id,
            role         => 'maintainer',
            granted_via  => 'github_access',
        }
    );
}

1;
