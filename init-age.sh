psql -v ON_ERROR_STOP=1 \
     --username postgres \
     --dbname graphdb <<'SQL'
CREATE SCHEMA IF NOT EXISTS ag_catalog;
CREATE EXTENSION IF NOT EXISTS age WITH SCHEMA ag_catalog;
ALTER DATABASE graphdb SET search_path = ag_catalog,public;
LOAD 'age';
SELECT ag_catalog.create_graph('test');
SQL