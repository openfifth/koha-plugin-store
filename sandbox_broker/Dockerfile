FROM perl:5.36-slim

# Only git (to clone Koha release tags) and the docker CLI (to talk to the
# host's socket, mounted in by docker-compose.yml -- this is Docker-outside-
# of-Docker, nothing here ever starts a dockerd of its own) -- deliberately
# nothing else. This is the only container in the stack with access to the
# host's Docker socket, so its image is kept as small and auditable as
# possible: no build toolchain, no Node/yarn, no Postgres client, no access
# to the main app's config, DB, GitHub token, or signing key.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY cpanfile ./
RUN cpanm --notest --installdeps .

COPY . .

CMD ["perl", "script/sandbox_broker", "daemon", "-l", "http+unix://%2Frun%2Fbroker%2Fbroker.sock"]
