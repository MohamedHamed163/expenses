#!/bin/bash
# Drops the per-test schemas the test suite creates in the expenses_test database.
PSQL=${PSQL:-/opt/homebrew/opt/postgresql@17/bin/psql}
$PSQL -d expenses_test -qtA -c "SET client_min_messages = warning; DO \$\$DECLARE s text; BEGIN FOR s IN SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 't\_%' LOOP EXECUTE format('DROP SCHEMA %I CASCADE', s); END LOOP; END\$\$;"
