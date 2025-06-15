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
DROP FUNCTION IF EXISTS create_taxonomy_node(VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, VARCHAR);
DROP FUNCTION IF EXISTS update_taxonomy_node(VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, VARCHAR);
DROP FUNCTION IF EXISTS delete_taxonomy_node(VARCHAR);
DROP FUNCTION IF EXISTS get_taxonomy_node(VARCHAR);
DROP FUNCTION IF EXISTS list_taxonomy_nodes();
DROP FUNCTION IF EXISTS get_taxonomy_node_history(VARCHAR);
DROP FUNCTION IF EXISTS format_generic_taxonomy_name(VARCHAR, JSONB);

-- Create sequence for version tracking
CREATE SEQUENCE IF NOT EXISTS taxonomy_version_seq;

-- Create the node_taxonomy table if it doesn't exist
CREATE TABLE IF NOT EXISTS node_taxonomy (
    id SERIAL PRIMARY KEY,
    node_type VARCHAR NOT NULL,
    description VARCHAR,
    name_constraints VARCHAR,
    columns VARCHAR,
    generic_properties JSONB,
    valid_from TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    valid_to TIMESTAMP DEFAULT NULL,
    version INTEGER DEFAULT 0,
    valid_from_version INTEGER,
    valid_to_version INTEGER,
    modifying_user VARCHAR,
    UNIQUE(node_type, valid_to)
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS node_taxonomy_node_type_idx ON node_taxonomy (node_type);
CREATE INDEX IF NOT EXISTS node_taxonomy_valid_to_idx ON node_taxonomy (valid_to);

-- Function to create a new taxonomy node
CREATE OR REPLACE FUNCTION create_taxonomy_node(
    p_node_type VARCHAR,
    p_description VARCHAR,
    p_name_constraints VARCHAR,
    p_columns VARCHAR,
    p_generic_properties JSONB,
    p_modifying_user VARCHAR
) RETURNS INTEGER AS $$
DECLARE
    v_id INTEGER;
    v_version INTEGER;
BEGIN
    -- Check if node type already exists
    SELECT version INTO v_version
    FROM node_taxonomy
    WHERE node_type = p_node_type
    AND valid_to IS NULL;

    IF v_version IS NOT NULL THEN
        RAISE EXCEPTION 'Node type % already exists', p_node_type;
    END IF;

    -- Insert new node
    INSERT INTO node_taxonomy (
        node_type,
        description,
        name_constraints,
        columns,
        generic_properties,
        version,
        valid_from_version,
        modifying_user
    ) VALUES (
        p_node_type,
        p_description,
        p_name_constraints,
        p_columns,
        p_generic_properties,
        0,
        nextval('taxonomy_version_seq'),
        p_modifying_user
    ) RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Function to update an existing taxonomy node
CREATE OR REPLACE FUNCTION update_taxonomy_node(
    p_node_type VARCHAR,
    p_description VARCHAR,
    p_name_constraints VARCHAR,
    p_columns VARCHAR,
    p_generic_properties JSONB,
    p_modifying_user VARCHAR
) RETURNS INTEGER AS $$
DECLARE
    v_id INTEGER;
    v_old_version INTEGER;
    v_new_version INTEGER;
BEGIN
    -- Get current version
    SELECT version INTO v_old_version
    FROM node_taxonomy
    WHERE node_type = p_node_type
    AND valid_to IS NULL;

    IF v_old_version IS NULL THEN
        RAISE EXCEPTION 'Node type % does not exist', p_node_type;
    END IF;

    -- Set valid_to for current version
    UPDATE node_taxonomy
    SET valid_to = CURRENT_TIMESTAMP,
        valid_to_version = nextval('taxonomy_version_seq')
    WHERE node_type = p_node_type
    AND valid_to IS NULL;

    -- Insert new version
    INSERT INTO node_taxonomy (
        node_type,
        description,
        name_constraints,
        columns,
        generic_properties,
        version,
        valid_from_version,
        modifying_user
    ) VALUES (
        p_node_type,
        p_description,
        p_name_constraints,
        p_columns,
        p_generic_properties,
        v_old_version + 1,
        nextval('taxonomy_version_seq'),
        p_modifying_user
    ) RETURNING id INTO v_id;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Function to delete a taxonomy node
CREATE OR REPLACE FUNCTION delete_taxonomy_node(
    p_node_type VARCHAR
) RETURNS BOOLEAN AS $$
DECLARE
    v_version INTEGER;
BEGIN
    -- Get current version
    SELECT version INTO v_version
    FROM node_taxonomy
    WHERE node_type = p_node_type
    AND valid_to IS NULL;

    IF v_version IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Set valid_to for current version
    UPDATE node_taxonomy
    SET valid_to = CURRENT_TIMESTAMP,
        valid_to_version = nextval('taxonomy_version_seq')
    WHERE node_type = p_node_type
    AND valid_to IS NULL;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Function to get current version of a taxonomy node
CREATE OR REPLACE FUNCTION get_taxonomy_node(
    p_node_type VARCHAR
) RETURNS TABLE (
    id INTEGER,
    node_type VARCHAR,
    description VARCHAR,
    name_constraints VARCHAR,
    columns VARCHAR,
    generic_properties JSONB,
    version INTEGER,
    valid_from TIMESTAMP,
    modifying_user VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id,
        t.node_type,
        t.description,
        t.name_constraints,
        t.columns,
        t.generic_properties,
        t.version,
        t.valid_from,
        t.modifying_user
    FROM node_taxonomy t
    WHERE t.node_type = p_node_type
    AND t.valid_to IS NULL;
END;
$$ LANGUAGE plpgsql;

-- Function to list all current taxonomy nodes
CREATE OR REPLACE FUNCTION list_taxonomy_nodes()
RETURNS TABLE (
    id INTEGER,
    node_type VARCHAR,
    description VARCHAR,
    name_constraints VARCHAR,
    columns VARCHAR,
    generic_properties JSONB,
    version INTEGER,
    valid_from TIMESTAMP,
    modifying_user VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id,
        t.node_type,
        t.description,
        t.name_constraints,
        t.columns,
        t.generic_properties,
        t.version,
        t.valid_from,
        t.modifying_user
    FROM node_taxonomy t
    WHERE t.valid_to IS NULL
    ORDER BY t.node_type;
END;
$$ LANGUAGE plpgsql;

-- Function to get version history of a taxonomy node
CREATE OR REPLACE FUNCTION get_taxonomy_node_history(
    p_node_type VARCHAR
) RETURNS TABLE (
    id INTEGER,
    node_type VARCHAR,
    description VARCHAR,
    name_constraints VARCHAR,
    columns VARCHAR,
    generic_properties JSONB,
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
        t.node_type,
        t.description,
        t.name_constraints,
        t.columns,
        t.generic_properties,
        t.version,
        t.valid_from,
        t.valid_to,
        t.valid_from_version,
        t.valid_to_version,
        t.modifying_user
    FROM node_taxonomy t
    WHERE t.node_type = p_node_type
    ORDER BY t.valid_from_version;
END;
$$ LANGUAGE plpgsql;

-- Function to format a generic taxonomy name using values from a JSONB object
CREATE OR REPLACE FUNCTION format_generic_taxonomy_name(
    p_name_template VARCHAR,
    p_properties JSONB
) RETURNS VARCHAR AS $$
DECLARE
    v_result VARCHAR;
    v_parts TEXT[];
    v_part TEXT;
    v_key TEXT;
    v_value TEXT;
BEGIN
    -- Split the template by spaces and dashes
    v_parts := string_to_array(p_name_template, ' ');
    v_result := '';
    
    FOR i IN 1..array_length(v_parts, 1) LOOP
        v_part := v_parts[i];
        
        -- Check if the part is a key (enclosed in curly braces)
        IF v_part ~ '^{.*}$' THEN
            -- Extract the key name from curly braces
            v_key := substring(v_part from 2 for length(v_part) - 2);
            -- Get the value from the JSONB object
            v_value := p_properties->>v_key;
            
            -- If value is null, use the key name
            IF v_value IS NULL THEN
                v_value := v_key;
            END IF;
            
            v_result := v_result || v_value;
        ELSE
            v_result := v_result || v_part;
        END IF;
        
        -- Add space if not the last part and not a dash
        IF i < array_length(v_parts, 1) AND v_part != '-' THEN
            v_result := v_result || ' ';
        END IF;
    END LOOP;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

SQL
