FROM postgres:16-alpine

RUN apk add --no-cache \
    aws-cli \
    jq

# Build context: raiz do monorepo
#   docker build -f togglemaster-infra/db-init/Dockerfile .
COPY togglemaster-infra/db-init/entrypoint.sh /usr/local/bin/entrypoint.sh

COPY togglemaster-auth/db/init.sql /sql/auth/init.sql
COPY togglemaster-flag/db/init.sql /sql/flag/init.sql
COPY togglemaster-targeting/db/init.sql /sql/targeting/init.sql

RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
