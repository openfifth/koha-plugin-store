# Private Plugins Design

**Status:** Approved, ready for implementation planning.

## Problem

Developers using this store also build bespoke, customer-specific plugins
(e.g. a Telford ERP integration, a WSCC Oracle integration) that have no
business being discoverable by the general public, but would still benefit
from the store's submission, certification, and signing pipeline — a
signed `.kpz` a customer's Koha instance can verify is genuinely worth
having even for a one-off integration.

## Goals

- Let a maintainer mark a plugin as private, at submission time or later.
- A private plugin never appears in the homepage catalogue (`/`), the
  public discovery API (`/api/plugins`), or the public author page
  (`/authors/:slug`).
- A private plugin still goes through the exact same certification and
  signing pipeline as a public one — "private" is a listing concern, not a
  trust/quality shortcut.
- A maintainer can still reach the plugin's own page and download its
  signed `.kpz` via a direct link, and hand that link to the customer
  directly — no new authentication for the customer's Koha instance.
- A maintainer can tell their private plugins apart from their public ones
  at a glance on `/my-plugins`.

## Non-goals

- No customer-specific access control (an API key or token scoped to a
  particular Koha instance, letting it auto-discover or auto-update a
  private plugin the way public plugins already work). This would need a
  real credential concept that doesn't exist anywhere in this app today,
  and is a materially bigger project. This design deliberately doesn't
  block it: a future "issue this Koha instance a scoped token" feature
  would sit entirely on top of the `is_private` flag added here, not
  require reworking it.
- No "maintainer-only" (fully access-controlled) visibility tier. The
  chosen model is unlisted-but-linkable — anyone with the direct URL can
  view the page and download the `.kpz`, matching how an unlisted video
  works. If a stricter tier is ever needed, it's a second boolean or a
  small follow-up, not a redesign of this one.
- No change to the certification pipeline itself, its 11 checks, or tier
  computation. A private plugin can land at any tier, same as today.

## Data model

One new column, migration 12 (the current highest, as of this spec, is 11 —
the `auto_sync_releases` column added earlier today; confirm this is still
correct when the plan is written, in case anything lands in between):

```sql
-- 12 up
ALTER TABLE plugins ADD COLUMN is_private BOOLEAN NOT NULL DEFAULT false;

-- 12 down
ALTER TABLE plugins DROP COLUMN is_private;
```

`Model::Plugin`'s `_columns` gains `is_private`.

## Where visibility is actually enforced

Exactly two existing query paths need one added clause each — both already
identified by reading the current code, not guessed:

**`Model::Plugin::_compatible_where_and_binds`** (`lib/KohaPluginStore/Model/Plugin.pm:135-157`)
is the single shared WHERE-clause builder behind both `search_compatible`
and `count_compatible`, which in turn back *both* the homepage catalogue
(`Controller::Plugins::index`) and the public discovery API
(`Controller::Plugins::list_all`, i.e. `/api/plugins` — the endpoint the
Koha-side Vue client calls). Adding one unconditional clause here covers
both surfaces in one place, with no new argument needed (nothing calling
this method today, or that this design adds, ever wants private plugins
included):

```perl
sub _compatible_where_and_binds {
    my ( $self, $args ) = @_;

    my @clauses = ( "v.status = 'published'", 'p.is_private = false' );
    my @binds;
    # ...unchanged from here down
```

**`Model::Plugin::search_by_author_slug`** (`lib/KohaPluginStore/Model/Plugin.pm:109-124`),
backing the public `/authors/:slug` page, gets the same clause added to its
`WHERE`:

```perl
WHERE v.status = 'published' AND p.is_private = false AND p.author IS NOT NULL AND p.author != ''
```

Nothing else changes. The plugin's own page (`GET /plugins/:slug`,
`GET /plugins/:slug/v/:tag_name`), the `.kpz` download itself, and
`GET /api/plugins/verify?digest=` are untouched — all three already work
by direct lookup (slug or digest), never by listing, so a private plugin
is reachable through every one of them exactly as a public plugin is
today. This is what makes "send the customer a URL" work with zero new
authentication code anywhere.

## Setting and displaying the flag

**At submission time:** a checkbox, "Keep this plugin private — don't list
it publicly," added to the single-plugin new-plugin flow
(`templates/new-plugin-step2.html.ep`'s form, posted to
`POST /new-plugin-confirm`; `Controller::Plugins::new_plugin_confirm`
reads it and sets `is_private` on the `plugins` row it creates). The bulk
import flow (`/new-plugin/bulk`) does not get this checkbox — it's built
for onboarding a whole existing public catalogue at once, not the kind of
one-off bespoke submission this feature targets. A plugin created via bulk
import defaults to public and can be flipped private afterward from its
manage page, same as any other plugin.

**Afterward:** the same maintainer-parity toggle pattern already
established for `auto_sync_releases` — any maintainer (owner or
co-maintainer) can flip it from the manage page
(`templates/plugins/manage.html.ep`), via its own small POST route/action,
not folded into `update_plugin`'s all-fields-required validation loop.
`is_private` carries no repo-hijack-style risk the way `repo_url` does, so
there's no reason to restrict it to the true owner.

**Display:** `templates/partial/table/plugins.html.ep` (used only by
`/my-plugins` — confirmed by checking every template that includes it, so
this change cannot leak onto any public listing) gets a small "Private"
badge next to a plugin's name when `$plugin->is_private` is true.

## Testing

- `t/model_plugin.t`: `is_private` defaults to false, round-trips via
  `update`/a fresh `find` re-fetch (matching this codebase's established
  pattern for boolean-column persistence tests).
- `t/plugins_show.t` or a new focused test: a private, published plugin
  with a compatible version is excluded from `search_compatible`/
  `count_compatible` results, but its own `/plugins/:slug` page still
  returns 200 for an anonymous visitor.
- A new or existing site test: a private plugin with an author set is
  excluded from `search_by_author_slug`'s results (the author page 404s if
  that was their only plugin, or simply omits it if they have other public
  ones).
- `t/plugins_new_plugin.t`: submitting with the private checkbox checked
  creates a plugin with `is_private = true`.
- `t/plugins_manage.t`: a co-maintainer (not just the owner) can toggle
  `is_private` from the manage page.
- `t/site.t`/`t/site_author.t` or equivalent: `/api/plugins` and
  `/authors/:slug` never include a private plugin, even when a `q` search
  term would otherwise match its name.

## Open risk, acknowledged

This relies on the plugin's slug being unguessable enough not to matter —
slugs are derived from the plugin's name (`slugify`), not random, so a
private plugin named something predictable (e.g. `telford-erp`) is
discoverable by a determined guesser trying slugs directly, same as an
"unlisted" YouTube video's ID being brute-forceable in principle. This
matches the access model you explicitly chose (unlisted, not truly
access-controlled) — acceptable given the actual threat model here is
"don't clutter the public catalogue for the general public," not "prevent
a targeted attacker from ever finding it." If that threat model changes,
that's the Non-goals section's deferred access-control feature, not a
defect in this one.
