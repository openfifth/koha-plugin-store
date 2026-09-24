# Auto-Sync Releases Design

**Status:** Approved, ready for implementation planning.

## Problem

Submitting a new plugin release today requires a maintainer to visit
`/plugins/:slug/manage` and click "Add this release" for each new GitHub
release, one at a time. A maintainer who tags releases regularly has to
remember to do this every time. This spec adds an opt-in mechanism so the
store can pick up new releases on its own.

## Goals

- Let any maintainer of a plugin opt that specific plugin into automatic
  release ingestion.
- Detect and submit every GitHub release not yet recorded as a
  `plugin_versions` row, on a nightly schedule, using exactly the same
  eligibility rule a manual submission already uses (tag not yet present,
  exactly one `.kpz` asset).
- Also let a maintainer trigger an immediate check, instead of waiting for
  the nightly run, since the underlying job-based design makes this nearly
  free.
- Never surprise anyone: opted-out (the default) plugins behave exactly as
  they do today.

## Non-goals

- No email or other maintainer-facing notification system. This spec relies
  entirely on the plugin's own pages (which already display each version's
  processing status) to surface outcomes; a release that never even becomes
  a `plugin_versions` row (e.g. no `.kpz` asset) produces no persisted
  record, same as if a maintainer never clicked "add" for it.
- No webhook-based, real-time ingestion. The store has no public inbound
  endpoint or webhook-secret handling today, and building that is a
  materially bigger project than a nightly poll. This design deliberately
  separates "decide a plugin needs checking" (the nightly scan, or the
  manual button) from "check one plugin and submit what's eligible" (the
  per-plugin job) specifically so a future webhook handler could enqueue
  that same per-plugin job instead of waiting on the nightly scan or a
  manual click — without needing to change the job itself. That future work
  is out of scope here.
- No per-release opt-out, no organization-level opt-in (the `organizations`
  table exists in the schema but stays unpopulated, per the co-maintainer
  model spec) — this is a single boolean per plugin.
- No change to the manual submission flows (`new_release`, `new_plugin`,
  `bulk_import`) or to `manage()`'s own existing GitHub-releases display
  logic, beyond factoring out the one pure helper described below.

## Data model

One new column, added in migration 11:

```sql
-- 11 up
ALTER TABLE plugins ADD COLUMN auto_sync_releases BOOLEAN NOT NULL DEFAULT false;

-- 11 down
ALTER TABLE plugins DROP COLUMN auto_sync_releases;
```

`Model::Plugin`'s `_columns` gains `auto_sync_releases`.

## Shared eligibility helper

`Controller::Plugins.pm` already contains, in **four** places (`manage()`,
`add_form()`, `new_plugin_confirm()`, and `bulk_import()`), calls to a
private helper, `_kpz_assets($release)`, whose own comment explains its
dual-context contract: "a Perl grep, so scalar context returns a count, list
context the matching assets" — two call sites use it as a count
(`manage()`, `add_form()`), the other two use it in list context to pull out
the actual matching asset's `browser_download_url` for `kpz_url`
(`new_plugin_confirm()`, `bulk_import()`). This spec moves that helper,
unchanged in behavior, to `KohaPluginStore::GitHub::kpz_assets($release)` —
a straight rename/relocation, not a rewrite — and builds one new, additional
pure function on top of it:

```perl
sub kpz_assets {
    my ($release) = @_;
    return grep { $_->{name} =~ /\.kpz$/ } @{ $release->{assets} };
}

# Returns the subset of $releases (as returned by fetch_releases) that are
# both new (tag not in $existing_tags) and carry exactly one '.kpz' asset --
# the same eligibility rule a manual submission already enforces.
sub new_releases {
    my ( $releases, $existing_tags ) = @_;
    return [ grep { !$existing_tags->{ $_->{tag_name} } && kpz_assets($_) == 1 } @$releases ];
}
```

All four existing `_kpz_assets(...)` call sites in `Controller::Plugins.pm`
are updated to call `KohaPluginStore::GitHub::kpz_assets(...)` instead —
same calling convention, same context-dependent return value, so none of
their surrounding logic changes. `bulk_import()` additionally gets the
option to replace its own inline `grep { !$existing_tags{...} && ... }`
one-liner with `GitHub::new_releases(...)`, since that's now exactly the
same computation; this is a small cleanup alongside the rename, not a
behavior change. `manage()` is **not** changed to use `new_releases` — it
needs a per-release *reason* for ineligibility ("already submitted" vs "no
`.kpz` asset") to display in its table, which that pure yes/no filter
doesn't provide; its existing loop stays as-is, just calling the relocated
`kpz_assets` by its new name.

## The job

**`KohaPluginStore::Command::sync_plugin_releases`** (new Mojolicious
command, run nightly via systemd timer — same shape as
`reconcile_maintainers`):

```perl
sub run ($self, @args) {
    my @plugins = KohaPluginStore::Model::Plugin->new( pg => $self->app->pg )
        ->search( { auto_sync_releases => 1 } );

    $self->app->minion->enqueue( sync_plugin_release => [ $_->id ] ) for @plugins;

    say 'Enqueued release sync for ' . scalar(@plugins) . ' opted-in plugin(s).';
}
```

It makes no GitHub calls itself and touches no `plugin_versions` rows — it
only fans work out, so one plugin's bad data or a GitHub outage can't block
or crash a run that covers every other opted-in plugin (this is the
isolation property Approach B was chosen for over a single inline loop).

**`KohaPluginStore::Task::SyncPluginRelease`** (new Minion task, job name
`sync_plugin_release`, one job per plugin, enqueued both by the nightly
command above and by the manual-trigger route below):

```perl
sub run {
    my ( $job, $plugin_id ) = @_;

    my $pg     = $job->app->pg;
    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $pg )->find( { id => $plugin_id } );
    return $job->fail("plugin_id=$plugin_id not found") unless $plugin;

    my $token    = $job->app->config->{github_app_token};
    my $releases = KohaPluginStore::GitHub::fetch_releases( $token, $plugin->repo_url );

    my %existing_tags = map { $_->tag_name => 1 }
        KohaPluginStore::Model::PluginVersion->new( pg => $pg )->search( { plugin_id => $plugin->id } );

    my $eligible = KohaPluginStore::GitHub::new_releases( $releases, \%existing_tags );

    for my $release (@$eligible) {
        my @kpz_assets = KohaPluginStore::GitHub::kpz_assets($release);
        my $new_version = eval {
            KohaPluginStore::Model::PluginVersion->new( pg => $pg )->create(
                {
                    plugin_id         => $plugin->id,
                    tag_name          => $release->{tag_name},
                    name              => $release->{name},
                    date_released     => $release->{published_at},
                    kpz_url           => $kpz_assets[0]->{browser_download_url},
                    author_username   => $release->{author}->{login},
                    author_avatar_url => $release->{author}->{avatar_url},
                    status            => 'submitted',
                }
            );
        };
        unless ($new_version) {
            warn "sync_plugin_release: plugin_id=$plugin_id tag=$release->{tag_name}: $@";
            next;
        }
        $job->app->minion->enqueue( process_plugin_version => [ $new_version->id ], { attempts => 3 } );
    }
}
```

Each release's create-and-enqueue is wrapped in its own `eval` (matching the
`reconcile_maintainers` fix from the co-maintainer branch) so one release
failing — including the ordinary case of a concurrent manual submission
racing this job for the same tag, which trips the `plugin_versions`
unique-constraint — can't stop the rest of that plugin's eligible releases
from being processed, and can't crash the job.

## Manual trigger

New route:

```perl
$r->post('/plugins/:slug/sync-releases')->requires( user_authenticated => 1 )->to('plugins#sync_releases_now');
```

New controller action, `Controller::Plugins::sync_releases_now`, following
`update_plugin`'s existing shape exactly: look up the plugin by slug (404 if
missing), require `is_maintained_by($developer_id)` (401 if not — any
maintainer, not owner-only, matching every other maintainer-parity field),
CSRF-protect, then:

```perl
$c->minion->enqueue( sync_plugin_release => [ $plugin->id ] );
return $c->redirect_to( '/plugins/' . $plugin->slug . '/manage' );
```

There is no flash-message system in this app, so the redirect carries no
inline confirmation. The manage page will reflect the new version once the
worker processes the job — typically a few seconds — the same way a
freshly-submitted version already shows as `submitted` before its checks
finish. This is an accepted, minor UX rough edge, not a defect: adding a
flash-message system is out of scope for this spec.

## UI

On `/plugins/:slug/manage` (already maintainer-gated), add near the top of
the page, above the "Releases from github" table:

- A checkbox bound to `auto_sync_releases`, submitted via its own small
  form POSTing to a new route:

  ```perl
  $r->post('/plugins/:slug/auto-sync')->requires( user_authenticated => 1 )->to('plugins#toggle_auto_sync');
  ```

  Kept separate from `update_plugin`'s `/edit` action, since that action's
  field-processing loop assumes every field is required non-empty text — a
  boolean toggle doesn't fit that validation shape.
- A "Check for new releases now" button, `form_for` posting to
  `/plugins/:slug/sync-releases` (no fields needed beyond the CSRF token).

`Controller::Plugins::toggle_auto_sync` follows the same authorization shape
as `sync_releases_now`: look up by slug (404), require
`is_maintained_by($developer_id)` (401 — any maintainer), CSRF-protect
(403), then `$plugin->update({ auto_sync_releases => $c->param('auto_sync_releases') ? 1 : 0 })`
and redirect back to `/plugins/:slug/manage`.

## Error handling

- No `.kpz` asset on an otherwise-new release, or a GitHub API error
  fetching releases for a plugin: the release (or that plugin's whole check,
  on an API error) is skipped; nothing is logged beyond Perl's own `warn` to
  the worker's log — no `plugin_versions` row, no other visible trace. This
  matches the "skip + log only" precedent from `reconcile_maintainers`.
- A release that *does* get submitted but then fails `process_plugin_version`'s
  own certification checks behaves exactly as it does for a manual
  submission today (`status = 'changes_requested'`, `error_message` set,
  visible on the plugin's page) — this path is unchanged by this spec.
- A create-time unique-constraint race (this job and a concurrent manual
  submission both try to create the same tag) is caught by the per-release
  `eval` and treated as a skip, not a failure — one of the two submissions
  wins, the other is a no-op, matching this store's existing
  tag-uniqueness handling elsewhere (`new_plugin_confirm`, `bulk_import`).

## Deployment

New `koha_plugin_store-sync-plugin-releases.service.example` and
`.timer.example`, identical in structure to the reconciliation job's units
(`Type=oneshot`, `OnCalendar=daily`), documented in `DEPLOYMENT.md`
alongside the existing "Maintainer reconciliation" section.

## Testing

- `t/github.t`: unit tests for `GitHub::new_releases` (already-submitted tag
  excluded, missing/multiple `.kpz` assets excluded, a genuinely new
  single-`.kpz` release included) and `kpz_asset_count`.
- New `t/command_sync_plugin_releases.t`: the command enqueues exactly one
  `sync_plugin_release` job per `auto_sync_releases = true` plugin, none for
  opted-out plugins, and makes no GitHub calls itself.
- New `t/task_sync_plugin_release.t`: mocked `fetch_releases` — a new
  eligible release creates a `plugin_versions` row and enqueues
  `process_plugin_version`; an already-submitted tag is skipped; a release
  without a valid `.kpz` is skipped; one release's DB failure (simulated)
  doesn't stop a second, genuinely eligible release in the same run from
  being processed.
- `t/plugins_manage.t`: the toggle and "sync now" button render on the
  manage page; a non-maintainer gets 401 from both new routes; a maintainer
  (not just the owner) can successfully use both.

## Open risk, acknowledged

`github_app_token` (the store's single, shared, public-repos-read-only
token) now serves one more caller. At realistic catalogue sizes this is far
under GitHub's REST rate limits (5000 req/hour for an authenticated token);
if the plugin catalogue grows enough for this to matter, the nightly
command could stagger enqueues or the task could back off on a 429 —
neither is needed at today's scale, so neither is built here.
