FROM perl:5.36-slim

# No docker.io here, deliberately: the perl_syntax check's sandboxed
# compile-check now runs in a separate syntax-sandbox broker service (see
# sandbox_broker/), which is the only container in the stack with a docker
# CLI or Docker socket access. This image (used by both app and worker)
# never touches Docker at all. No nodejs/npm/yarn either -- those were only
# ever needed to build Koha::QA's share/ assets back when it had to be
# installed from git into a project-local lib; it's a normal CPAN
# distribution now (see the cpanfile comment), needing nothing beyond a
# plain `cpanm --installdeps`.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    libssl-dev \
    zlib1g-dev \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY cpanfile ./
RUN cpanm --notest --installdeps .

COPY . .

EXPOSE 3000

CMD ["morbo", "--listen", "http://*:3000", "script/koha_plugin_store"]
