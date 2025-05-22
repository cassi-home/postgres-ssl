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
    DROP FUNCTION IF EXISTS test_create_graph(TEXT);
    DROP FUNCTION IF EXISTS test_create_node(TEXT, VARCHAR, VARCHAR, JSONB);
    DROP FUNCTION IF EXISTS test_create_edge(TEXT, INTEGER, INTEGER, VARCHAR, JSONB);
    DROP FUNCTION IF EXISTS test_open_nodes(TEXT, TEXT[]);
    DROP FUNCTION IF EXISTS test_search_nodes(TEXT, TEXT);
    DROP FUNCTION IF EXISTS test_search_edges(TEXT, TEXT);
    DROP FUNCTION IF EXISTS test_read_graph(TEXT);
    DROP FUNCTION IF EXISTS test_check_graph_exists(TEXT);

    CREATE OR REPLACE FUNCTION test_check_graph_exists(
        user_id TEXT
    ) RETURNS BOOLEAN AS $$
    DECLARE
        safe_user_id TEXT;
        nodes_exist BOOLEAN;
        edges_exist BOOLEAN;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Check if nodes table exists
        SELECT EXISTS (
            SELECT FROM information_schema.tables 
            WHERE table_schema = 'ag_catalog' 
            AND table_name = format('graph_%s_nodes', safe_user_id)
        ) INTO nodes_exist;
        
        -- Check if edges table exists
        SELECT EXISTS (
            SELECT FROM information_schema.tables 
            WHERE table_schema = 'ag_catalog' 
            AND table_name = format('graph_%s_edges', safe_user_id)
        ) INTO edges_exist;
        
        -- Return true only if both tables exist
        RETURN nodes_exist AND edges_exist;
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_create_graph(
        user_id TEXT
    ) RETURNS BOOLEAN AS $$
    DECLARE
        create_nodes_sql TEXT;
        create_edges_sql TEXT;
        create_index_sql TEXT;
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Create nodes table
        create_nodes_sql := format(
            'CREATE TABLE IF NOT EXISTS graph_%s_nodes (
                -- Internal identifiers
                id          SERIAL PRIMARY KEY,
                node_id   INTEGER,
                node_type VARCHAR,
                node_name VARCHAR,
                version     INTEGER DEFAULT 0,
                created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

                -- Version control
                valid_from  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                valid_to    TIMESTAMP DEFAULT NULL,

                -- Use JSONB instead of JSON for better read performance
                properties  JSONB
            )',
            safe_user_id
        );
        
        -- Create edges table
        create_edges_sql := format(
            'CREATE TABLE IF NOT EXISTS graph_%s_edges (
                -- Internal identifiers
                id            SERIAL PRIMARY KEY,
                source        INTEGER,
                target        INTEGER,
                edge_type VARCHAR,
                version       INTEGER DEFAULT 0,
                created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

                -- Version control
                valid_from    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                valid_to      TIMESTAMP DEFAULT NULL,

                -- Use JSONB instead of JSON for better read performance
                properties    JSONB
            )',
            safe_user_id
        );
        
        EXECUTE create_nodes_sql;
        EXECUTE create_edges_sql;

        -- Create indexes for nodes table
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS graph_%s_nodes_node_type_idx ON graph_%s_nodes (node_type)',
            safe_user_id,
            safe_user_id
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS graph_%s_nodes_node_name_idx ON graph_%s_nodes (node_name)',
            safe_user_id,
            safe_user_id
        );

        -- Create indexes for edges table
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS graph_%s_edges_source_idx ON graph_%s_edges (source)',
            safe_user_id,
            safe_user_id
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS graph_%s_edges_target_idx ON graph_%s_edges (target)',
            safe_user_id,
            safe_user_id
        );
        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS graph_%s_edges_type_idx ON graph_%s_edges (edge_type)',
            safe_user_id,
            safe_user_id
        );

        -- Cluster the tables
        EXECUTE format('CLUSTER graph_%s_nodes USING graph_%s_nodes_node_type_idx', safe_user_id, safe_user_id);
        EXECUTE format('CLUSTER graph_%s_edges USING graph_%s_edges_type_idx', safe_user_id, safe_user_id);
        
        RETURN TRUE;
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_create_node(
        user_id TEXT,
        node_type VARCHAR,
        node_name VARCHAR,
        properties JSONB
    ) RETURNS INTEGER AS $$
    DECLARE
        existing_node_id INTEGER;
        existing_properties JSONB;
        existing_version INTEGER;
        new_node_id INTEGER;
        merged_properties JSONB;
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- First, check if a node with this name exists and get its node_id, properties, and version
        EXECUTE format('
            SELECT node_id, properties, version 
            FROM graph_%s_nodes 
            WHERE node_name = $1 
            AND valid_to IS NULL 
            LIMIT 1',
            safe_user_id
        ) INTO existing_node_id, existing_properties, existing_version USING node_name;

        -- If node exists, deprecate it
        IF existing_node_id IS NOT NULL THEN
            EXECUTE format('
                UPDATE graph_%s_nodes 
                SET valid_to = CURRENT_TIMESTAMP 
                WHERE node_name = $1 
                AND valid_to IS NULL',
                safe_user_id
            ) USING node_name;
            
            new_node_id := existing_node_id;
            -- Merge old and new properties, with new properties taking precedence
            merged_properties := COALESCE(existing_properties, '{}'::jsonb) || properties;
        ELSE
            merged_properties := properties;
            existing_version := -1; -- Start at -1 so first version will be 0
        END IF;

        -- Insert the new node
        EXECUTE format('
            INSERT INTO graph_%s_nodes (
                node_id,
                node_type,
                node_name,
                version,
                properties
            ) VALUES (
                $1,
                $2,
                $3,
                $4,
                $5
            ) RETURNING id',
            safe_user_id
        ) INTO new_node_id 
        USING 
            COALESCE(existing_node_id, nextval(format('graph_%s_nodes_id_seq', safe_user_id))),
            node_type,
            node_name,
            existing_version + 1,
            merged_properties;

        RETURN new_node_id;
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_create_edge(
        user_id TEXT,
        source_id INTEGER,
        target_id INTEGER,
        edge_type VARCHAR,
        properties JSONB
    ) RETURNS INTEGER AS $$
    DECLARE
        existing_edge_id INTEGER;
        existing_properties JSONB;
        existing_version INTEGER;
        new_edge_id INTEGER;
        merged_properties JSONB;
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- First, check if a edge exists between these nodes with this type
        EXECUTE format('
            SELECT id, properties, version 
            FROM graph_%s_edges 
            WHERE source = $1 
            AND target = $2 
            AND edge_type = $3
            AND valid_to IS NULL 
            LIMIT 1',
            safe_user_id
        ) INTO existing_edge_id, existing_properties, existing_version 
        USING source_id, target_id, edge_type;

        -- If edge exists, deprecate it
        IF existing_edge_id IS NOT NULL THEN
            EXECUTE format('
                UPDATE graph_%s_edges 
                SET valid_to = CURRENT_TIMESTAMP 
                WHERE source = $1 
                AND target = $2 
                AND edge_type = $3
                AND valid_to IS NULL',
                safe_user_id
            ) USING source_id, target_id, edge_type;
            
            -- Merge old and new properties, with new properties taking precedence
            merged_properties := COALESCE(existing_properties, '{}'::jsonb) || properties;
        ELSE
            merged_properties := properties;
            existing_version := -1; -- Start at -1 so first version will be 0
        END IF;

        -- Insert the new edge
        EXECUTE format('
            INSERT INTO graph_%s_edges (
                source,
                target,
                edge_type,
                version,
                properties
            ) VALUES (
                $1,
                $2,
                $3,
                $4,
                $5
            ) RETURNING id',
            safe_user_id
        ) INTO new_edge_id 
        USING 
            source_id,
            target_id,
            edge_type,
            existing_version + 1,
            merged_properties;

        RETURN new_edge_id;
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_open_nodes(
        user_id TEXT,
        node_names TEXT[]
    ) RETURNS TABLE (
        node_id INTEGER,
        node_type VARCHAR,
        node_name VARCHAR,
        properties JSONB
    ) AS $$
    DECLARE
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        RETURN QUERY EXECUTE format('
            SELECT 
                node_id,
                node_type,
                node_name,
                properties
            FROM graph_%s_nodes
            WHERE node_name = ANY($1)
            AND valid_to IS NULL
            ORDER BY node_name',
            safe_user_id
        ) USING node_names;
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_search_nodes(
        user_id TEXT,
        keyword TEXT
    ) RETURNS TABLE (
        node_id INTEGER,
        node_type VARCHAR,
        node_name VARCHAR,
        properties JSONB
    ) AS $$
    DECLARE
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        RETURN QUERY EXECUTE format(
            'SELECT 
                node_id,
                node_type, 
                node_name, 
                properties 
             FROM graph_%s_nodes 
             WHERE valid_to IS NULL AND (
                node_name ILIKE %L OR
                properties::TEXT ILIKE %L OR
                (node_type ILIKE %L)
             )
             ORDER BY node_name',
            safe_user_id,
            '%' || keyword || '%',
            '%' || keyword || '%',
            '%' || keyword || '%'
        );
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_search_edges(
        user_id TEXT,
        keyword TEXT
    ) RETURNS TABLE (
        edge_id INTEGER,
        source_id INTEGER,
        target_id INTEGER,
        edge_type VARCHAR,
        properties JSONB
    ) AS $$
    DECLARE
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        RETURN QUERY EXECUTE format(
            'SELECT 
                id AS edge_id,
                source,
                target,
                edge_type, 
                properties 
             FROM graph_%s_edges 
             WHERE valid_to IS NULL AND (
                edge_type ILIKE %L OR
                properties::TEXT ILIKE %L
             )
             ORDER BY edge_type',
            safe_user_id,
            '%' || keyword || '%',
            '%' || keyword || '%'
        );
    END;
    $$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION test_read_graph(
        user_id TEXT
    ) RETURNS TABLE (
        result_type TEXT,
        entity_id INTEGER,
        source_target INTEGER,
        name VARCHAR,
        type VARCHAR,
        version INTEGER,
        properties JSONB
    ) AS $$
    DECLARE
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- First return all nodes
        RETURN QUERY EXECUTE format('
            SELECT 
                ''node''::TEXT as result_type,
                node_id as entity_id,
                node_id as source_target,
                node_name as name,
                node_type as type,
                version,
                properties
            FROM graph_%s_nodes
            WHERE valid_to IS NULL
            
            UNION ALL
            
            SELECT 
                ''edge''::TEXT as result_type,
                id as entity_id,
                source as source_target,
                null as name,
                edge_type as type,
                version,
                properties
            FROM graph_%s_edges
            WHERE valid_to IS NULL
            
            ORDER BY result_type',
            safe_user_id,
            safe_user_id
        );
    END;
    $$ LANGUAGE plpgsql;

    -- Define additional functions for graph operations

    -- Drop functions if they exist
    DROP FUNCTION IF EXISTS test_delete_node(TEXT, INTEGER);
    DROP FUNCTION IF EXISTS test_delete_edge(TEXT, INTEGER);
    DROP FUNCTION IF EXISTS test_find_node_by_name(TEXT, TEXT);
    DROP FUNCTION IF EXISTS test_find_edges_between(TEXT, INTEGER, INTEGER, TEXT);
    DROP FUNCTION IF EXISTS test_update_node_property(TEXT, INTEGER, TEXT, JSONB);
    DROP FUNCTION IF EXISTS test_edges_of(TEXT, INTEGER);

    -- Function to delete a node completely
    CREATE OR REPLACE FUNCTION test_delete_node(
        user_id TEXT,
        node_id INTEGER
    ) RETURNS BOOLEAN AS $$
    DECLARE
        safe_user_id TEXT;
        affected_rows INTEGER;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Delete all associated edges first to maintain referential integrity
        EXECUTE format('
            DELETE FROM graph_%s_edges 
            WHERE source = $1 OR target = $1',
            safe_user_id
        ) USING node_id;
        
        -- Delete the node
        EXECUTE format('
            DELETE FROM graph_%s_nodes 
            WHERE node_id = $1',
            safe_user_id
        ) USING node_id;
        
        -- Get the number of affected rows
        GET DIAGNOSTICS affected_rows = ROW_COUNT;
        
        -- Return true if at least one row was affected
        RETURN affected_rows > 0;
    END;
    $$ LANGUAGE plpgsql;

    -- Function to delete an edge completely
    CREATE OR REPLACE FUNCTION test_delete_edge(
        user_id TEXT,
        edge_id INTEGER
    ) RETURNS BOOLEAN AS $$
    DECLARE
        safe_user_id TEXT;
        affected_rows INTEGER;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Delete the edge
        EXECUTE format('
            DELETE FROM graph_%s_edges 
            WHERE id = $1',
            safe_user_id
        ) USING edge_id;
        
        -- Get the number of affected rows
        GET DIAGNOSTICS affected_rows = ROW_COUNT;
        
        -- Return true if at least one row was affected
        RETURN affected_rows > 0;
    END;
    $$ LANGUAGE plpgsql;

    -- Function to find a node ID by name
    CREATE OR REPLACE FUNCTION test_find_node_by_name(
        user_id TEXT,
        node_name TEXT
    ) RETURNS INTEGER AS $$
    DECLARE
        safe_user_id TEXT;
        found_node_id INTEGER;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Find the node ID
        EXECUTE format('
            SELECT node_id 
            FROM graph_%s_nodes 
            WHERE node_name = $1 
            AND valid_to IS NULL 
            LIMIT 1',
            safe_user_id
        ) INTO found_node_id USING node_name;
        
        -- Return the found node ID (or NULL if not found)
        RETURN found_node_id;
    END;
    $$ LANGUAGE plpgsql;

    -- Function to find edges between nodes
    CREATE OR REPLACE FUNCTION test_find_edges_between(
        user_id TEXT,
        source_id INTEGER,
        target_id INTEGER,
        edge_type TEXT DEFAULT NULL
    ) RETURNS TABLE (
        edge_id INTEGER
    ) AS $$
    DECLARE
        safe_user_id TEXT;
        query_sql TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Construct the query based on whether edge_type is provided
        IF edge_type IS NULL THEN
            query_sql := format('
                SELECT id AS edge_id
                FROM graph_%s_edges
                WHERE source = $1 
                AND target = $2
                AND valid_to IS NULL',
                safe_user_id
            );
        ELSE
            query_sql := format('
                SELECT id AS edge_id
                FROM graph_%s_edges
                WHERE source = $1 
                AND target = $2
                AND edge_type = $3
                AND valid_to IS NULL',
                safe_user_id
            );
        END IF;
        
        -- Execute the appropriate query
        IF edge_type IS NULL THEN
            RETURN QUERY EXECUTE query_sql USING source_id, target_id;
        ELSE
            RETURN QUERY EXECUTE query_sql USING source_id, target_id, edge_type;
        END IF;
    END;
    $$ LANGUAGE plpgsql;

    -- Function to update a specific property without versioning
    CREATE OR REPLACE FUNCTION test_update_node_property(
        user_id TEXT,
        node_id INTEGER,
        property_name TEXT,
        property_value JSONB
    ) RETURNS BOOLEAN AS $$
    DECLARE
        safe_user_id TEXT;
        current_properties JSONB;
        updated_properties JSONB;
        affected_rows INTEGER;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        -- Get current properties
        EXECUTE format('
            SELECT properties
            FROM graph_%s_nodes
            WHERE node_id = $1
            AND valid_to IS NULL',
            safe_user_id
        ) INTO current_properties USING node_id;
        
        -- If node not found, return false
        IF current_properties IS NULL THEN
            RETURN FALSE;
        END IF;
        
        -- Create updated properties by setting specific property
        updated_properties := jsonb_set(
            current_properties,
            ARRAY[property_name],
            property_value
        );
        
        -- Update the node with new properties
        EXECUTE format('
            UPDATE graph_%s_nodes
            SET properties = $2
            WHERE node_id = $1
            AND valid_to IS NULL',
            safe_user_id
        ) USING node_id, updated_properties;
        
        -- Get the number of affected rows
        GET DIAGNOSTICS affected_rows = ROW_COUNT;
        
        -- Return true if update was successful
        RETURN affected_rows > 0;
    END;
    $$ LANGUAGE plpgsql;

    -- Function to get all edges connected to a node with node names
    CREATE OR REPLACE FUNCTION test_edges_of(
        user_id TEXT,
        node_id INTEGER
    ) RETURNS TABLE (
        edge_id INTEGER,
        edge_type VARCHAR,
        source_id INTEGER,
        source_name VARCHAR,
        target_id INTEGER,
        target_name VARCHAR,
        properties JSONB
    ) AS $$
    DECLARE
        safe_user_id TEXT;
    BEGIN
        -- Replace hyphens with underscores for safe table names
        safe_user_id := regexp_replace(user_id, '-', '_', 'g');
        
        RETURN QUERY EXECUTE format('
            -- Outgoing edges (where the node is the source)
            SELECT 
                e.id AS edge_id,
                e.edge_type,
                e.source AS source_id,
                source_node.node_name AS source_name,
                e.target AS target_id,
                target_node.node_name AS target_name,
                e.properties
            FROM 
                graph_%1$s_edges e
                JOIN graph_%1$s_nodes source_node ON e.source = source_node.node_id AND source_node.valid_to IS NULL
                JOIN graph_%1$s_nodes target_node ON e.target = target_node.node_id AND target_node.valid_to IS NULL
            WHERE 
                e.source = $1 AND e.valid_to IS NULL
            
            UNION ALL
            
            -- Incoming edges (where the node is the target)
            SELECT 
                e.id AS edge_id,
                e.edge_type,
                e.source AS source_id,
                source_node.node_name AS source_name,
                e.target AS target_id,
                target_node.node_name AS target_name,
                e.properties
            FROM 
                graph_%1$s_edges e
                JOIN graph_%1$s_nodes source_node ON e.source = source_node.node_id AND source_node.valid_to IS NULL
                JOIN graph_%1$s_nodes target_node ON e.target = target_node.node_id AND target_node.valid_to IS NULL
            WHERE 
                e.target = $1 AND e.valid_to IS NULL
            
            ORDER BY edge_type, edge_id
        ', safe_user_id) USING node_id;
    END;
    $$ LANGUAGE plpgsql;

SQL

