# WIP koha-plugin-store

Koha plugin store project consisting of 2 distinct components:
- Backend
- Client

# Backend
- Mojolicious app (Perl)
- Koha plugins database

- Features:
  - Restricted access UI for review process of new plugin submissions
  - Authorized community members can access and review plugins
  - Provides REST API to be consumed by core Koha
  - Automatically manage latest version releases for each plugin

- Notes
  - A `koha_plugin_store.conf` file is required. Follow the example from `koha_plugin_store.conf.example`
  - The `kpz_packages` directory is used to store `.kpz` files download from github.
  - To install cpan dependencies, run `cpanm --installdeps . ` at the project root dir.
  - To init database for development run `perl lib/MyApp/Command/init_db.pl` at the project root dir.

# Client
- VueJS App
- Relevant repo/branch [here](https://github.com/PTFS-Europe/koha/tree/plugin_store)
- Interacts with backend using the REST API

- Features:
  - Provides UI for searching and installing plugins
  - Enables updating an installed plugin if installed version is out of date

## New submission diagram
![new submission](https://github.com/ammopt/koha-plugin-store/blob/main/new-submission.jpg?raw=true)

## New version release diagram
![new version release](https://github.com/ammopt/koha-plugin-store/blob/main/new-version-release.jpg?raw=true)

## Launch server
- morbo script/koha_plugin_store
