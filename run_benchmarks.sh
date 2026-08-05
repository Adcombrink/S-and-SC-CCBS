#!/usr/bin/env bash
#
# Sweeps CCBS over every MAPF instance set found in a folder of subfolders.
#
# Each subfolder of <main_folder> is one instance set and must contain either:
#   - a MovingAI map (*.map) + one or more MovingAI scenarios (*.scen), or
#   - an already-converted map.xml + one or more task *.xml files (as produced
#     by movingai_converter, or as shipped in this repo's Instances/*.zip).
#
# For every subfolder, every connectedness value in [kmin, kmax], and every
# scenario file, CCBS is run starting at 2 agents and incrementing by one
# (taking the first N agents from the scenario, in file order) until CCBS
# fails to find a solution (or the per-run timeout is hit), matching the
# sweep scheme used elsewhere in this repo's benchmarking.
#
# Usage:
#   ./run_benchmarks.sh <main_folder> [options]
#
#   main_folder        folder containing one subfolder per instance set
#
# Options (all optional, may be given as --flag value or --flag=value):
#   --kmin N            minimum connectedness to sweep, 2-5 (default: 2)
#   --kmax N            maximum connectedness to sweep, 2-5 (default: 5)
#   --max-agents N      agent-count cap per scenario (default: no cap)
#   --output PATH       where to write the aggregated CSV
#                        (default: <main_folder>/benchmark_results.csv)
#   --jobs N            number of scenario sweeps (one per subfolder x
#                        connectedness x scenario file) to run in parallel
#                        (default: 1)
#   --config PATH       config.xml template to sweep from (see Config options
#                        in README.md); --kmin/--kmax override its
#                        <connectedness> per run, everything else (including
#                        <timelimit>, which also sizes the external per-run
#                        watchdog) is used as-is (default: Examples/config.xml)
#
# Env overrides:
#   CCBS_BIN, CONVERTER_BIN   paths to the built binaries (auto-detected otherwise)
#   KEEP_LOGS=1               keep the *_log.xml CCBS writes per run (deleted by default)

set -uo pipefail

usage() {
    awk '/^#!/{next} /^#/{print substr($0,3); next} {exit}' "$0" >&2
    exit 1
}

[ $# -ge 1 ] || usage

MAIN_FOLDER=$(cd "$1" 2>/dev/null && pwd) || { echo "Error: no such folder: $1" >&2; exit 1; }
shift

KMIN=2
KMAX=5
MAX_AGENTS=1000000
OUTPUT_CSV=""
JOBS=1
CONFIG_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --kmin=*) KMIN=${1#*=}; shift ;;
        --kmin) KMIN=${2:?--kmin needs a value}; shift 2 ;;
        --kmax=*) KMAX=${1#*=}; shift ;;
        --kmax) KMAX=${2:?--kmax needs a value}; shift 2 ;;
        --max-agents=*) MAX_AGENTS=${1#*=}; shift ;;
        --max-agents) MAX_AGENTS=${2:?--max-agents needs a value}; shift 2 ;;
        --output=*) OUTPUT_CSV=${1#*=}; shift ;;
        --output) OUTPUT_CSV=${2:?--output needs a value}; shift 2 ;;
        --jobs=*) JOBS=${1#*=}; shift ;;
        --jobs) JOBS=${2:?--jobs needs a value}; shift 2 ;;
        --config=*) CONFIG_ARG=${1#*=}; shift ;;
        --config) CONFIG_ARG=${2:?--config needs a value}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Error: unrecognized argument: $1" >&2; usage ;;
    esac
done

[ -n "$OUTPUT_CSV" ] || OUTPUT_CSV="$MAIN_FOLDER/benchmark_results.csv"

case "$KMIN" in ''|*[!0-9]*) echo "Error: --kmin must be an integer, got '$KMIN'" >&2; exit 1 ;; esac
case "$KMAX" in ''|*[!0-9]*) echo "Error: --kmax must be an integer, got '$KMAX'" >&2; exit 1 ;; esac
case "$MAX_AGENTS" in ''|*[!0-9]*) echo "Error: --max-agents must be an integer, got '$MAX_AGENTS'" >&2; exit 1 ;; esac
case "$JOBS" in ''|*[!0-9]*) echo "Error: --jobs must be an integer, got '$JOBS'" >&2; exit 1 ;; esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

find_bin() {
    local name=$1 override=$2
    if [ -n "$override" ]; then
        echo "$override"
        return
    fi
    for candidate in "$SCRIPT_DIR/$name" "$SCRIPT_DIR/build/$name" "$SCRIPT_DIR"/build*/"$name" $(command -v "$name" 2>/dev/null); do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
}

CCBS_BIN=$(find_bin CCBS "${CCBS_BIN:-}")
CONVERTER_BIN=$(find_bin movingai_converter "${CONVERTER_BIN:-}")

[ -n "$CCBS_BIN" ] || { echo "Error: could not find CCBS binary. Build it (cmake . && make CCBS) or set CCBS_BIN." >&2; exit 1; }
[ -n "$CONVERTER_BIN" ] || { echo "Error: could not find movingai_converter binary. Build it (cmake . && make movingai_converter) or set CONVERTER_BIN." >&2; exit 1; }

echo "Using CCBS: $CCBS_BIN"
echo "Using movingai_converter: $CONVERTER_BIN"

if [ -n "$CONFIG_ARG" ]; then
    [ -f "$CONFIG_ARG" ] || { echo "Error: no such config file: $CONFIG_ARG" >&2; exit 1; }
    CONFIG_TEMPLATE=$(cd "$(dirname "$CONFIG_ARG")" && pwd)/$(basename "$CONFIG_ARG")
else
    CONFIG_TEMPLATE="$SCRIPT_DIR/Examples/config.xml"
    [ -f "$CONFIG_TEMPLATE" ] || { echo "Error: config template not found: $CONFIG_TEMPLATE" >&2; exit 1; }
fi
echo "Using config template: $CONFIG_TEMPLATE"

grep -q '<connectedness>' "$CONFIG_TEMPLATE" || echo "Warning: $CONFIG_TEMPLATE has no <connectedness> tag; --kmin/--kmax will have no effect on this config." >&2

# The external per-run watchdog needs a concrete number of seconds, so it's
# read from the config's own <timelimit> (this is the only source of the time
# limit now -- there is no --timelimit flag). Falls back to CCBS's own
# built-in default (30s, see CN_TIMELIMIT in const.h) if the tag is absent,
# matching what CCBS itself would do.
TIMELIMIT=$(sed -n 's/.*<timelimit>[[:space:]]*\([0-9.]*\)[[:space:]]*<\/timelimit>.*/\1/p' "$CONFIG_TEMPLATE" | head -1)
if [ -z "$TIMELIMIT" ]; then
    TIMELIMIT=30
    echo "Warning: $CONFIG_TEMPLATE has no <timelimit> tag; using CCBS's built-in default (${TIMELIMIT}s) for the external watchdog too." >&2
fi
case "$TIMELIMIT" in ''|*[!0-9.]*) echo "Error: <timelimit> in $CONFIG_TEMPLATE must be a positive number, got '$TIMELIMIT'" >&2; exit 1 ;; esac
echo "Using timelimit: ${TIMELIMIT}s (from config)"

# `timeout` is a GNU coreutils tool and isn't shipped with macOS (nor is
# `gtimeout` unless coreutils was brew-installed). Fall back to a manual
# background-process watcher so a genuine CCBS hang still gets killed even
# without either binary available.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
else
    TIMEOUT_BIN=""
    echo "Note: the 'timeout'/'gtimeout' command-line tool isn't installed, so a manual watcher process will be used instead to enforce the config's <timelimit> (${TIMELIMIT}s)." >&2
fi

# Watchdog duration: a little longer than <timelimit> so CCBS's own internal
# timelimit check gets a chance to fire first; float-safe since <timelimit>
# is a config-supplied double (bash arithmetic only handles integers).
WATCHDOG_SECS=$(awk -v t="$TIMELIMIT" 'BEGIN { printf "%.3f", t + 10 }')

# Portable stand-in for `timeout <secs> "$@" > <outfile> 2>&1`.
run_with_timeout() {
    local secs=$1 outfile=$2
    shift 2
    "$@" > "$outfile" 2>&1 &
    local cmd_pid=$!
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null ) &
    local watcher_pid=$!
    wait "$cmd_pid" 2>/dev/null
    local status=$?
    kill "$watcher_pid" 2>/dev/null
    wait "$watcher_pid" 2>/dev/null
    return $status
}

echo "task_name,connectedness,num_agents,solved,runtime,makespan,flowtime,init_cost,check_time,hl_expanded,ll_searches,ll_expanded_avg" > "$OUTPUT_CSV"

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ccbs_bench.XXXXXX")
cleanup() { rm -rf "$WORK_ROOT"; }
trap cleanup EXIT

# Ensure every subfolder is converted to map.xml / task-*.xml before sweeping.
for subfolder in "$MAIN_FOLDER"/*/; do
    [ -d "$subfolder" ] || continue
    subfolder=${subfolder%/}
    if [ ! -f "$subfolder/map.xml" ]; then
        if ls "$subfolder"/*.map >/dev/null 2>&1; then
            echo "Converting $subfolder ..."
            "$CONVERTER_BIN" "$subfolder" "$subfolder" || { echo "Warning: conversion failed for $subfolder, skipping" >&2; }
        else
            echo "Warning: $subfolder has no map.xml and no .map file, skipping" >&2
        fi
    fi
done

# One connectedness config, generated once per k, shared read-only across a
# sweep. <timelimit> is left untouched -- it comes from the config only.
make_config() {
    local k=$1 out=$2
    sed -e "s#<connectedness>[0-9]*</connectedness>#<connectedness>${k}</connectedness>#" \
        "$CONFIG_TEMPLATE" > "$out"
}

# Runs the full increasing-agent-count sweep for one (task file, connectedness)
# pair, appending CSV rows to $3 and stopping at the first unsolved instance.
sweep_task() {
    local map_xml=$1 task_xml=$2 config_xml=$3 k=$4 out_csv=$5 tmp_dir=$6
    local task_name total_agents cap n subset log out solved runtime makespan flowtime init_cost check_time hl ll ll_avg rc

    task_name=$(basename "$task_xml" .xml)
    total_agents=$(grep -c '<agent' "$task_xml")
    cap=$total_agents
    [ "$MAX_AGENTS" -lt "$cap" ] && cap=$MAX_AGENTS

    for ((n = 2; n <= cap; n++)); do
        subset="$tmp_dir/${task_name}_k${k}_n${n}.xml"
        { sed -n '1,2p' "$task_xml"; sed -n "3,$((n + 2))p" "$task_xml"; echo "</root>"; } > "$subset"

        if [ -n "$TIMEOUT_BIN" ]; then
            out=$("$TIMEOUT_BIN" "$WATCHDOG_SECS" "$CCBS_BIN" "$map_xml" "$subset" "$config_xml" 2>&1)
            rc=$?
        else
            local outfile="$tmp_dir/${task_name}_k${k}_n${n}.out"
            run_with_timeout "$WATCHDOG_SECS" "$outfile" "$CCBS_BIN" "$map_xml" "$subset" "$config_xml"
            rc=$?
            out=$(cat "$outfile")
            rm -f "$outfile"
        fi

        solved=$(printf '%s\n' "$out" | sed -n 's/^Solution found: //p')
        runtime=$(printf '%s\n' "$out" | sed -n 's/^Runtime: //p')
        makespan=$(printf '%s\n' "$out" | sed -n 's/^Makespan: //p')
        flowtime=$(printf '%s\n' "$out" | sed -n 's/^Flowtime: //p')
        init_cost=$(printf '%s\n' "$out" | sed -n 's/^Initial Cost: //p')
        check_time=$(printf '%s\n' "$out" | sed -n 's/^Collision Checking Time: //p')
        hl=$(printf '%s\n' "$out" | sed -n 's/^HL expanded: //p')
        ll=$(printf '%s\n' "$out" | sed -n 's/^LL searches: //p')
        ll_avg=$(printf '%s\n' "$out" | sed -n 's/^LL expanded(avg): //p')

        if [ "$rc" = 124 ] || [ -z "$solved" ]; then
            solved=false
        fi

        echo "${task_name},${k},${n},${solved},${runtime},${makespan},${flowtime},${init_cost},${check_time},${hl},${ll},${ll_avg}" >> "$out_csv"

        log="${subset%.xml}_log.xml"
        [ "${KEEP_LOGS:-0}" = 1 ] || rm -f "$log"
        rm -f "$subset"

        if [ "$solved" != "true" ]; then
            break
        fi
    done
}

# Portable concurrency cap (avoids `wait -n`, which needs bash >= 4.3 and
# isn't available in macOS's stock /bin/bash 3.2): keep at most $JOBS
# background sweeps running by blocking on the oldest one once the pool fills.
# One job = the full agent-count sweep for a single (subfolder, connectedness,
# scenario) triple, so scenario files run in parallel with each other.
declare -a job_csvs=()
declare -a pids=()

for subfolder in "$MAIN_FOLDER"/*/; do
    [ -d "$subfolder" ] || continue
    subfolder=${subfolder%/}
    map_xml="$subfolder/map.xml"
    [ -f "$map_xml" ] || continue

    for ((k = KMIN; k <= KMAX; k++)); do
        # One shared, read-only config per (subfolder, connectedness), reused
        # by every scenario job below.
        k_tmp=$(mktemp -d "$WORK_ROOT/k.XXXXXX")
        config_xml="$k_tmp/config.xml"
        make_config "$k" "$config_xml"

        for task_xml in "$subfolder"/*.xml; do
            [ "$(basename "$task_xml")" = "map.xml" ] && continue

            job_tmp=$(mktemp -d "$WORK_ROOT/job.XXXXXX")
            job_csv="$job_tmp/results.csv"
            : > "$job_csv"
            job_csvs+=("$job_csv")

            (
                echo "[$(basename "$subfolder") k=$k] sweeping $(basename "$task_xml") ..."
                sweep_task "$map_xml" "$task_xml" "$config_xml" "$k" "$job_csv" "$job_tmp"
            ) &
            pids+=("$!")

            if [ "${#pids[@]}" -ge "$JOBS" ]; then
                wait "${pids[0]}"
                pids=("${pids[@]:1}")
            fi
        done
    done
done

wait

if [ "${#job_csvs[@]}" -gt 0 ]; then
    for job_csv in "${job_csvs[@]}"; do
        cat "$job_csv" >> "$OUTPUT_CSV"
    done
fi

echo "Done. Results written to $OUTPUT_CSV"
