/* pgnodemx cgroup v2 subtree regression test */

\pset pager off

DROP EXTENSION IF EXISTS pgnodemx;

CREATE EXTENSION pgnodemx;

-- subtree management should have initialized successfully
SELECT current_setting('pgnodemx.subtree_enabled');

-- set_subtree should move the backend into the named subtree
SELECT set_subtree('pgnodemx_regress');

-- confirm via /proc that the backend process is now in the pgnodemx_regress subtree
COPY (SELECT pg_backend_pid()) TO '/tmp/pgnodemx_test_pid';
\! grep -c '/pgnodemx_regress' /proc/$(tr -d '[:space:]' </tmp/pgnodemx_test_pid)/cgroup

-- cgroup path should reflect the subtree
SELECT count(*) > 0 AS has_cgroup_path FROM cgroup_path();

-- permission check: non-superuser cannot call set_subtree
CREATE USER pgnodemx_subtree_joe;
SET SESSION AUTHORIZATION pgnodemx_subtree_joe;
SELECT set_subtree('pgnodemx_regress');
RESET SESSION AUTHORIZATION;
DROP USER pgnodemx_subtree_joe;

-- ALTER SYSTEM rejects unknown custom GUCs before PG 15; write to auto.conf directly.
COPY (SELECT current_setting('data_directory') || '/postgresql.auto.conf') TO '/tmp/pgnodemx_autoconf';

-- databases_with_subtrees: reconnecting to a listed database assigns its subtree
ALTER SYSTEM SET pgnodemx.databases_with_subtrees = 'contrib_regression';
-- Per-database/role subtree GUCs are not pre-registered; ALTER SYSTEM rejects them before PG 15.
\! printf "database_contrib_regression_session.subtree = 'pgnodemx_db_regress'\n" >> "$(tr -d '[:space:]' < /tmp/pgnodemx_autoconf)"
SELECT pg_reload_conf();
\c contrib_regression
COPY (SELECT pg_backend_pid()) TO '/tmp/pgnodemx_test_pid';
\! grep -c '/pgnodemx_db_regress' /proc/$(tr -d '[:space:]' </tmp/pgnodemx_test_pid)/cgroup
ALTER SYSTEM RESET pgnodemx.databases_with_subtrees;
\! sed -i '/^database_contrib_regression_session\.subtree/d' "$(tr -d '[:space:]' < /tmp/pgnodemx_autoconf)"
SELECT pg_reload_conf();

-- roles_with_subtrees: reconnecting as a listed role assigns its subtree
ALTER SYSTEM SET pgnodemx.roles_with_subtrees = 'postgres';
\! printf "role_postgres_session.subtree = 'pgnodemx_role_regress'\n" >> "$(tr -d '[:space:]' < /tmp/pgnodemx_autoconf)"
SELECT pg_reload_conf();
\c contrib_regression
COPY (SELECT pg_backend_pid()) TO '/tmp/pgnodemx_test_pid';
\! grep -c '/pgnodemx_role_regress' /proc/$(tr -d '[:space:]' </tmp/pgnodemx_test_pid)/cgroup
ALTER SYSTEM RESET pgnodemx.roles_with_subtrees;
\! sed -i '/^role_postgres_session\.subtree/d' "$(tr -d '[:space:]' < /tmp/pgnodemx_autoconf)"
SELECT pg_reload_conf();
