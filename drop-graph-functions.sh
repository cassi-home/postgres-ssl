#!/bin/bash

psql "$PGCONNSTRING" -v ON_ERROR_STOP=1 <<'SQL'

-- Drop functions if they exist
DROP FUNCTION IF EXISTS test_create_graph(TEXT);
DROP FUNCTION IF EXISTS test_create_node(TEXT, VARCHAR, VARCHAR, JSONB);
DROP FUNCTION IF EXISTS test_create_relation(TEXT, INTEGER, INTEGER, VARCHAR, JSONB);

SQL 