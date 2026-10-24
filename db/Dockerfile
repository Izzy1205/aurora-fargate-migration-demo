# Flyway image, run as a one-off ECS task in the VPC. FLYWAY_URL comes from
# the task definition, FLYWAY_USER and FLYWAY_PASSWORD are injected by ECS
# from Secrets Manager.
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
 && rm -rf /flyway/drivers/couchbase \
      /flyway/drivers/databricks-jdbc-*.jar \
      /flyway/drivers/mssql-jdbc-*.jar \
      /flyway/lib/flyway/flyway-database-nc-couchbase-*.jar \
      /flyway/lib/flyway/flyway-database-databricks-*.jar \
      /flyway/lib/flyway/flyway-sqlserver-*.jar \
 && ls /flyway/drivers/postgresql-*.jar

RUN addgroup -S migrate && adduser -S -G migrate -h /home/migrate migrate

# Owned by root so the runtime user can read but not change them.
COPY migrations/ /flyway/sql/

USER migrate

# Base image ENTRYPOINT is "flyway"; the task definition passes "migrate".
CMD ["info"]
