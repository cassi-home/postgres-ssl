#!/bin/bash

# Source the .env file if it exists
if [ -f .env ]; then
    source .env
fi

# Check if PGCONNSTRING is set
if [ -z "$PGCONNSTRING" ]; then
    echo "Error: PGCONNSTRING is not set. Please set it in your .env file or environment."
    exit 1
fi

# Run the SQL commands
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
-- Create the graph
SELECT test_create_graph('test_123');

-- First clean the test tables
TRUNCATE TABLE graph_test_123_nodes CASCADE;
TRUNCATE TABLE graph_test_123_edges CASCADE;


-- Create first node
SELECT test_create_node(
    'test_123',
    'test',
    'test_A',
    '{"x": "y"}'::jsonb
);

-- Create second node
SELECT test_create_node(
    'test_123',
    'test',
    'test_B',
    '{"a": "b"}'::jsonb
);

-- Create edge between nodes
SELECT test_create_edge(
    'test_123',
    (SELECT node_id FROM graph_test_123_nodes WHERE node_name = 'test_A' AND valid_to IS NULL),
    (SELECT node_id FROM graph_test_123_nodes WHERE node_name = 'test_B' AND valid_to IS NULL),
    'CONNECTED_TO',
    '{"strength": "high"}'::jsonb
);

-- View all nodes
SELECT * FROM graph_test_123_nodes
ORDER BY node_id;

-- View all edges
SELECT * FROM graph_test_123_edges
ORDER BY id;

-- Test the test_open_nodes function
SELECT * FROM test_open_nodes('test_123', ARRAY['test_A', 'test_B']);

-- Test the test_search_nodes function
SELECT * FROM test_search_nodes('test_123', 'y');

-- Test the test_search_edges function
SELECT * FROM test_search_edges('test_123', 'high');

-- Test the test_read_graph function
SELECT * FROM test_read_graph('test_123');

-- Create an additional edge to test more complex queries
SELECT test_create_edge(
    'test_123',
    (SELECT node_id FROM graph_test_123_nodes WHERE node_name = 'test_B' AND valid_to IS NULL),
    (SELECT node_id FROM graph_test_123_nodes WHERE node_name = 'test_A' AND valid_to IS NULL),
    'DEPENDS_ON',
    '{"priority": "medium"}'::jsonb
);

-- Test read_graph again with the additional edge
SELECT * FROM test_read_graph('test_123');

-- Exit psql properly
\q
EOF 

