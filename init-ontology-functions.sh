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
    creation_condition VARCHAR,
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

CREATE OR REPLACE FUNCTION apply_ontology(
    p_residence_id VARCHAR,
    p_id INTEGER
) RETURNS BOOLEAN AS $$
DECLARE
    v_query varchar;
    v_node_type varchar;
    v_edge_type varchar;
    v_creation_condition varchar;
    v_edge_record RECORD;
BEGIN
    -- Loop through ontology rules that match the given node
    FOR v_edge_record IN
        SELECT 
            user_nodes.node_type,
            node_ontology.edge_type,
            node_ontology.creation_condition
        FROM node_ontology
        INNER JOIN user_nodes ON (
            (node_ontology.source = user_nodes.node_type OR node_ontology.target = user_nodes.node_type)
            AND user_nodes.residence_id = p_residence_id
            AND user_nodes.id = p_id
            AND user_nodes.valid_to IS NULL
        )
        WHERE node_ontology.valid_to IS NULL
    LOOP
        v_node_type := v_edge_record.node_type;
        v_creation_condition := v_edge_record.creation_condition;
        v_edge_type := v_edge_record.edge_type;
        
        -- Substitute the placeholder directly
        v_creation_condition := replace(v_creation_condition, '{p_id}', p_id::text);
        
        -- Build the complete query with CTEs
        v_query := format('
            WITH 
                user_nodes AS (SELECT * FROM user_nodes WHERE residence_id = %L AND valid_to IS NULL), 
                user_edges AS (SELECT * FROM user_edges WHERE residence_id = %L AND valid_to IS NULL),
                creation_condition AS (%s)
            SELECT test_create_edge(
                %L, 
                source_id, 
                target_id, 
                %L, 
                creation_condition.properties
            )
            FROM creation_condition
            LEFT JOIN user_edges
                ON creation_condition.source_id = user_edges.source
                AND creation_condition.target_id = user_edges.target
                AND user_edges.edge_type = %L
            WHERE user_edges.edge_type IS NULL -- where no match
        ', 
        p_residence_id, 
        p_residence_id, 
        v_creation_condition,
        p_residence_id,
        v_edge_type,
        v_edge_type
        );
        
        -- Execute the query
        BEGIN
            EXECUTE v_query;
        EXCEPTION
            WHEN OTHERS THEN
                -- Log the error but continue processing other rules
                RAISE WARNING 'Error executing ontology rule for node type %: %', 
                    v_node_type, SQLERRM;
        END;
    END LOOP;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql; 
SQL
