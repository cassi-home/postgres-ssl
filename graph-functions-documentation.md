# Graph Database API Documentation

This document describes the PostgreSQL functions available for interacting with the graph database. These functions provide a high-level API for creating and querying graph data structures stored in PostgreSQL.

## Core Concepts

The graph database consists of two main components:
- **Nodes**: Vertices in the graph with properties
- **Edges**: Connections between nodes with properties

Both nodes and edges support:
- **Versioning**: Each update creates a new version while preserving history
- **Properties**: JSONB documents storing flexible attributes
- **Temporal Tracking**: Valid time periods for each version

## UUID Handling

All functions properly handle UUIDs for the `user_id` parameter:
- Hyphens in UUIDs are automatically converted to underscores
- This ensures PostgreSQL can use them as identifiers without quoting issues
- For example, UUID `ab6751ca-a52c-421c-981c-7465f40bc31e` will create tables named `graph_ab6751ca_a52c_421c_981c_7465f40bc31e_nodes` and `graph_ab6751ca_a52c_421c_981c_7465f40bc31e_edges`

## Function Reference

### `test_create_graph(user_id TEXT) RETURNS BOOLEAN`

Creates the necessary tables and indexes for a new graph instance.

**Parameters:**
- `user_id`: A unique identifier for the graph instance (can be a UUID with hyphens)

**Returns:**
- `TRUE` if the graph was created successfully

**Details:**
- Creates two tables: `graph_[user_id]_nodes` and `graph_[user_id]_edges`
- Automatically converts hyphens in UUIDs to underscores for PostgreSQL compatibility
- Establishes indexes for efficient querying
- Sets up clustering for performance optimization
- Safe to call multiple times (uses CREATE IF NOT EXISTS)

**Example:**
```sql
SELECT test_create_graph('customer_123');
-- Or with UUID
SELECT test_create_graph('ab6751ca-a52c-421c-981c-7465f40bc31e');
```

---

### `test_create_node(user_id TEXT, node_type VARCHAR, node_name VARCHAR, properties JSONB) RETURNS INTEGER`

Creates or updates a node in the graph.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `node_type`: Type classification for the node
- `node_name`: A unique name for the node
- `properties`: A JSONB object containing the node's properties

**Returns:**
- The node's ID in the database

**Details:**
- If a node with the given name already exists, it deprecates the old version and creates a new one
- Merges properties between versions (new properties take precedence over old ones)
- Maintains version history while only exposing the current version by default
- Increments version numbers automatically
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT test_create_node(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    'person',
    'john_doe',
    '{"name": "John Doe", "age": 30}'::jsonb
);
```

---

### `test_create_edge(user_id TEXT, source_id INTEGER, target_id INTEGER, edge_type VARCHAR, properties JSONB) RETURNS INTEGER`

Creates or updates an edge connecting two nodes.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `source_id`: The node ID of the source node
- `target_id`: The node ID of the target node
- `edge_type`: Type classification for the edge
- `properties`: A JSONB object containing the edge's properties

**Returns:**
- The edge's ID in the database

**Details:**
- If an edge with the same source, target, and type already exists, it deprecates the old version
- Merges properties between versions (new properties take precedence)
- Supports versioning and temporal tracking
- Can create multiple edges of different types between the same nodes
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT test_create_edge(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    101, -- source_id
    102, -- target_id
    'FRIEND_OF',
    '{"since": "2023-01-01"}'::jsonb
);
```

---

### `test_open_nodes(user_id TEXT, node_names TEXT[]) RETURNS TABLE`

Retrieves multiple nodes by their names.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `node_names`: An array of node names to retrieve

**Returns:**
A table with the following columns:
- `node_id`: The unique identifier of each node
- `node_type`: The type of each node
- `node_name`: The name of each node
- `properties`: The properties of each node

**Details:**
- Only returns the current version of each node (where valid_to IS NULL)
- Returns multiple rows if multiple nodes are requested
- Orders results by node_name
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT * FROM test_open_nodes('ab6751ca-a52c-421c-981c-7465f40bc31e', ARRAY['john_doe', 'jane_doe']);
```

---

### `test_search_nodes(user_id TEXT, keyword TEXT) RETURNS TABLE`

Searches for nodes containing a keyword in their name or properties.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `keyword`: The keyword to search for

**Returns:**
A table with the following columns:
- `node_id`: The unique identifier of each matching node
- `node_type`: The type of each matching node
- `node_name`: The name of each matching node
- `properties`: The properties of each matching node

**Details:**
- Performs case-insensitive search using ILIKE
- Searches in the node_name field, the node_type field, and the properties JSON
- Only returns current versions of nodes
- Orders results by node_name
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT * FROM test_search_nodes('ab6751ca-a52c-421c-981c-7465f40bc31e', 'john');
```

---

### `test_search_edges(user_id TEXT, keyword TEXT) RETURNS TABLE`

Searches for edges containing a keyword in their properties.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `keyword`: The keyword to search for

**Returns:**
A table with the following columns:
- `edge_id`: The unique identifier of each matching edge
- `source_id`: The ID of the source node
- `target_id`: The ID of the target node
- `edge_type`: The type of each matching edge
- `properties`: The properties of each matching edge

**Details:**
- Performs case-insensitive search in the edge properties and edge type
- Only returns current versions of edges
- Orders results by edge_type
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT * FROM test_search_edges('ab6751ca-a52c-421c-981c-7465f40bc31e', 'friend');
```

---

### `test_read_graph(user_id TEXT) RETURNS TABLE`

Retrieves the entire graph structure (both nodes and edges).

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)

**Returns:**
A table with the following columns:
- `result_type`: 'node' or 'edge' indicating the type of record
- `id`: The database ID of the record
- `entity_id`: For nodes, this is the node_id; for edges, this is the edge_id
- `source_target`: For nodes, this is the node_id; for edges, this is the source node ID
- `name`: For nodes, this is the node_name; for edges, this is NULL
- `type`: For nodes, this is the node_type; for edges, this is the edge_type
- `version`: The version number of the record
- `properties`: The properties of the record

**Details:**
- Returns a unified view of both nodes and edges
- Only includes current versions (where valid_to IS NULL)
- Orders results by result_type (nodes first) and then by ID
- Useful for exporting the entire graph for visualization
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT * FROM test_read_graph('ab6751ca-a52c-421c-981c-7465f40bc31e');
```

---

### `test_delete_node(user_id TEXT, node_id INTEGER) RETURNS BOOLEAN`

Permanently deletes a node and all its associated edges.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `node_id`: The ID of the node to delete

**Returns:**
- `TRUE` if the node was deleted successfully, `FALSE` if the node was not found

**Details:**
- Completely removes the node and all versions from the database
- Also removes all edges connected to this node (both incoming and outgoing)
- This operation cannot be undone
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT test_delete_node('ab6751ca-a52c-421c-981c-7465f40bc31e', 123);
```

---

### `test_delete_edge(user_id TEXT, edge_id INTEGER) RETURNS BOOLEAN`

Permanently deletes an edge from the graph.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `edge_id`: The ID of the edge to delete

**Returns:**
- `TRUE` if the edge was deleted successfully, `FALSE` if the edge was not found

**Details:**
- Completely removes the edge and all versions from the database
- This operation cannot be undone
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT test_delete_edge('ab6751ca-a52c-421c-981c-7465f40bc31e', 456);
```

---

### `test_find_node_by_name(user_id TEXT, node_name TEXT) RETURNS INTEGER`

Finds a node's ID by its name.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `node_name`: The name of the node to find

**Returns:**
- The node_id if found, NULL if not found

**Details:**
- Only returns the ID of the current version of the node (where valid_to IS NULL)
- Useful for getting a node ID to use in other functions
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT test_find_node_by_name('ab6751ca-a52c-421c-981c-7465f40bc31e', 'john_doe');
```

---

### `test_find_edges_between(user_id TEXT, source_id INTEGER, target_id INTEGER, edge_type TEXT DEFAULT NULL) RETURNS TABLE`

Finds edges between two specified nodes.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `source_id`: The ID of the source node
- `target_id`: The ID of the target node
- `edge_type`: (Optional) The type of edge to find. If NULL, returns all edge types.

**Returns:**
A table with the following column:
- `edge_id`: The ID of each matching edge

**Details:**
- Only returns the current versions of edges (where valid_to IS NULL)
- Can filter by edge type if specified
- If edge_type is NULL, returns all edges between the nodes regardless of type
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
-- Find all edges between nodes 101 and 102
SELECT * FROM test_find_edges_between('ab6751ca-a52c-421c-981c-7465f40bc31e', 101, 102);

-- Find only 'FRIEND_OF' edges between nodes 101 and 102
SELECT * FROM test_find_edges_between('ab6751ca-a52c-421c-981c-7465f40bc31e', 101, 102, 'FRIEND_OF');
```

---

### `test_edges_of(user_id TEXT, node_id INTEGER) RETURNS TABLE`

Gets all edges (both incoming and outgoing) connected to a specific node, including the names of nodes on both sides of each edge.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `node_id`: The ID of the node to find edges for

**Returns:**
A table with the following columns:
- `edge_id`: The ID of the edge
- `edge_type`: The type of the edge
- `source_id`: The ID of the source node
- `source_name`: The name of the source node
- `target_id`: The ID of the target node
- `target_name`: The name of the target node
- `properties`: The properties of the edge

**Details:**
- Returns both outgoing edges (where the node is the source) and incoming edges (where the node is the target)
- Only returns current versions of edges and nodes (where valid_to IS NULL)
- Joins with the nodes table to retrieve node names
- Results are ordered by edge_type and edge_id
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
-- Get all edges connected to node 101 with node names on both sides
SELECT * FROM test_edges_of('ab6751ca-a52c-421c-981c-7465f40bc31e', 101);
```

---

### `test_update_node_property(user_id TEXT, node_id INTEGER, property_name TEXT, property_value JSONB) RETURNS BOOLEAN`

Updates a specific property of a node without creating a new version.

**Parameters:**
- `user_id`: The graph instance identifier (can be a UUID with hyphens)
- `node_id`: The ID of the node to update
- `property_name`: The name of the property to update
- `property_value`: The new JSONB value for the property

**Returns:**
- `TRUE` if the property was updated successfully, `FALSE` if the node was not found

**Details:**
- Unlike test_create_node, this function updates a property in-place without versioning
- Useful for frequently changing properties where history is not important
- Only affects the current version of the node (where valid_to IS NULL)
- Handles UUIDs by converting hyphens to underscores

**Example:**
```sql
SELECT test_update_node_property(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    123,
    'last_active',
    '"2023-09-15T14:30:00Z"'::jsonb
);
```

## Usage Patterns

### Creating a Graph
```sql
-- Using a simple string ID
SELECT test_create_graph('my_graph');

-- Using a UUID
SELECT test_create_graph('ab6751ca-a52c-421c-981c-7465f40bc31e');
```

### Adding Nodes
```sql
-- Add first node
SELECT test_create_node('ab6751ca-a52c-421c-981c-7465f40bc31e', 'person', 'alice', '{"age": 30}'::jsonb);

-- Add second node
SELECT test_create_node('ab6751ca-a52c-421c-981c-7465f40bc31e', 'person', 'bob', '{"age": 28}'::jsonb);
```

### Connecting Nodes
```sql
SELECT test_create_edge(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    (SELECT node_id FROM graph_ab6751ca_a52c_421c_981c_7465f40bc31e_nodes WHERE node_name = 'alice' AND valid_to IS NULL),
    (SELECT node_id FROM graph_ab6751ca_a52c_421c_981c_7465f40bc31e_nodes WHERE node_name = 'bob' AND valid_to IS NULL),
    'KNOWS',
    '{"since": "2020-01-01"}'::jsonb
);
```

### Querying the Graph
```sql
-- Get specific nodes
SELECT * FROM test_open_nodes('ab6751ca-a52c-421c-981c-7465f40bc31e', ARRAY['alice', 'bob']);

-- Search for nodes
SELECT * FROM test_search_nodes('ab6751ca-a52c-421c-981c-7465f40bc31e', 'ali');

-- Search for edges
SELECT * FROM test_search_edges('ab6751ca-a52c-421c-981c-7465f40bc31e', 'since');

-- Get the entire graph
SELECT * FROM test_read_graph('ab6751ca-a52c-421c-981c-7465f40bc31e');
```

### Updating Nodes
```sql
-- Update a node (creates a new version)
SELECT test_create_node('ab6751ca-a52c-421c-981c-7465f40bc31e', 'person', 'alice', '{"age": 31, "city": "New York"}'::jsonb);
```

### Deleting Nodes and Edges
```sql
-- Delete a node by ID (first find the node ID)
SELECT test_delete_node(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    (SELECT test_find_node_by_name('ab6751ca-a52c-421c-981c-7465f40bc31e', 'alice'))
);

-- Delete an edge (first find the edge ID)
SELECT test_delete_edge(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    (SELECT edge_id FROM test_find_edges_between('ab6751ca-a52c-421c-981c-7465f40bc31e', 101, 102, 'KNOWS') LIMIT 1)
);
```

### Finding Nodes and Edges
```sql
-- Find a node ID by name
SELECT test_find_node_by_name('ab6751ca-a52c-421c-981c-7465f40bc31e', 'bob');

-- Find edges between nodes
SELECT * FROM test_find_edges_between('ab6751ca-a52c-421c-981c-7465f40bc31e', 101, 102);

-- Get all edges connected to a node with node names
SELECT * FROM test_edges_of('ab6751ca-a52c-421c-981c-7465f40bc31e', 101);
```

### Updating Properties Without Versioning
```sql
-- Update a specific property without creating a new version
SELECT test_update_node_property(
    'ab6751ca-a52c-421c-981c-7465f40bc31e',
    101,
    'active',
    'true'::jsonb
);
```

## Important Notes

1. All functions operate on the concept of "current" records, where `valid_to IS NULL`.
2. Updates to nodes and edges automatically create new versions with incremented version numbers.
3. Properties are merged during updates, with new properties taking precedence.
4. The graph is separated by user_id, allowing multiple isolated graph instances in the same database.
5. The `test_` prefix is for distinguishing test functions from production functions and can be changed if needed.
6. UUIDs with hyphens are automatically converted to use underscores to ensure PostgreSQL compatibility.
7. When referencing tables directly in queries, use the converted format (with underscores instead of hyphens).