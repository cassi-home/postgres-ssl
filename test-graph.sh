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

# Test user ID
TEST_USER_ID="test-user-123"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print test results
print_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ $2${NC}"
    else
        echo -e "${RED}✗ $2${NC}"
        exit 1
    fi
}

echo "Starting graph function tests..."

# Test 1: Create Graph
echo "Testing test_create_graph..."
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_create_graph('$TEST_USER_ID');
EOF
print_result $? "Create graph"

# Test 2: Create Node
echo "Testing test_create_node..."
NODE_ID=$(psql -t -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_create_node(
    '$TEST_USER_ID',
    'person',
    'John Doe',
    '{"age": 30, "city": "New York"}'::jsonb
);
EOF
)
print_result $? "Create node"

# Test 3: Create Edge
echo "Testing test_create_edge..."
EDGE_ID=$(psql -t -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_create_edge(
    '$TEST_USER_ID',
    $NODE_ID,
    $NODE_ID,
    'knows',
    '{"since": "2020"}'::jsonb
);
EOF
)
print_result $? "Create edge"

# Test 4: Open Nodes
echo "Testing test_open_nodes..."
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_open_nodes('$TEST_USER_ID', ARRAY['person']);
EOF
print_result $? "Open nodes"

# Test 5: Search Nodes
echo "Testing test_search_nodes..."
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_search_nodes('$TEST_USER_ID', 'John');
EOF
print_result $? "Search nodes"

# Test 6: Search Edges
echo "Testing test_search_edges..."
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_search_edges('$TEST_USER_ID', 'knows');
EOF
print_result $? "Search edges"

# Test 7: Read Graph
echo "Testing test_read_graph..."
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
SELECT test_read_graph('$TEST_USER_ID');
EOF
print_result $? "Read graph"

# Cleanup
echo "Cleaning up test data..."
psql -v ON_ERROR_STOP=1 "$PGCONNSTRING" <<EOF
DROP TABLE IF EXISTS graph_${TEST_USER_ID//-/_}_nodes;
DROP TABLE IF EXISTS graph_${TEST_USER_ID//-/_}_edges;
EOF
print_result $? "Cleanup"

echo "All tests completed successfully!"
