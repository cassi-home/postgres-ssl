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

CREATE OR REPLACE FUNCTION create_graph(
    user_id TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    create_nodes_sql TEXT;
    create_relations_sql TEXT;
    create_index_sql TEXT;
BEGIN
    -- Create nodes table
    create_nodes_sql := format(
        'CREATE TABLE IF NOT EXISTS graph_%I_nodes (
            -- Internal identifiers
            id          SERIAL PRIMARY KEY,
            entity_id   INTEGER,
            entity_type VARCHAR,
            entity_name VARCHAR,
            version     INTEGER DEFAULT 0,
            created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            -- Version control
            valid_from  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            valid_to    TIMESTAMP DEFAULT NULL,

            -- Use JSONB instead of JSON for better read performance
            properties  JSONB
        )',
        user_id
    );
    
    -- Create relations table
    create_relations_sql := format(
        'CREATE TABLE IF NOT EXISTS graph_%I_relations (
            -- Internal identifiers
            id            SERIAL PRIMARY KEY,
            source        INTEGER,
            target        INTEGER,
            relation_type VARCHAR,
            version       INTEGER DEFAULT 0,
            created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

            -- Version control
            valid_from    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            valid_to      TIMESTAMP DEFAULT NULL,

            -- Use JSONB instead of JSON for better read performance
            properties    JSONB
        )',
        user_id,
        user_id,
        user_id
    );
    
    EXECUTE create_nodes_sql;
    EXECUTE create_relations_sql;

    -- Create indexes for nodes table
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS graph_%I_nodes_entity_type_idx ON graph_%I_nodes (entity_type)',
        user_id,
        user_id
    );
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS graph_%I_nodes_entity_name_idx ON graph_%I_nodes (entity_name)',
        user_id,
        user_id
    );

    -- Create indexes for relations table
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS graph_%I_relations_source_idx ON graph_%I_relations (source)',
        user_id,
        user_id
    );
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS graph_%I_relations_target_idx ON graph_%I_relations (target)',
        user_id,
        user_id
    );
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS graph_%I_relations_type_idx ON graph_%I_relations (relation_type)',
        user_id,
        user_id
    );

    -- Cluster the tables
    EXECUTE format('CLUSTER graph_%I_nodes USING graph_%I_nodes_entity_type_idx', user_id, user_id);
    EXECUTE format('CLUSTER graph_%I_relations USING graph_%I_relations_type_idx', user_id, user_id);
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_node(
    user_id TEXT,
    entity_type VARCHAR,
    entity_name VARCHAR,
    properties JSONB
) RETURNS INTEGER AS $$
DECLARE
    existing_entity_id INTEGER;
    existing_properties JSONB;
    existing_version INTEGER;
    new_entity_id INTEGER;
    merged_properties JSONB;
BEGIN
    -- First, check if a node with this name exists and get its entity_id, properties, and version
    EXECUTE format('
        SELECT entity_id, properties, version 
        FROM graph_%I_nodes 
        WHERE entity_name = $1 
        AND valid_to IS NULL 
        LIMIT 1',
        user_id
    ) INTO existing_entity_id, existing_properties, existing_version USING entity_name;

    -- If node exists, deprecate it
    IF existing_entity_id IS NOT NULL THEN
        EXECUTE format('
            UPDATE graph_%I_nodes 
            SET valid_to = CURRENT_TIMESTAMP 
            WHERE entity_name = $1 
            AND valid_to IS NULL',
            user_id
        ) USING entity_name;
        
        new_entity_id := existing_entity_id;
        -- Merge old and new properties, with new properties taking precedence
        merged_properties := COALESCE(existing_properties, '{}'::jsonb) || properties;
    ELSE
        merged_properties := properties;
        existing_version := -1; -- Start at -1 so first version will be 0
    END IF;

    -- Insert the new node
    EXECUTE format('
        INSERT INTO graph_%I_nodes (
            entity_id,
            entity_type,
            entity_name,
            version,
            properties
        ) VALUES (
            $1,
            $2,
            $3,
            $4,
            $5
        ) RETURNING id',
        user_id
    ) INTO new_entity_id 
    USING 
        COALESCE(existing_entity_id, nextval(format('graph_%I_nodes_id_seq', user_id))),
        entity_type,
        entity_name,
        existing_version + 1,
        merged_properties;

    RETURN new_entity_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_relation(
    user_id TEXT,
    source_id INTEGER,
    target_id INTEGER,
    relation_type VARCHAR,
    properties JSONB
) RETURNS INTEGER AS $$
DECLARE
    existing_relation_id INTEGER;
    existing_properties JSONB;
    existing_version INTEGER;
    new_relation_id INTEGER;
    merged_properties JSONB;
BEGIN
    -- First, check if a relation exists between these nodes with this type
    EXECUTE format('
        SELECT id, properties, version 
        FROM graph_%I_relations 
        WHERE source = $1 
        AND target = $2 
        AND relation_type = $3
        AND valid_to IS NULL 
        LIMIT 1',
        user_id
    ) INTO existing_relation_id, existing_properties, existing_version 
    USING source_id, target_id, relation_type;

    -- If relation exists, deprecate it
    IF existing_relation_id IS NOT NULL THEN
        EXECUTE format('
            UPDATE graph_%I_relations 
            SET valid_to = CURRENT_TIMESTAMP 
            WHERE source = $1 
            AND target = $2 
            AND relation_type = $3
            AND valid_to IS NULL',
            user_id
        ) USING source_id, target_id, relation_type;
        
        -- Merge old and new properties, with new properties taking precedence
        merged_properties := COALESCE(existing_properties, '{}'::jsonb) || properties;
    ELSE
        merged_properties := properties;
        existing_version := -1; -- Start at -1 so first version will be 0
    END IF;

    -- Insert the new relation
    EXECUTE format('
        INSERT INTO graph_%I_relations (
            source,
            target,
            relation_type,
            version,
            properties
        ) VALUES (
            $1,
            $2,
            $3,
            $4,
            $5
        ) RETURNING id',
        user_id
    ) INTO new_relation_id 
    USING 
        source_id,
        target_id,
        relation_type,
        existing_version + 1,
        merged_properties;

    RETURN new_relation_id;
END;
$$ LANGUAGE plpgsql;

SQL

