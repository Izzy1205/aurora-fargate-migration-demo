# Flyway image, run as a one-off ECS task. Also runs db-logins.sh, which needs psql.
# TODO: pin by digest.
FROM flyway/flyway:13.11.1-alpine

ENV FLYWAY_LOCATIONS=filesystem:/flyway/sql \
    FLYWAY_CLEAN_DISABLED=true \
    REDGATE_DISABLE_TELEMETRY=true

# Drop JDBC drivers we don't use (most of the CVEs) and their plugins, or Flyway crashes.
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

# Guava swap for CVE-2026-102554. Flyway 13.11.1 still bundles 33.5.0.
# Remove once Flyway ships Guava 33.7.2+.
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

RUN addgroup -S migrate && adduser -S -G migrate -h /home/migrate migrate

# Root-owned so the runtime user can't change them.
COPY migrations/ /flyway/sql/
COPY logins/ /flyway/logins/

USER migrate

# Task definition passes "migrate".
CMD ["info"]
