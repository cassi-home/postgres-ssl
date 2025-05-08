#!/bin/bash

psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<'SQL'
-- Create the graph
SELECT create_graph('test_123');

-- Create first node
SELECT create_node(
    'test_123',
    'test',
    'test_A',
    '{"x": "y"}'::jsonb
);

-- Create second node
SELECT create_node(
    'test_123',
    'test',
    'test_B',
    '{"a": "b"}'::jsonb
);

-- Create relation between nodes
SELECT create_relation(
    'test_123',
    (SELECT entity_id FROM graph_test_123_nodes WHERE entity_name = 'test_A' AND valid_to IS NULL),
    (SELECT entity_id FROM graph_test_123_nodes WHERE entity_name = 'test_B' AND valid_to IS NULL),
    'CONNECTED_TO',
    '{"strength": "high"}'::jsonb
);

-- View all nodes
SELECT 
    entity_id,
    entity_type,
    entity_name,
    version,
    properties,
    valid_from,
    valid_to
FROM graph_test_123_nodes
ORDER BY entity_id;

-- View all relations
SELECT 
    id,
    source,
    target,
    relation_type,
    version,
    properties,
    valid_from,
    valid_to
FROM graph_test_123_relations
ORDER BY id;
SQL 