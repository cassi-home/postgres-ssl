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

psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<'SQL'

-- Drop existing functions to avoid conflicts
DROP FUNCTION IF EXISTS create_ontology_edge(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR);
DROP FUNCTION IF EXISTS update_ontology_edge(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR);
DROP FUNCTION IF EXISTS delete_ontology_edge(VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS get_ontology_edge(VARCHAR, VARCHAR, VARCHAR);
DROP FUNCTION IF EXISTS list_ontology_edges();
DROP FUNCTION IF EXISTS get_ontology_edge_history(VARCHAR, VARCHAR, VARCHAR);

-- Create sequence for version tracking
CREATE SEQUENCE IF NOT EXISTS ontology_version_seq;

-- Create the node_ontology table if it doesn't exist
CREATE TABLE IF NOT EXISTS node_ontology (
    id SERIAL PRIMARY KEY,
    source VARCHAR NOT NULL,
    edge_type VARCHAR NOT NULL,
    target VARCHAR NOT NULL,
    source_column_match VARCHAR,
    target_column_match VARCHAR,
    create_missing_target_node BOOLEAN DEFAULT FALSE,
    valid_from TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    valid_to TIMESTAMP DEFAULT NULL,
    version INTEGER DEFAULT 0,
    valid_from_version INTEGER,
    valid_to_version INTEGER,
    modifying_user VARCHAR,
    UNIQUE(source, edge_type, target, valid_to)
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS node_ontology_source_idx ON node_ontology (source);
CREATE INDEX IF NOT EXISTS node_ontology_edge_type_idx ON node_ontology (edge_type);
CREATE INDEX IF NOT EXISTS node_ontology_target_idx ON node_ontology (target);
CREATE INDEX IF NOT EXISTS node_ontology_valid_to_idx ON node_ontology (valid_to);

-- Function to create a new ontology edge
CREATE OR REPLACE FUNCTION create_ontology_edge(
    p_source VARCHAR,
    p_edge_type VARCHAR,
    p_target VARCHAR,
    p_source_column_match VARCHAR,
    p_target_column_match VARCHAR,
    p_create_missing_target_node BOOLEAN,
    p_modifying_user VARCHAR
) RETURNS INTEGER AS $$
DECLARE
    v_id INTEGER;
    v_version INTEGER;
BEGIN
    -- Check if edge already exists with same column matches
    SELECT version INTO v_version
    FROM node_ontology
    WHERE source = p_source
    AND edge_type = p_edge_type
    AND target = p_target
    AND COALESCE(source_column_match, '') = COALESCE(p_source_column_match, '')
    AND COALESCE(target_column_match, '') = COALESCE(p_target_column_match, '')
    AND valid_to IS NULL;

    IF v_version IS NOT NULL THEN
        RAISE EXCEPTION 'Edge from % to % with type % and column matches already exists', p_source, p_target, p_edge_type;
    END IF;

    -- Check if edge exists with different column matches
    SELECT version INTO v_version
    FROM node_ontology
    WHERE source = p_source
    AND edge_type = p_edge_type
    AND target = p_target
    AND valid_to IS NULL;

    IF v_version IS NOT NULL THEN
        -- Update existing edge with new column matches
        UPDATE node_ontology
        SET valid_to = CURRENT_TIMESTAMP,
            valid_to_version = nextval('ontology_version_seq')
        WHERE source = p_source
        AND edge_type = p_edge_type
        AND target = p_target
        AND valid_to IS NULL;

        -- Insert new version with updated column matches
        INSERT INTO node_ontology (
            source,
            edge_type,
            target,
            source_column_match,
            target_column_match,
            create_missing_target_node,
            version,
            valid_from_version,
            modifying_user
        ) VALUES (
            p_source,
            p_edge_type,
            p_target,
            p_source_column_match,
            p_target_column_match,
            p_create_missing_target_node,
            v_version + 1,
            nextval('ontology_version_seq'),
            p_modifying_user
        ) RETURNING id INTO v_id;

        RETURN v_id;
    END IF;

    -- Insert new edge
    INSERT INTO node_ontology (
        source,
        edge_type,
        target,
        source_column_match,
        target_column_match,
        create_missing_target_node,
        version,
        valid_from_version,
        modifying_user
    ) VALUES (
        p_source,
        p_edge_type,
        p_target,
        p_source_column_match,
        p_target_column_match,
        p_create_missing_target_node,
        0,
        nextval('ontology_version_seq'),
        p_modifying_user
    ) RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Function to update an existing ontology edge
CREATE OR REPLACE FUNCTION update_ontology_edge(
    p_source VARCHAR,
    p_edge_type VARCHAR,
    p_target VARCHAR,
    p_source_column_match VARCHAR,
    p_target_column_match VARCHAR,
    p_create_missing_target_node BOOLEAN,
    p_modifying_user VARCHAR
) RETURNS INTEGER AS $$
DECLARE
    v_id INTEGER;
    v_old_version INTEGER;
    v_new_version INTEGER;
BEGIN
    -- Get current version
    SELECT version INTO v_old_version
    FROM node_ontology
    WHERE source = p_source
    AND edge_type = p_edge_type
    AND target = p_target
    AND valid_to IS NULL;

    IF v_old_version IS NULL THEN
        RAISE EXCEPTION 'Edge from % to % with type % does not exist', p_source, p_target, p_edge_type;
    END IF;

    -- Set valid_to for current version
    UPDATE node_ontology
    SET valid_to = CURRENT_TIMESTAMP,
        valid_to_version = nextval('ontology_version_seq')
    WHERE source = p_source
    AND edge_type = p_edge_type
    AND target = p_target
    AND valid_to IS NULL;

    -- Insert new version
    INSERT INTO node_ontology (
        source,
        edge_type,
        target,
        source_column_match,
        target_column_match,
        create_missing_target_node,
        version,
        valid_from_version,
        modifying_user
    ) VALUES (
        p_source,
        p_edge_type,
        p_target,
        p_source_column_match,
        p_target_column_match,
        p_create_missing_target_node,
        v_old_version + 1,
        nextval('ontology_version_seq'),
        p_modifying_user
    ) RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Function to delete an ontology edge
CREATE OR REPLACE FUNCTION delete_ontology_edge(
    p_source VARCHAR,
    p_edge_type VARCHAR,
    p_target VARCHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_version INTEGER;
BEGIN
    -- Get current version
    SELECT version INTO v_version
    FROM node_ontology
    WHERE source = p_source
    AND edge_type = p_edge_type
    AND target = p_target
    AND valid_to IS NULL;

    IF v_version IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Set valid_to for current version
    UPDATE node_ontology
    SET valid_to = CURRENT_TIMESTAMP,
        valid_to_version = nextval('ontology_version_seq')
    WHERE source = p_source
    AND edge_type = p_edge_type
    AND target = p_target
    AND valid_to IS NULL;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Function to get current version of an ontology edge
CREATE OR REPLACE FUNCTION get_ontology_edge(
    p_source VARCHAR,
    p_edge_type VARCHAR,
    p_target VARCHAR
) RETURNS TABLE (
    id INTEGER,
    source VARCHAR,
    edge_type VARCHAR,
    target VARCHAR,
    source_column_match VARCHAR,
    target_column_match VARCHAR,
    create_missing_target_node BOOLEAN,
    version INTEGER,
    valid_from TIMESTAMP,
    modifying_user VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id,
        t.source,
        t.edge_type,
        t.target,
        t.source_column_match,
        t.target_column_match,
        t.create_missing_target_node,
        t.version,
        t.valid_from,
        t.modifying_user
    FROM node_ontology t
    WHERE t.source = p_source
    AND t.edge_type = p_edge_type
    AND t.target = p_target
    AND t.valid_to IS NULL;
END;
$$ LANGUAGE plpgsql;

-- Function to list all current ontology edges
CREATE OR REPLACE FUNCTION list_ontology_edges()
RETURNS TABLE (
    id INTEGER,
    source VARCHAR,
    edge_type VARCHAR,
    target VARCHAR,
    source_column_match VARCHAR,
    target_column_match VARCHAR,
    create_missing_target_node BOOLEAN,
    version INTEGER,
    valid_from TIMESTAMP,
    modifying_user VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id,
        t.source,
        t.edge_type,
        t.target,
        t.source_column_match,
        t.target_column_match,
        t.create_missing_target_node,
        t.version,
        t.valid_from,
        t.modifying_user
    FROM node_ontology t
    WHERE t.valid_to IS NULL
    ORDER BY t.source, t.edge_type, t.target;
END;
$$ LANGUAGE plpgsql;

-- Function to get version history of an ontology edge
CREATE OR REPLACE FUNCTION get_ontology_edge_history(
    p_source VARCHAR,
    p_edge_type VARCHAR,
    p_target VARCHAR
) RETURNS TABLE (
    id INTEGER,
    source VARCHAR,
    edge_type VARCHAR,
    target VARCHAR,
    source_column_match VARCHAR,
    target_column_match VARCHAR,
    create_missing_target_node BOOLEAN,
    version INTEGER,
    valid_from TIMESTAMP,
    valid_to TIMESTAMP,
    valid_from_version INTEGER,
    valid_to_version INTEGER,
    modifying_user VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id,
        t.source,
        t.edge_type,
        t.target,
        t.source_column_match,
        t.target_column_match,
        t.create_missing_target_node,
        t.version,
        t.valid_from,
        t.valid_to,
        t.valid_from_version,
        t.valid_to_version,
        t.modifying_user
    FROM node_ontology t
    WHERE t.source = p_source
    AND t.edge_type = p_edge_type
    AND t.target = p_target
    ORDER BY t.valid_from_version;
END;
$$ LANGUAGE plpgsql;

SQL 