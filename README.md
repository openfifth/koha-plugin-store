# WIP koha-plugin-store

Koha plugin store project consisting of 2 distinct components:

- Backend
- Client

## Backend

- Mojolicious app (Perl)
- Koha plugins database

- Features:
  - Restricted access UI for review process of new plugin submissions
  - Authorized community members can access and review plugins
  - Provides REST API to be consumed by core Koha
  - Automatically manage latest version releases for each plugin

Every submitted plugin version runs through an 11-check automated
certification pipeline before it can publish, and published versions are
signed by the store — see [docs/CERTIFICATION.md](docs/CERTIFICATION.md).

### Quick start (Docker)

```bash
cp koha_plugin_store.conf.docker.example koha_plugin_store.conf
docker compose up -d --build
docker compose exec app script/koha_plugin_store migrate
```

Visit <http://127.0.0.1:3000>. See [DEVELOPMENT.md](DEVELOPMENT.md) for the
full dev setup, including host-only dev, testing GitHub OAuth login, and
common pitfalls.

## Client

- VueJS App
- Relevant repo/branch [here](https://github.com/PTFS-Europe/koha/tree/plugin_store)
- Interacts with backend using the REST API

- Features:
  - Provides UI for searching and installing plugins
  - Enables updating an installed plugin if installed version is out of date

### New submission diagram

![new submission](https://github.com/ammopt/koha-plugin-store/blob/main/new-submission.jpg?raw=true)

### New version release diagram

![new version release](https://github.com/ammopt/koha-plugin-store/blob/main/new-version-release.jpg?raw=true)

## Documentation

- [DEVELOPMENT.md](DEVELOPMENT.md) — local dev setup (Docker and host), testing GitHub OAuth login
- [DEPLOYMENT.md](DEPLOYMENT.md) — running the store in production
- [docs/CERTIFICATION.md](docs/CERTIFICATION.md) — the automated check pipeline and publish signing
- [CONTRIBUTING.md](CONTRIBUTING.md) — workflow, testing, code conventions
