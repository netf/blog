-- DuckDB 2.0.1, iceberg extension f979b5b28a. No refresh during a statement or transaction:
-- each new transaction re-loads the table (and gets new credentials), so split long work into
-- statements that each finish inside the TTL, or run it on an engine that refreshes.
-- Writing needs TABLE_CREATE on the namespace (Polaris authorizes /transactions/commit with it).
INSTALL iceberg; LOAD iceberg; LOAD httpfs;
CREATE SECRET pol (TYPE iceberg, CLIENT_ID '<client_id>', CLIENT_SECRET '<client_secret>',
  OAUTH2_SERVER_URI 'http://polaris:8181/api/catalog/v1/oauth/tokens', OAUTH2_SCOPE 'PRINCIPAL_ROLE:ALL');
ATTACH 'lake_c' AS lake (TYPE iceberg, ENDPOINT 'http://polaris:8181/api/catalog', SECRET pol,
  ACCESS_DELEGATION_MODE 'vended_credentials');
