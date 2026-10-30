# Flyway image, run as a one-off ECS task in the VPC. FLYWAY_URL comes from
# the task definition, FLYWAY_USER and FLYWAY_PASSWORD are injected by ECS
# from the Flyway login secret in Secrets Manager.
#
# The same image also runs db/logins/db-logins.sh (a different entrypoint in
# the db-logins task definition), which needs psql.
# TODO: pin by digest (flyway/flyway:13.11.1-alpine@sha256:...).
FROM flyway/flyway:13.11.1-alpine

ENV FLYWAY_LOCATIONS=filesystem:/flyway/sql \
    FLYWAY_CLEAN_DISABLED=true \
    REDGATE_DISABLE_TELEMETRY=true

# The base image ships JDBC drivers for ~20 databases. Most of its CVEs are
# in three we never use (Databricks, Couchbase, SQL Server), so delete those
# and their Flyway plugins too. A plugin without its driver crashes Flyway at
# startup. apk upgrade picks up Alpine fixes newer than the base image.
RUN apk upgrade --no-cache \
 && apk add --no-cache postgresql-client \
 && rm -rf /flyway/drivers/couchbase \
      /flyway/drivers/databricks-jdbc-*.jar \
      /flyway/drivers/mssql-jdbc-*.jar \
      /flyway/lib/flyway/flyway-database-nc-couchbase-*.jar \
      /flyway/lib/flyway/flyway-database-databricks-*.jar \
      /flyway/lib/flyway/flyway-sqlserver-*.jar \
 && ls /flyway/drivers/postgresql-*.jar \
 && psql --version

# Guava swap (CVE-2026-102554, High, denial of service).
# Flyway 13.11.1 is the newest release and still bundles Guava 33.5.0, which
# our Trivy gate blocks. The fix is in Guava 33.7.2, so we replace the jar
# ourselves: delete the bundled copy, download 33.7.2 from Maven Central, and
# check its SHA-256 before using it. Guava keeps its API stable across minor
# versions, and the "flyway against throwaway Postgres" PR check proves
# Flyway still runs with it.
# Remove this block once a Flyway release ships Guava 33.7.2 or newer.
ARG GUAVA_VERSION=33.7.2-jre
ARG GUAVA_SHA256=b530942257fb935f8b2cfaa5f8eb5bd59c555fd8e8d01b8ce98912e077ea606c
RUN set -eu \
 && old="$(find /flyway -name 'guava-*.jar')" \
 && test -n "$old" \
 && dir="$(dirname "$(echo "$old" | head -n 1)")" \
 && rm -f $old \
 && wget -q -O "$dir/guava-${GUAVA_VERSION}.jar" \
      "https://repo1.maven.org/maven2/com/google/guava/guava/${GUAVA_VERSION}/guava-${GUAVA_VERSION}.jar" \
 && echo "${GUAVA_SHA256}  $dir/guava-${GUAVA_VERSION}.jar" | sha256sum -c - \
 && find /flyway -name 'guava-*.jar'

# OpenTelemetry swap (CVE-2026-118259, Medium).
# Flyway 13.11.1 bundles opentelemetry-api 1.62.0 with its GCP Spanner
# driver in /flyway/drivers/gcp. We never use Spanner, but Trivy scans the
# whole image. The fix is in 1.67.0, so we swap the API jar and the context
# jar it depends on (same version, per its POM), each checked by SHA-256
# from Maven Central, the same way as Guava above.
# Remove this block once a Flyway release ships opentelemetry-api 1.67.0 or
# newer.
ARG OTEL_VERSION=1.67.0
ARG OTEL_API_SHA256=538d1dff2f9a37aecbc0ef98fd17273a3affb058e734e6763a3a07a38a5fdc59
ARG OTEL_CONTEXT_SHA256=40fb813fb5e27ec2691daa29c81b572b5b1541ef9b41e62490c3ee3e6407c55e
RUN set -eu \
 && for pair in "api:${OTEL_API_SHA256}" "context:${OTEL_CONTEXT_SHA256}"; do \
      name="opentelemetry-${pair%%:*}"; sum="${pair#*:}"; \
      old="$(find /flyway -name "${name}-[0-9]*.jar")"; \
      test -n "$old"; \
      dir="$(dirname "$(echo "$old" | head -n 1)")"; \
      rm -f $old; \
      wget -q -O "$dir/${name}-${OTEL_VERSION}.jar" \
        "https://repo1.maven.org/maven2/io/opentelemetry/${name}/${OTEL_VERSION}/${name}-${OTEL_VERSION}.jar"; \
      echo "${sum}  $dir/${name}-${OTEL_VERSION}.jar" | sha256sum -c -; \
    done \
 && find /flyway -name 'opentelemetry-api-*.jar' -o -name 'opentelemetry-context-*.jar'

RUN addgroup -S migrate && adduser -S -G migrate -h /home/migrate migrate

# Owned by root so the runtime user can read but not change them.
COPY migrations/ /flyway/sql/
COPY logins/ /flyway/logins/

USER migrate

# Base image ENTRYPOINT is "flyway"; the task definition passes "migrate".
CMD ["info"]
