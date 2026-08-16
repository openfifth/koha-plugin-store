# Contributing

Thanks for contributing to koha-plugin-store. See
[DEVELOPMENT.md](DEVELOPMENT.md) for getting a local instance running before
you start.

## Workflow

1. Branch off `main`.
2. For anything beyond a small, obvious fix, write a short design doc first
   under `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` describing the
   architecture, data flow, and testing approach — this repo's history is
   full of these (see existing files under `docs/superpowers/specs/` and
   `docs/superpowers/plans/`) and reviewers expect one for anything that adds
   a table, endpoint, or background job.
3. Open a pull request against `main`.

## Testing

Run the test suite before opening a PR:

```bash
prove -l t/
```

or, inside the Docker dev setup:

```bash
docker compose exec app prove -l t/
```

Add or extend tests under `t/` for any behavioural change — new checks in
`lib/KohaPluginStore/Check/`, new endpoints, new Minion tasks. See
[docs/CERTIFICATION.md](docs/CERTIFICATION.md) if your change touches the
automated check pipeline that submitted plugins run through — that's a
different thing from testing this app's own code, but the two are easy to
conflate since both live under `t/` and `lib/KohaPluginStore/Check/`.

`t/login.t` is stale (marked `#TODO: Redo this, its out of date` in the file
itself) and tests a login flow that predates the current GitHub OAuth login —
don't treat its failures as a regression you introduced.

## Code conventions

- Perl: standard Mojolicious controller/model conventions — see `CLAUDE.md`
  for an architecture overview (request flow, data layer, submission
  workflow, check pipeline) before making non-trivial changes.
- Templates: server-rendered `.html.ep` under `templates/`, Bootstrap-based.
  No frontend build step for this half of the project.
- If your change touches a `.tt`/`.html.ep` template, keep in mind the
  `translatable_templates` and `plugin_template_wrapper` checks documented in
  [docs/CERTIFICATION.md](docs/CERTIFICATION.md) — those apply to submitted
  *plugins*, not to this app's own templates, but the same habits (translation
  markers on visible text) are good practice here too.

## Reporting issues

Open a GitHub issue against this repo describing the problem or proposal. For
security-sensitive findings (auth, signing, the sandboxed check pipeline),
please reach out privately rather than filing a public issue.
