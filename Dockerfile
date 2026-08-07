FROM perl:5.36-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY cpanfile ./
RUN cpanm --installdeps --notest .

COPY . .

EXPOSE 3000

CMD ["morbo", "--listen", "http://*:3000", "script/koha_plugin_store"]
