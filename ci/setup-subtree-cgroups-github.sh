#!/bin/bash
#
# ci/setup-subtree-cgroups-github.sh  --  cgroup v2 subtree setup for GitHub Actions
#
# Usage: setup-subtree-cgroups-github.sh <pg-major-version>
#
# This script is SPECIFIC to the GitHub Actions environment (pgxn/pgxn-tools
# container, --privileged Docker, cgroupns private).  It is NOT a general
# setup script.  See "Running subtree regression tests" in README.md for the
# general prerequisites that any environment must satisfy.
#
# Why this script exists
# ----------------------
# GitHub Actions runs jobs in Docker containers.  Docker's default cgroupns
# mode ("private") makes the container see "/" as its cgroup root, but on the
# host that root is actually a non-root cgroup deep in the host hierarchy.
# The cgroupv2 no-internal-process constraint (NIPC) therefore applies: the
# kernel refuses writes to cgroup.subtree_control on any cgroup that already
# has processes directly inside it, even for root.
#
# Three steps are required to work around this before starting PostgreSQL:
#
#   1. Empty the container-root cgroup by moving all current processes into
#      an init/ sub-cgroup, so the root cgroup itself has no direct members.
#
#   2. Enable the desired controllers on the now-empty root cgroup by writing
#      to /sys/fs/cgroup/cgroup.subtree_control.
#
#   3. Create a postgres/ cgroup, delegate it to the postgres OS user, and
#      start PostgreSQL inside it via a one-shot subshell.  The subshell
#      writes its own PID into postgres/cgroup.procs before exec-ing
#      pg_ctlcluster, so only the PostgreSQL postmaster (and its children)
#      end up in the postgres/ cgroup.  init_default_subtree() then moves
#      the postmaster into postgres/default/, leaving postgres/ empty so
#      that subsequent auth-hook calls can write postgres/cgroup.subtree_control
#      without hitting NIPC.
#
# On a real machine or in a systemd-managed container the right approach is
# entirely different: use systemd's cgroup delegation (Delegate=yes in the
# PostgreSQL service unit, or systemd-run --scope) so that systemd hands a
# proper sub-cgroup to the postmaster at startup.
#
# IMPORTANT: this script must be invoked with "exec bash <script>" from the
# workflow step, NOT as a plain subprocess.  "exec" replaces the step shell
# with this process so that only one shell exists in the root cgroup when the
# drain loop runs; a subprocess invocation leaves the parent step shell behind
# and the root cgroup is never fully drained, causing EBUSY on step 2.
#
# The drain loop (step 1) retries up to 20 times with a short sleep between
# attempts.  This handles a subtle race: the GitHub Actions runner process
# (node) can temporarily reside in a child cgroup while executing a step and
# then migrate back to the root cgroup once the step's subprocess exits.  A
# single-pass scan therefore misses it.  All container processes share the
# same cgroup namespace, so every PID in the root cgroup is movable.

set -euo pipefail

PG=${1:?Usage: $0 <pg-major-version>}

# Controllers to enable.  cpuset requires extra setup in Docker (no cpuset
# root quota is pre-configured), so we restrict to cpu, memory, and io.
CONTROLLERS="+cpu +memory +io"

# Subtrees that the regression test SQL creates/uses.  These are pre-created
# here so their kernel-owned cgroup.procs files exist and can be chowned
# before the server starts (the postgres user must be able to write to them).
TEST_SUBTREES="default pgnodemx_regress pgnodemx_db_regress pgnodemx_role_regress"

# Stop PostgreSQL before touching cgroups.  pg-start runs before this step,
# so postgres processes are already in the root cgroup.  Running processes
# cannot be migrated across cgroupns boundaries, so we must stop them first
# to drain the root cgroup completely before writing cgroup.subtree_control.
pg_ctlcluster "$PG" test stop

# ── Step 1: empty the container-root cgroup (retry until stable) ─────────────
mkdir -p /sys/fs/cgroup/init
remaining=""
for attempt in $(seq 1 20); do
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        echo "$pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    done < /sys/fs/cgroup/cgroup.procs
    remaining=$(tr '\n' ' ' < /sys/fs/cgroup/cgroup.procs)
    remaining="${remaining%"${remaining##*[![:space:]]}"}"   # rtrim
    [ -z "$remaining" ] && break
    echo "drain attempt $attempt: root cgroup still has PIDs: $remaining" >&2
    sleep 0.2
done
if [ -n "$remaining" ]; then
    echo "ERROR: could not drain root cgroup after 20 attempts; remaining PIDs: $remaining" >&2
    exit 1
fi

# ── Step 2: enable controllers on the now-empty root ─────────────────────────
echo "$CONTROLLERS" > /sys/fs/cgroup/cgroup.subtree_control

# ── Step 3: create and delegate the postgres cgroup ──────────────────────────
mkdir -p /sys/fs/cgroup/postgres
chown postgres /sys/fs/cgroup/postgres
chown postgres /sys/fs/cgroup/postgres/cgroup.procs
chown postgres /sys/fs/cgroup/postgres/cgroup.subtree_control

for subtree in $TEST_SUBTREES; do
    mkdir -p /sys/fs/cgroup/postgres/${subtree}
    chown postgres /sys/fs/cgroup/postgres/${subtree}/cgroup.procs
done

# Start PostgreSQL inside the postgres/ cgroup.  The subshell moves itself
# into the cgroup before exec-ing pg_ctlcluster so that only the postmaster
# ends up there.  This shell remains in init/ and never pollutes postgres/.
sh -c "echo \$\$ > /sys/fs/cgroup/postgres/cgroup.procs && exec pg_ctlcluster ${PG} test start" &
wait $!
