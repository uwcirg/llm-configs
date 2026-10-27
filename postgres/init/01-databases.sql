-- Runs from /docker-entrypoint-initdb.d on an empty data volume only.
-- The superuser (POSTGRES_USER, default postgres) owns these databases.
-- A keycloak database can be added here in a later iteration:
-- CREATE DATABASE keycloak;

CREATE DATABASE litellm;
CREATE DATABASE openwebui;
