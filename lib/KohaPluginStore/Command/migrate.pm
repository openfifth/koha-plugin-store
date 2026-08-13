package KohaPluginStore::Command::migrate;
use Mojo::Base 'Mojolicious::Command', -signatures;

has description => 'Apply Postgres migrations';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $pg = $self->app->pg;
    $pg->migrations->from_data(__PACKAGE__)->migrate;

    say 'Migrated to version ' . $pg->migrations->latest;
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::migrate - Apply Postgres migrations

=head1 SYNOPSIS

  Usage: APPLICATION migrate

=cut

__DATA__

@@ migrations
-- 1 up
CREATE TABLE users (
    id       SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email    TEXT UNIQUE NOT NULL
);

CREATE TABLE plugins (
    id          SERIAL PRIMARY KEY,
    repo_url    TEXT UNIQUE,
    name        TEXT UNIQUE,
    class_name  TEXT UNIQUE,
    description TEXT,
    author      TEXT,
    thumbnail   TEXT,
    user_id     INTEGER REFERENCES users(id) ON DELETE CASCADE,
    "timestamp" TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE plugin_versions (
    id               SERIAL PRIMARY KEY,
    plugin_id        INTEGER REFERENCES plugins(id) ON DELETE CASCADE,
    name             TEXT,
    tag_name         TEXT,
    version          TEXT,
    koha_min_version TEXT,
    kpz_url          TEXT,
    date_released    TIMESTAMPTZ
);

-- 1 down
DROP TABLE plugin_versions;
DROP TABLE plugins;
DROP TABLE users;

-- 2 up
CREATE TABLE developers (
    id                 SERIAL PRIMARY KEY,
    oauth_provider_key TEXT NOT NULL,
    provider_user_id   TEXT NOT NULL,
    username           TEXT NOT NULL,
    avatar_url         TEXT,
    created_at         TIMESTAMPTZ DEFAULT now(),
    UNIQUE (oauth_provider_key, provider_user_id)
);

ALTER TABLE plugins DROP COLUMN user_id;
ALTER TABLE plugins ADD COLUMN developer_id INTEGER REFERENCES developers(id) ON DELETE CASCADE;

DROP TABLE users;

-- 2 down
CREATE TABLE users (
    id       SERIAL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    email    TEXT UNIQUE NOT NULL
);

ALTER TABLE plugins DROP COLUMN developer_id;
ALTER TABLE plugins ADD COLUMN user_id INTEGER REFERENCES users(id) ON DELETE CASCADE;

DROP TABLE developers;

-- 3 up
ALTER TABLE developers ADD COLUMN cached_repos JSONB;
ALTER TABLE developers ADD COLUMN cached_repos_fetched_at TIMESTAMPTZ;

-- 3 down
ALTER TABLE developers DROP COLUMN cached_repos_fetched_at;
ALTER TABLE developers DROP COLUMN cached_repos;

-- 4 up
ALTER TABLE plugins ADD COLUMN slug TEXT UNIQUE;
ALTER TABLE plugins ADD COLUMN documentation_url TEXT;

ALTER TABLE plugin_versions ADD COLUMN status TEXT NOT NULL DEFAULT 'submitted';
ALTER TABLE plugin_versions ADD COLUMN error_message TEXT;
ALTER TABLE plugin_versions ADD COLUMN content_digest TEXT;
ALTER TABLE plugin_versions ADD COLUMN author_username TEXT;
ALTER TABLE plugin_versions ADD COLUMN author_avatar_url TEXT;
ALTER TABLE plugin_versions ADD CONSTRAINT plugin_versions_plugin_id_tag_name_key
    UNIQUE (plugin_id, tag_name);

CREATE TABLE plugin_contributors (
    id                  SERIAL PRIMARY KEY,
    plugin_id           INTEGER REFERENCES plugins(id) ON DELETE CASCADE,
    github_username     TEXT NOT NULL,
    avatar_url          TEXT,
    contributions_count INTEGER,
    fetched_at          TIMESTAMPTZ DEFAULT now(),
    UNIQUE (plugin_id, github_username)
);

-- 4 down
DROP TABLE plugin_contributors;

ALTER TABLE plugin_versions DROP CONSTRAINT plugin_versions_plugin_id_tag_name_key;
ALTER TABLE plugin_versions DROP COLUMN author_avatar_url;
ALTER TABLE plugin_versions DROP COLUMN author_username;
ALTER TABLE plugin_versions DROP COLUMN content_digest;
ALTER TABLE plugin_versions DROP COLUMN error_message;
ALTER TABLE plugin_versions DROP COLUMN status;

ALTER TABLE plugins DROP COLUMN documentation_url;
ALTER TABLE plugins DROP COLUMN slug;

-- 5 up
ALTER TABLE plugin_versions ADD COLUMN certification_tier TEXT;

CREATE TABLE review_checks (
    id                SERIAL PRIMARY KEY,
    plugin_version_id INTEGER REFERENCES plugin_versions(id) ON DELETE CASCADE,
    check_name        TEXT NOT NULL,
    required          BOOLEAN NOT NULL,
    passed            BOOLEAN NOT NULL,
    message           TEXT,
    checked_at        TIMESTAMPTZ DEFAULT now(),
    UNIQUE (plugin_version_id, check_name)
);

-- 5 down
DROP TABLE review_checks;
ALTER TABLE plugin_versions DROP COLUMN certification_tier;

-- 6 up
ALTER TABLE plugin_versions ADD COLUMN signed_manifest TEXT;
ALTER TABLE plugin_versions ADD COLUMN signature TEXT;

-- 6 down
ALTER TABLE plugin_versions DROP COLUMN signed_manifest;
ALTER TABLE plugin_versions DROP COLUMN signature;
