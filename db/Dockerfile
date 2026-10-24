# Flyway migration image. Runs as a one-off ECS task inside the VPC.
# Connection settings come from the task definition:
#   FLYWAY_URL                     plain environment variable
#   FLYWAY_USER, FLYWAY_PASSWORD   injected by ECS from Secrets Manager
# Hardening: pin by digest (flyway/flyway:13.11.1-alpine@sha256:...).
FROM flyway/flyway:13.11.1-alpine

ENV FLYWAY_LOCATIONS=filesystem:/flyway/sql \
    FLYWAY_CLEAN_DISABLED=true \
    REDGATE_DISABLE_TELEMETRY=true

# The base image ships JDBC drivers for about 20 databases. Most of its CVEs
# live in three drivers this image never uses (Databricks, Couchbase, SQL
# Server), so drop those along with the Flyway plugins that load them. A
# plugin left behind without its driver crashes Flyway at startup. Also pull
# in any Alpine security fixes newer than the base image.
RUN apk upgrade --no-cache \
 && rm -rf /flyway/drivers/couchbase \
      /flyway/drivers/databricks-jdbc-*.jar \
      /flyway/drivers/mssql-jdbc-*.jar \
      /flyway/lib/flyway/flyway-database-nc-couchbase-*.jar \
      /flyway/lib/flyway/flyway-database-databricks-*.jar \
      /flyway/lib/flyway/flyway-sqlserver-*.jar \
 && ls /flyway/drivers/postgresql-*.jar

RUN addgroup -S migrate && adduser -S -G migrate -h /home/migrate migrate

# Owned by root, readable by the runtime user, not writable by it.
COPY migrations/ /flyway/sql/

USER migrate

# Base image ENTRYPOINT is "flyway"; the task definition passes "migrate".
CMD ["info"]
