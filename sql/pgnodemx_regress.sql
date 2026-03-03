/* pgnodemx cgroup v2 regression test */

\pset pager off
\x auto

DROP EXTENSION IF EXISTS pgnodemx;

CREATE EXTENSION pgnodemx;

-- cgroup mode should be 'unified' on cgroup v2
SELECT cgroup_mode();

-- cgroup path should return results
SELECT count(*) > 0 AS has_cgroup_path FROM cgroup_path();

-- cgroup is enabled
SELECT current_setting('pgnodemx.cgroup_enabled');

-- NULL input returns NULL
SELECT cgroup_scalar_bigint(null);

-- should fail (path traversal)
SELECT cgroup_scalar_bigint('bar/../../etc/memory.max');

-- should fail (absolute path)
SELECT cgroup_scalar_bigint('/memory.max');

-- subtree management is disabled by default
SELECT set_subtree('test');

-- permission checks
CREATE USER pgnodemx_joe;
SET SESSION AUTHORIZATION pgnodemx_joe;
SELECT cgroup_scalar_bigint('memory.current');
SELECT set_subtree('test');
RESET SESSION AUTHORIZATION;
DROP USER pgnodemx_joe;

-- memory.current should be a positive integer
SELECT cgroup_scalar_bigint('memory.current') > 0 AS memory_current_positive;

-- cgroup.procs should have at least one process
SELECT count(*) > 0 AS has_procs FROM cgroup_setof_bigint('cgroup.procs');

-- cpu.max is accessible as text
SELECT cgroup_array_text('cpu.max') IS NOT NULL AS cpu_max_not_null;

-- cgroup.controllers should list controllers
SELECT count(*) > 0 AS has_controllers
FROM (SELECT unnest(cgroup_array_text('cgroup.controllers'))) t;

-- memory.stat should have rows
SELECT count(*) > 0 AS has_memory_stat FROM cgroup_setof_kv('memory.stat');

-- cpu.stat should have rows
SELECT count(*) > 0 AS has_cpu_stat FROM cgroup_setof_kv('cpu.stat');

-- PGDATA environment variable should be set
SELECT envvar_text('PGDATA') IS NOT NULL AS pgdata_set;

-- proc functions should return data
SELECT count(*) > 0 AS has_diskstats FROM proc_diskstats();
SELECT count(*) > 0 AS has_mountinfo FROM proc_mountinfo();
SELECT count(*) > 0 AS has_meminfo FROM proc_meminfo();

-- filesystem info should show positive total bytes
SELECT total_bytes > 0 AS fsinfo_has_bytes
FROM fsinfo(current_setting('data_directory'));

-- network stats should have at least one interface
SELECT count(*) > 0 AS has_network FROM proc_network_stats();

-- cpu time values should be non-negative
SELECT "user" >= 0 AND system >= 0 AS cpu_times_valid FROM proc_cputime();

-- load averages should be non-negative
SELECT load1 >= 0 AND load5 >= 0 AS loadavg_valid FROM proc_loadavg();

-- exec_path should return a non-empty string
SELECT length(exec_path()) > 0 AS exec_path_valid;
