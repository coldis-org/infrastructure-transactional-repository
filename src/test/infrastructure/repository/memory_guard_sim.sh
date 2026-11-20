#!/usr/bin/env bash
#
# Docker simulation of the memory guard and the OOM targeting (psql_memory.sh): scenarios S0 to
# S10 of the 7.4.0 plan, each in a fresh container. Manual, on a workstation with Docker (cgroup
# v2); not part of the host tests. Bash, because it runs on the host, not in the image.
#
#   src/test/infrastructure/repository/memory_guard_sim.sh --build .            # build Dockerfile7 here
#   src/test/infrastructure/repository/memory_guard_sim.sh --image <tag> --scenarios S0
#
# Every database container gets --memory=1g --memory-swap=1g (no swap), --cpus=2, a tmpfs at
# /var/lib/postgresql (the data directory lives in memory, charged to the same cgroup), and the
# application role simapp through POSTGRES_DEFAULT_USER. Load comes from a second container on the
# same network (sim/sim_client.sh), so the clients' memory is not charged to the database.
#
# Pressure is reproducible:
#   idle bloat  sessions that set_config() 8 MB pads one after the other, at a set share of the
#               limit per second, then sit idle on an open stdin;
#   active hog  array_agg over generate_series of 10 kB text rows, paced in SQL to a set MB/s. The
#               plan's array_agg of integers is not used: its array doubles, so its last steps are
#               single allocations of half the limit, which no polling guard can see coming.
#
# Checks are locale-proof (the image speaks pt_BR): the oom_kill counter of memory.events, the
# canary session's backend pid, SQLSTATEs (psql VERBOSITY=verbose), pg_stat_database counters,
# and a grep for both "signal 9" and "sinal 9". Guard lines are read in the format of the plan's
# section 8: "MEMORY_GUARD: <LEVEL>: event=<name> key=value ...".
#
# The guard ships in dry-run (decision D2): every scenario that needs it acting sets
# MEMORY_GUARD_MODE=enforce itself.
#
# cgroup files are read from the host (/sys/fs/cgroup/system.slice/docker-<id>.scope) when
# readable, else through docker exec. The host read is preferred: an exec into a container at its
# limit charges a process to that cgroup and can itself become the OOM victim.
#
# S9 (memory.high below memory.max) is not scripted: memory.high of a container's cgroup can only be
# written from the host, as root. To run it by hand during S1:
#   echo $(( 1073741824 * 90 / 100 )) | sudo tee /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.high
#
# Exits 1 when any scenario failed, 2 on a usage or setup error. Every container, network and
# volume it creates carries the label mgsim.run=<run id> and is removed on exit, whatever the exit.

set -u -o pipefail

# Numbers are printed with a decimal point (sleep and awk in the containers read them), whatever
# the host locale.
export LC_ALL=C

SIM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Options.
IMAGE=
BUILD_PATH=
BASELINE_IMAGE=coldis/infrastructure-transactional-repository:7.3.0
REPLICA_IMAGE=
declare -A MAJOR_IMAGE=()
SCENARIOS=S0,S0B,S1,S2,S3,S4,S5,S6,S7,S8,S9,S10
OUT=
KEEP_IMAGES=false
MEMORY=1g
CPUS=2
CGROUP_READ=auto
S3_RATES=3,6,12,25,50,100
S3_HOGS=3
S4_ADJ=100
S7_BACKENDS=2000
S7_TARGET=5000
S7_MEMORY=8g
S7_CPUS=4
S7_WINDOW=30
S10_SECONDS=20
S10_REPEAT=3
S10_CLIENTS=4
S10_SCALE=5
# Medians and guard CPU of S10, per case (a, b, c); set through printf -v and read through ${!name}.
# shellcheck disable=SC2034
S10_a_TPS='' S10_a_P95='' S10_a_ABOVE_CORES='' S10_b_TPS='' S10_b_P95='' S10_b_ABOVE_CORES='' S10_c_TPS='' S10_c_P95='' S10_c_ABOVE_CORES=''

usage() {
	sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
	cat <<-EOF
	Options:
	  --image TAG             image under test (PostgreSQL 18 line)
	  --build PATH            build it from the worktree at PATH (Dockerfile7; also Dockerfile3..6
	                          for S8 and the replica Dockerfile7 for S6, on demand)
	  --baseline-image TAG    image for S0B (default ${BASELINE_IMAGE})
	  --replica-image TAG     replica image for S6 (default: built from --build)
	  --major-image N=TAG     image of PostgreSQL N (15, 16, 17) for S8 (default: built from --build)
	  --scenarios LIST        comma list of S0,S0B,S1,S2,S3,S4,S5,S6,S7,S8,S9,S10
	                          (default: all; S5 runs S5a,S5b,S5cd,S5e, which can be named alone)
	  --out DIR               where logs go (default: a new temporary directory)
	  --memory SIZE           database container limit (default ${MEMORY})
	  --cpus N                database container CPUs (default ${CPUS})
	  --cgroup-read auto|exec read memory.* from the host when possible, or always via docker exec
	  --s3-rates LIST         S3 total growth rates, in % of the limit per second (${S3_RATES})
	  --s3-hogs N             hogs at once in S3 (${S3_HOGS})
	  --s7-backends N         idle backends opened in S7 (${S7_BACKENDS})
	  --s7-target N           backend count S7 extrapolates to (${S7_TARGET})
	  --s7-memory SIZE        S7 container limit (${S7_MEMORY})
	  --s10-seconds N         length of each pgbench run in S10 (${S10_SECONDS})
	  --s10-repeat N          pgbench runs per case below the threshold in S10 (${S10_REPEAT})
	  --keep-images           keep the images this run built
	EOF
}

while [ $# -gt 0 ]
do
	case $1 in
		--image) IMAGE=$2; shift ;;
		--build) BUILD_PATH=$2; shift ;;
		--baseline-image) BASELINE_IMAGE=$2; shift ;;
		--replica-image) REPLICA_IMAGE=$2; shift ;;
		--major-image) MAJOR_IMAGE[${2%%=*}]=${2#*=}; shift ;;
		--scenarios) SCENARIOS=$2; shift ;;
		--out) OUT=$2; shift ;;
		--memory) MEMORY=$2; shift ;;
		--cpus) CPUS=$2; shift ;;
		--cgroup-read) CGROUP_READ=$2; shift ;;
		--s3-rates) S3_RATES=$2; shift ;;
		--s3-hogs) S3_HOGS=$2; shift ;;
		--s7-backends) S7_BACKENDS=$2; shift ;;
		--s7-target) S7_TARGET=$2; shift ;;
		--s7-memory) S7_MEMORY=$2; shift ;;
		--s10-seconds) S10_SECONDS=$2; shift ;;
		--s10-repeat) S10_REPEAT=$2; shift ;;
		--keep-images) KEEP_IMAGES=true ;;
		-h|--help) usage; exit 0 ;;
		*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

# Run identity, users and throwaway passwords (random per run, never written to a file).
RUN_ID=mgsim-$$-$(date +%s)
sim_random() { od -An -tx1 -N12 /dev/urandom | tr -d ' \n'; }
ADMIN_USER=postgres
ADMIN_PW=$(sim_random)
APP_USER=simapp
APP_PW=$(sim_random)
APP_DB=simapp
# pg_hba.conf of the image only lets "replicator" replicate over the network.
REPL_USER=replicator
REPL_PW=$(sim_random)
CHUNK_BYTES=8388608
# Private memory one 8 MB pad really adds to a backend (measured: about 10 MB).
CHUNK_EFFECTIVE_MB=10
SIG9_RE='signal 9|sinal 9'
RECOVERY_RE='recovery mode|modo de recupera|reinitializing|reinicializando|all server processes terminated|todos os processos servidor'

# Defaults of the guard, used when its start line does not say otherwise.
GUARD_IDLE_PERC=85
GUARD_ACTIVE_PERC=92
GUARD_FAST_INTERVAL=0.5
GUARD_MAX_INTERVAL=5
GUARD_TICK_BUDGET_MS=200

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }
now_ms() { date +%s%3N; }

# Results, printed as a table at the end.
RES_IDS=()
RES_STATUS=()
RES_DETAIL=()
record() {
	RES_IDS+=("$1")
	RES_STATUS+=("$2")
	RES_DETAIL+=("$3")
	log "RESULT $1 $2: $3"
}

# Cleanup of everything this run created.
SAMPLER_PIDS=()
BUILT_IMAGES=()
sim_cleanup() {
	local p i
	for p in "${SAMPLER_PIDS[@]+"${SAMPLER_PIDS[@]}"}"
	do
		kill "${p}" 2>/dev/null
	done
	docker ps -aq --filter "label=mgsim.run=${RUN_ID}" | xargs -r docker rm -f -v >/dev/null 2>&1
	docker network ls -q --filter "label=mgsim.run=${RUN_ID}" | xargs -r docker network rm >/dev/null 2>&1
	docker volume ls -q --filter "label=mgsim.run=${RUN_ID}" | xargs -r docker volume rm >/dev/null 2>&1
	if ! ${KEEP_IMAGES}
	then
		for i in "${BUILT_IMAGES[@]+"${BUILT_IMAGES[@]}"}"
		do
			docker image rm "${i}" >/dev/null 2>&1
		done
	fi
	return 0
}
trap sim_cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

# Waits up to $1 seconds for the command after it to succeed, every second.
wait_for() {
	local deadline=$(( $(date +%s) + $1 ))
	shift
	until "$@"
	do
		[ "$(date +%s)" -lt "${deadline}" ] || return 1
		sleep 1
	done
}

# --- Images ------------------------------------------------------------------------------------

# Builds a Dockerfile of the worktree: build_image <tag> <Dockerfile> <context>.
build_image() {
	log "building $1 from $2"
	if docker build -q -f "$2" -t "$1" "$3" > "${OUT}/build-${1//[:\/]/_}.log" 2>&1
	then
		BUILT_IMAGES+=("$1")
		return 0
	fi
	log "build of $1 failed; see ${OUT}/build-${1//[:\/]/_}.log"
	return 1
}

# Image of PostgreSQL $1 for S8 into IMAGE_RESULT, built from the worktree when not given. Not
# called in a subshell: the build is recorded for cleanup and cached.
IMAGE_RESULT=
major_image() {
	local major=$1 file
	if [ -n "${MAJOR_IMAGE[${major}]:-}" ]
	then
		IMAGE_RESULT=${MAJOR_IMAGE[${major}]}
		return 0
	fi
	[ -n "${BUILD_PATH}" ] || return 1
	case ${major} in 14) file=3 ;; 15) file=4 ;; 16) file=5 ;; 17) file=6 ;; *) return 1 ;; esac
	build_image "mgsim-local/repository:${RUN_ID}-pg${major}" \
		"${BUILD_PATH}/src/main/infrastructure/repository/Dockerfile${file}" \
		"${BUILD_PATH}/src/main/infrastructure/repository" || return 1
	MAJOR_IMAGE[${major}]="mgsim-local/repository:${RUN_ID}-pg${major}"
	IMAGE_RESULT=${MAJOR_IMAGE[${major}]}
}

# Replica image for S6 into IMAGE_RESULT: the worktree's replica Dockerfile7 on top of the image
# under test.
replica_image() {
	if [ -n "${REPLICA_IMAGE}" ]
	then
		IMAGE_RESULT=${REPLICA_IMAGE}
		return 0
	fi
	[ -n "${BUILD_PATH}" ] || return 1
	local dir="${BUILD_PATH}/src/main/infrastructure/repository-replica"
	sed "s|^FROM .*|FROM ${IMAGE}|" "${dir}/Dockerfile7" > "${OUT}/Dockerfile.replica"
	build_image "mgsim-local/replica:${RUN_ID}" "${OUT}/Dockerfile.replica" "${dir}" || return 1
	REPLICA_IMAGE="mgsim-local/replica:${RUN_ID}"
	IMAGE_RESULT=${REPLICA_IMAGE}
}

# --- Containers --------------------------------------------------------------------------------

SCN=
NET=
DB=
CL=
SDIR=
CX_HOST=
HOST_PID1=

scn_begin() {
	SCN=$1
	NET="${RUN_ID}-${1,,}"
	DB="${NET}-db"
	CL="${NET}-cl"
	CX_HOST=
	SDIR="${OUT}/$1"
	[ -e "${SDIR}" ] && SDIR="${OUT}/$1-$(date +%s%N)"
	mkdir -p "${SDIR}"
	docker network create --label "mgsim.run=${RUN_ID}" --label "mgsim.scn=${NET}" "${NET}" >/dev/null
	log "--- ${SCN}"
}

# Saves the logs of the scenario's containers, then removes them and their network.
scn_end() {
	local p c
	for p in "${SAMPLER_PIDS[@]+"${SAMPLER_PIDS[@]}"}"
	do
		kill "${p}" 2>/dev/null
	done
	SAMPLER_PIDS=()
	for c in $(docker ps -a --filter "label=mgsim.scn=${NET}" --format '{{.Names}}')
	do
		docker logs "${c}" > "${SDIR}/${c#"${NET}-"}.log" 2>&1
		[ "${c}" = "${CL}" ] && docker exec "${CL}" sh -c 'tail -n 50 /tmp/sim/*.log' > "${SDIR}/client-sessions.log" 2>&1
	done
	docker ps -aq --filter "label=mgsim.scn=${NET}" | xargs -r docker rm -f -v >/dev/null 2>&1
	docker network rm "${NET}" >/dev/null 2>&1
	return 0
}

# Starts a database container: db_run <name> <image> <memory> [NAME=value ...].
db_run() {
	local name=$1 image=$2 mem=$3 e
	shift 3
	local env=()
	for e in "$@"
	do
		env+=(-e "${e}")
	done
	docker run -d --name "${name}" --hostname "${name}" --network "${NET}" \
		--label "mgsim.run=${RUN_ID}" --label "mgsim.scn=${NET}" \
		--memory="${mem}" --memory-swap="${mem}" --cpus="${CPUS}" \
		--tmpfs "/var/lib/postgresql:rw,size=${mem}" \
		-e "POSTGRES_ADMIN_USER=${ADMIN_USER}" -e "POSTGRES_ADMIN_PASSWORD=${ADMIN_PW}" \
		-e "POSTGRES_DEFAULT_USER=${APP_USER}" -e "POSTGRES_DEFAULT_PASSWORD=${APP_PW}" \
		-e "POSTGRES_DEFAULT_DATABASE=${APP_DB}" \
		"${env[@]}" "${image}" >/dev/null
}

# Starts the client container on the image under test.
client_run() {
	docker run -d --name "${CL}" --network "${NET}" \
		--label "mgsim.run=${RUN_ID}" --label "mgsim.scn=${NET}" \
		--ulimit nofile=65536:65536 -v "${SIM_DIR}/sim:/sim:ro" \
		-e "SIM_DB=${APP_DB}" -e "SIM_APP_USER=${APP_USER}" \
		-e "SIM_ADMIN_USER=${ADMIN_USER}" -e "SIM_ADMIN_PW=${ADMIN_PW}" -e "SIM_APP_PW=${APP_PW}" \
		-e "SIM_REPL_USER=${REPL_USER}" -e "SIM_REPL_PW=${REPL_PW}" -e LC_ALL=C \
		--entrypoint sleep "${CLIENT_IMAGE}" infinity >/dev/null
}

# Address of a container on the scenario's network. Clients connect by address, never by name: once
# a container is gone its name stops resolving on the network and the lookup falls through to the
# host's resolver and search domains, which can hand back some other machine.
db_ip() { docker inspect -f "{{with index .NetworkSettings.Networks \"${NET}\"}}{{.IPAddress}}{{end}}" "$1" 2>/dev/null; }

# Client commands, foreground (cx) or detached (cxd), against CX_HOST (an address).
cx() { docker exec -e "SIM_DB_HOST=${CX_HOST}" "${CL}" sh /sim/sim_client.sh "$@"; }
cxd() { docker exec -d -e "SIM_DB_HOST=${CX_HOST}" "${CL}" sh /sim/sim_client.sh "$@"; }
asql() { cx sql "${ADMIN_USER}" "$1" 2>/dev/null; }
client_log() { docker exec "${CL}" cat "/tmp/sim/$1.log" 2>/dev/null; }
# A client session's log has a line matching an ERE: client_has <tag> <regex>.
client_has() { docker exec "${CL}" grep -E "$2" "/tmp/sim/$1.log" >/dev/null 2>&1; }

db_ready() {
	[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ] || return 2
	docker logs "$1" 2>&1 | grep 'Database started and configured' >/dev/null || return 1
	local ip
	ip=$(db_ip "$1")
	[ -n "${ip}" ] && [ "$(CX_HOST=${ip} cx sql "${APP_USER}" 'SELECT 1' 2>/dev/null)" = 1 ]
}

# Brings up the database and the client and starts the memory sampler. Records a FAIL when the
# server does not come up.
sim_up() {
	local image=$1
	shift
	db_run "${DB}" "${image}" "${MEMORY}" "$@" || { record "${SCN}" FAIL "docker run failed"; return 1; }
	client_run || { record "${SCN}" FAIL "client container failed"; return 1; }
	if ! wait_for 240 db_ready "${DB}"
	then
		record "${SCN}" FAIL "server not ready in 240 s (logs in ${SDIR})"
		return 1
	fi
	CX_HOST=$(db_ip "${DB}")
	cg_resolve "${DB}"
	HOST_PID1=$(docker inspect -f '{{.State.Pid}}' "${DB}")
	sampler_start "${DB}" "${SDIR}/memory.tsv"
	guard_settings
	return 0
}

# Running, restart count, OOMKilled flag.
container_state() { docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}}' "$1" 2>/dev/null || echo "gone - -"; }

# --- cgroup ------------------------------------------------------------------------------------

declare -A CG_PATH=()
cg_resolve() {
	local id c
	id=$(docker inspect -f '{{.Id}}' "$1") || return 1
	CG_PATH[$1]="exec"
	[ "${CGROUP_READ}" = exec ] && return 0
	for c in "/sys/fs/cgroup/system.slice/docker-${id}.scope" "/sys/fs/cgroup/docker/${id}"
	do
		if [ -r "${c}/memory.events" ]
		then
			CG_PATH[$1]=${c}
			return 0
		fi
	done
}
cg_cat() {
	[ -n "${CG_PATH[$1]:-}" ] || cg_resolve "$1"
	if [ "${CG_PATH[$1]}" = exec ]
	then
		docker exec "$1" cat "/sys/fs/cgroup/$2"
	else
		cat "${CG_PATH[$1]}/$2"
	fi
}
# oom_kill of memory.events. Once the container is gone its cgroup is too: then 1000000 when Docker
# recorded it as OOM-killed (the kernel killed PID 1, which takes the container down), else -1.
OOM_GONE=1000000
oom_kills() {
	local v
	v=$(cg_cat "$1" memory.events 2>/dev/null | awk '$1 == "oom_kill" { print $2 }')
	if [ -n "${v}" ]
	then
		echo "${v}"
	elif [ "$(docker inspect -f '{{.State.OOMKilled}}' "$1" 2>/dev/null)" = true ]
	then
		echo "${OOM_GONE}"
	else
		echo -1
	fi
}
# The kernel's own account of the kills in a container's cgroup since epoch $2, when the kernel log
# is readable without root (journalctl -k): "pid=<pid> <name> anon=<kB> shmem=<kB> adj=<n>" each.
kernel_victims() {
	local id
	id=$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null) || return 0
	journalctl -k --since "@$2" --no-pager -o cat 2>/dev/null | awk -v scope="docker-${id}.scope" -v pid1="${HOST_PID1:-x}" '
		index($0, "oom-kill:") && index($0, "task_memcg=/system.slice/" scope) { mine = 1; next }
		mine && /Killed process/ {
			match($0, /Killed process [0-9]+ \([^)]*\)/); v = substr($0, RSTART + 15, RLENGTH - 15)
			a = $0; sub(/.*anon-rss:/, "", a); sub(/kB.*/, "", a)
			m = $0; sub(/.*shmem-rss:/, "", m); sub(/kB.*/, "", m)
			j = $0; sub(/.*oom_score_adj:/, "", j); sub(/[^-0-9].*/, "", j)
			split(v, w, " ")
			printf "pid=%s%s anon=%skB shmem=%skB adj=%s; ", v, (w[1] == pid1 ? " [PID 1 of the container]" : ""), a, m, j; mine = 0 }'
}
oom_fmt() { if [ "$1" = "${OOM_GONE}" ]; then echo "container-OOM-killed"; else echo "$1"; fi; }

# "<pct> <used MB> <limit MB>": memory.current less page cache, as the guard reads it.
mem_use() {
	local cur max
	cur=$(cg_cat "$1" memory.current) || return 1
	max=$(cg_cat "$1" memory.max) || return 1
	[ "${max}" != max ] || { echo "0 0 0"; return 0; }
	cg_cat "$1" memory.stat | awk -v cur="${cur}" -v max="${max}" '
		$1 == "active_file" || $1 == "inactive_file" { f += $2 }
		END { u = cur - f; printf "%d %d %d\n", u * 100 / max, u / 1048576, max / 1048576 }'
}

# Samples "<epoch> <pct> <used MB> <limit MB> <oom_kill>" every 0.5 s into a file.
sampler_start() {
	(
		while :
		do
			m=$(mem_use "$1" 2>/dev/null) || break
			o=$(oom_kills "$1")
			echo "$(date +%s.%N | cut -c1-14) ${m} ${o}" >> "$2"
			sleep 0.5
		done
	) &
	SAMPLER_PIDS+=($!)
}
# Highest and lowest percentage sampled since epoch $2 (0: all).
sampled_peak() { awk -v from="${2:-0}" '$1 >= from && $2 > p { p = $2 } END { print p + 0 }' "$1" 2>/dev/null || echo 0; }
sampled_low() { awk -v from="${2:-0}" '$1 >= from && (l == "" || $2 < l) { l = $2 } END { print l + 0 }' "$1" 2>/dev/null || echo 0; }

# --- Server and guard logs -----------------------------------------------------------------------

db_log() { docker logs "$1" 2>&1; }
# Guard lines of one event: guard_events <log file> <event>.
guard_events() { grep -E "MEMORY_GUARD: [A-Z]+: event=$2( |\$)" "$1" || true; }
# Value of key=value in a guard line, quotes removed.
kv() { printf '%s\n' "$1" | sed -nE "s/.* $2=(\"[^\"]*\"|[^ ]*).*/\1/p" | head -n 1 | tr -d '"'; }
count_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l; fi; }

# Reads the thresholds from the guard's start line, when there is one.
guard_settings() {
	local start v
	start=$(db_log "${DB}" | grep -E 'MEMORY_GUARD: [A-Z]+: event=start( |$)' | tail -n 1)
	GUARD_IDLE_PERC=85
	GUARD_ACTIVE_PERC=92
	GUARD_FAST_INTERVAL=0.5
	[ -n "${start}" ] || return 0
	v=$(kv "${start}" idle_perc); [ -n "${v}" ] && GUARD_IDLE_PERC=${v}
	v=$(kv "${start}" active_perc); [ -n "${v}" ] && GUARD_ACTIVE_PERC=${v}
	v=$(kv "${start}" fast_interval); [ -n "${v}" ] && GUARD_FAST_INTERVAL=${v%s}
	v=$(kv "${start}" max_interval); [ -n "${v}" ] && GUARD_MAX_INTERVAL=${v%s}
	v=$(kv "${start}" tick_budget_ms); [ -n "${v}" ] && GUARD_TICK_BUDGET_MS=${v}
	return 0
}

# Pid of the guard: the process running psql_memory_guard.sh whose parent is PID 1 (its ticks are
# subshells with the same command line).
guard_pid() {
	docker exec "${1:-${DB}}" sh -c 'for d in /proc/[0-9]*; do grep -q psql_memory_guard "$d/cmdline" 2>/dev/null || continue; set -- $(cat "$d/stat" 2>/dev/null); [ "$4" = 1 ] && echo "${d#/proc/}"; done' 2>/dev/null | head -n 1
}
# Alive and not a zombie.
pid_alive() { [ -n "$2" ] && docker exec "$1" sh -c "s=\$(cut -d' ' -f3 /proc/$2/stat 2>/dev/null) && [ -n \"\$s\" ] && [ \"\$s\" != Z ]" 2>/dev/null; }
# CPU of the guard and of its reaped children (its ticks), in ms.
guard_cpu_ms() {
	[ -n "$2" ] || { echo 0; return 0; }
	docker exec "$1" sh -c "awk -v hz=\$(getconf CLK_TCK) '{ print int((\$14 + \$15 + \$16 + \$17) * 1000 / hz) }' /proc/$2/stat" 2>/dev/null || echo 0
}

# --- Load --------------------------------------------------------------------------------------

# Canary: "<distinct pids> <first pid> <last epoch> <exited 0/1>".
canary_state() {
	client_log canary | awk -F '|' '
		$1 == "canary" { if (!($2 in s)) { s[$2] = 1; n++; if (first == "") first = $2 }; last = $3 }
		/^EXIT/ { ex = 1 }
		END { printf "%d %s %d %d\n", n, (first == "" ? "-" : first), last, ex }'
}
# Canary kept one backend and is still reporting.
canary_ok() {
	local n first last ex
	read -r n first last ex <<< "$(canary_state)"
	[ "${n}" = 1 ] && [ "${ex}" = 0 ] && [ $(( $(date +%s) - last )) -lt 6 ]
}
canary_start() { cxd canary; wait_for 15 client_has canary '^canary'; }

# Number of client-backend slots left for the application role.
app_slots() {
	asql "SELECT current_setting('max_connections')::int - current_setting('superuser_reserved_connections')::int
		- coalesce(nullif(current_setting('reserved_connections', true), '')::int, 0)
		- (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend')::int - 1"
}

# Idle bloat: ramp <rate % of limit per s> <target % of limit> <stop: oom|action|none> <tag>.
# Opens as many application sessions as there are slots, each padding its share of the target in
# 8 MB steps; the next session starts when the previous one is done. Stops early on an OOM kill
# (oom) or on the guard's first action (action).
ramp() {
	local rate=$1 target=$2 stop=$3 tag=$4
	local pct used limit slots chunks gap step_ms oom0 i deadline
	read -r pct used limit <<< "$(mem_use "${DB}")"
	slots=$(app_slots)
	[ -n "${slots}" ] && [ "${slots}" -gt 0 ] || { log "ramp: no free slot"; return 1; }
	chunks=$(( (target * limit / 100 - used + slots * CHUNK_EFFECTIVE_MB - 1) / (slots * CHUNK_EFFECTIVE_MB) ))
	[ "${chunks}" -ge 1 ] || chunks=1
	gap=$(awk -v mb="${CHUNK_EFFECTIVE_MB}" -v r="${rate}" -v l="${limit}" 'BEGIN { printf "%.3f", mb / (r * l / 100) }')
	step_ms=$(awk -v g="${gap}" -v c="${chunks}" 'BEGIN { printf "%d", g * c * 1000 }')
	log "ramp: from ${pct}% (${used}/${limit} MB) to ${target}%: ${slots} sessions x ${chunks} pads of 8 MB, one every ${gap} s"
	oom0=$(oom_kills "${DB}")
	for i in $(seq 1 "${slots}")
	do
		cxd pad "${tag}${i}" "${APP_USER}" "${chunks}" "${CHUNK_BYTES}" "${gap}"
		deadline=$(( $(now_ms) + step_ms ))
		while [ "$(now_ms)" -lt "${deadline}" ]
		do
			[ "$(docker inspect -f '{{.State.Running}}' "${DB}" 2>/dev/null)" = true ] || { log "ramp: container stopped"; return 0; }
			case ${stop} in
				oom) [ "$(oom_kills "${DB}")" -gt "${oom0}" ] && return 0 ;;
				action) db_log "${DB}" | grep -E 'MEMORY_GUARD: [A-Z]+: event=action ' >/dev/null && return 0 ;;
			esac
			sleep 0.5
		done
	done
	return 0
}

# Pads as USER up to TARGET % of the limit: pad_to <user> <target> <tag>. A pad adds 8 to 10 MB
# depending on the role and the allocator, so it estimates low and adds sessions (<tag>, <tag>2, ...)
# until the target is reached, four at most.
pad_to() {
	local pct used limit chunks round tag
	for round in 1 2 3 4
	do
		read -r pct used limit <<< "$(mem_use "${DB}")"
		[ "${pct}" -lt "$2" ] || return 0
		chunks=$(( ($2 * limit / 100 - used) / 8 ))
		[ "${chunks}" -ge 1 ] || chunks=1
		tag=$3
		[ "${round}" = 1 ] || tag="$3${round}"
		log "pad_to: ${1} from ${pct}% to ${2}%: ${chunks} pads of 8 MB (${tag})"
		cxd pad "${tag}" "$1" "${chunks}" "${CHUNK_BYTES}" 0.3
		wait_for $(( chunks + 30 )) client_has "${tag}" '^(padded|EXIT)' || return 1
		client_has "${tag}" '^EXIT' && return 1
		sleep 1
	done
}

# The first boot runs on initdb's pg_hba.conf (the image's own is only put in place from the second
# start on), which has no network replication line: adds the image's.
allow_replication() {
	docker exec "$1" sh -c 'grep -q "^host[[:space:]]*replication[[:space:]]*replicator" "${PGDATA}/pg_hba.conf" || echo "host replication replicator 0.0.0.0/0 scram-sha-256" >> "${PGDATA}/pg_hba.conf"' \
		&& asql 'SELECT pg_reload_conf()' >/dev/null
}

# Backend pid of a client session, from its log (first pid it printed).
session_pid() { client_log "$1" | awk -F '|' '$1 == "pad" || $1 == "before" || $1 == "padded" { print $2; exit }'; }

hog_done() { client_has "$1" '^EXIT'; }
oom_rose() { [ "$(oom_kills "${DB}")" -gt "$1" ]; }
use_below() { local p; read -r p _ <<< "$(mem_use "${DB}")"; [ "${p}" -lt "$1" ]; }
wal_sender_attached() { [ -n "$(asql 'SELECT pid FROM pg_stat_replication')" ]; }
standby_serving() { [ "$(cx sql "${APP_USER}" 'SELECT pg_is_in_recovery()' 2>/dev/null)" = t ]; }
app_backends_at_least() { [ "$(asql "SELECT count(*) >= $1 FROM pg_stat_activity WHERE usename = '${APP_USER}'")" = t ]; }

# --- Scenarios ---------------------------------------------------------------------------------

# S0 / S0B: guard and targeting off, idle bloat to the limit. The kernel kills, PostgreSQL runs
# crash recovery, the container survives.
s0() {
	local image=$1 oom0 oom1 group sig9 recov n first last ex state probes t0
	t0=$(date +%s)
	sim_up "${image}" MEMORY_GUARD_ENABLED=false OOM_TARGETING_ENABLED=false || return 0
	oom0=$(oom_kills "${DB}")
	group=$(cg_cat "${DB}" memory.oom.group)
	canary_start
	ramp 3 130 oom pad
	wait_for 30 oom_rose "${oom0}" || true
	# Reconnects while the server recovers.
	probes=
	if [ "$(docker inspect -f '{{.State.Running}}' "${DB}")" = true ]
	then
		probes=$(for _ in $(seq 1 20); do cx sql "${APP_USER}" "SELECT 'up'" 2>&1 | head -n 2; sleep 0.5; done)
	fi
	printf '%s\n' "${probes}" > "${SDIR}/reconnects.txt"
	sleep 2
	oom1=$(oom_kills "${DB}")
	db_log "${DB}" > "${SDIR}/db.log"
	sig9=$(grep -E "${SIG9_RE}" "${SDIR}/db.log" | head -n 1)
	recov=$(grep -hE "${RECOVERY_RE}" "${SDIR}/db.log" "${SDIR}/reconnects.txt" | head -n 1)
	read -r n first last ex <<< "$(canary_state)"
	state=$(container_state "${DB}")
	local fails=()
	[ "${oom1}" -gt "${oom0}" ] || fails+=("oom_kill did not rise")
	[ -n "${sig9}" ] || fails+=("no signal 9 line")
	[ "${ex}" = 1 ] || [ "${n}" -gt 1 ] || fails+=("canary not dropped")
	[ -n "${recov}" ] || fails+=("no recovery seen")
	[ "${state%% *}" = true ] || fails+=("container not running")
	[ "$(echo "${state}" | cut -d' ' -f2)" = 0 ] || fails+=("container restarted")
	local detail
	detail="image=${image} oom_kill ${oom0}->$(oom_fmt "${oom1}"); exit code $(docker inspect -f '{{.State.ExitCode}}' "${DB}"); oom.group=${group}; kernel killed: $(kernel_victims "${DB}" "${t0}"); peak=$(sampled_peak "${SDIR}/memory.tsv")%; canary pids=${n} exited=${ex}; state(running restarts oomkilled)=${state}; signal9: ${sig9:-none}; recovery: ${recov:-none}"
	if [ ${#fails[@]} -eq 0 ]; then record "${SCN}" PASS "${detail}"; else record "${SCN}" FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S1: guard enforcing, idle bloat at 3% of the limit per second.
s1() {
	local oom0 oom1 actions bad n peak final
	sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce || return 0
	oom0=$(oom_kills "${DB}")
	canary_start
	ramp 3 130 none pad
	wait_for 30 use_below "${GUARD_IDLE_PERC}" || true
	read -r final _ <<< "$(mem_use "${DB}")"
	oom1=$(oom_kills "${DB}")
	db_log "${DB}" > "${SDIR}/db.log"
	actions=$(guard_events "${SDIR}/db.log" action)
	n=$(count_lines "${actions}")
	bad=$(printf '%s\n' "${actions}" | grep -v '^$' | grep -cvE ' action=terminate( |$).* stage=idle( |$)| stage=idle( |$).* action=terminate( |$)')
	peak=$(sampled_peak "${SDIR}/memory.tsv")
	local fails=()
	[ "${oom1}" = "${oom0}" ] || fails+=("oom_kill ${oom0}->${oom1}")
	grep -qE "${SIG9_RE}" "${SDIR}/db.log" && fails+=("signal 9 line")
	[ "${n}" -ge 1 ] || fails+=("no action line")
	[ "${bad}" = 0 ] || fails+=("${bad} action line(s) other than terminate at stage idle")
	canary_ok || fails+=("canary lost its backend ($(canary_state))")
	[ "${final}" -lt "${GUARD_IDLE_PERC}" ] || fails+=("use still ${final}%")
	[ "${peak}" -ge "${GUARD_IDLE_PERC}" ] || fails+=("pressure never reached ${GUARD_IDLE_PERC}% (peak ${peak}%)")
	local detail
	detail="actions=${n} peak=${peak}% final=${final}% oom_kill ${oom0}->${oom1}"
	if [ ${#fails[@]} -eq 0 ]; then record S1 PASS "${detail}"; else record S1 FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S2: guard enforcing, one active hog as the application role at 3% of the limit per second.
s2() {
	local oom0 oom1 limit rate rows hlog before after cancels terms
	sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce || return 0
	oom0=$(oom_kills "${DB}")
	canary_start
	read -r _ _ limit <<< "$(mem_use "${DB}")"
	rate=$(( limit * 3 / 100 ))
	rows=$(( limit * 2 * 1048576 / 10240 ))
	log "hog: ${rate} MB/s, ${rows} rows"
	cxd hog hog "${APP_USER}" "${rate}" "${rows}"
	wait_for 180 hog_done hog || true
	sleep 2
	oom1=$(oom_kills "${DB}")
	db_log "${DB}" > "${SDIR}/db.log"
	hlog=$(client_log hog)
	printf '%s\n' "${hlog}" > "${SDIR}/hog.txt"
	before=$(printf '%s\n' "${hlog}" | awk -F '|' '$1 == "before" { print $2 }')
	after=$(printf '%s\n' "${hlog}" | awk -F '|' '$1 == "after" { print $2 }')
	cancels=$(guard_events "${SDIR}/db.log" action | grep -E ' action=cancel( |$)')
	terms=$(guard_events "${SDIR}/db.log" action | grep -E ' action=terminate( |$)' | grep -E " pid=${before:-none}( |$)")
	local fails=()
	[ -n "${cancels}" ] || fails+=("no cancel line")
	printf '%s\n' "${hlog}" | grep '57014' >/dev/null || fails+=("client did not get SQLSTATE 57014")
	[ -n "${before}" ] && [ "${before}" = "${after}" ] || fails+=("hog session did not survive (before=${before:-none} after=${after:-none})")
	[ "${oom1}" = "${oom0}" ] || fails+=("oom_kill ${oom0}->${oom1}")
	canary_ok || fails+=("canary lost its backend")
	local detail
	detail="cancel lines=$(count_lines "${cancels}") terminate lines for hog=$(count_lines "${terms}") peak=$(sampled_peak "${SDIR}/memory.tsv")% oom_kill ${oom0}->${oom1}"
	if [ ${#fails[@]} -eq 0 ]; then record S2 PASS "${detail}"; else record S2 FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S3: several hogs at once, the total rate swept upward, a fresh container per rate. Measures the
# highest rate the guard withstands at its fast interval.
s3() {
	local rate best=none lost=none first=true r limit mb rows h oom0 oom1 ok results=""
	for r in ${S3_RATES//,/ }
	do
		scn_begin "S3-${r}"
		if ! sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce
		then
			scn_end
			break
		fi
		oom0=$(oom_kills "${DB}")
		read -r _ _ limit <<< "$(mem_use "${DB}")"
		mb=$(( limit * r / 100 / S3_HOGS ))
		[ "${mb}" -ge 1 ] || mb=1
		rows=$(( limit * 2 * 1048576 / 10240 ))
		for h in $(seq 1 "${S3_HOGS}")
		do
			cxd hog "hog${h}" "${APP_USER}" "${mb}" "${rows}"
		done
		for h in $(seq 1 "${S3_HOGS}")
		do
			wait_for 240 hog_done "hog${h}" || true
		done
		sleep 2
		oom1=$(oom_kills "${DB}")
		db_log "${DB}" > "${SDIR}/db.log"
		ok=true
		[ "${oom1}" = "${oom0}" ] || ok=false
		grep -qE "${SIG9_RE}" "${SDIR}/db.log" && ok=false
		results="${results} ${r}%/s=$(${ok} && echo held || echo lost)(peak $(sampled_peak "${SDIR}/memory.tsv")%,actions $(count_lines "$(guard_events "${SDIR}/db.log" action)"))"
		scn_end
		if ${ok}
		then
			best="${r}%/s ($(( limit * r / 100 )) MB/s)"
		else
			lost="${r}%/s"
			${first} && { SCN=S3; record S3 FAIL "lowest rate lost:${results}"; return 0; }
			break
		fi
		first=false
	done
	SCN=S3
	if [ "${best}" = none ]
	then
		record S3 FAIL "nothing measured:${results}"
	else
		record S3 PASS "highest rate withstood with ${S3_HOGS} hogs at fast interval ${GUARD_FAST_INTERVAL}s: ${best}; first lost: ${lost};${results}"
	fi
}

# S4: guard off, targeting on: boot lines, scores, and a kernel kill that spares PID 1.
s4() {
	local boot pm_adj want_pm children bad nchild oom0 oom1 sig9 victim state recov t0
	t0=$(date +%s)
	sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=false OOM_TARGETING_ENABLED=true "OOM_CHILD_SCORE_ADJ=${S4_ADJ}" || return 0
	boot=$(db_log "${DB}" | grep -E 'MEMORY_GUARD: [A-Z]+: event=oom_target( |$)' | head -n 1)
	pm_adj=$(docker exec "${DB}" cat /proc/1/oom_score_adj)
	want_pm=$(docker inspect -f '{{.HostConfig.OomScoreAdj}}' "${DB}")
	children=$(docker exec "${DB}" sh -c 'for d in /proc/[0-9]*; do [ "$(cat "$d/comm" 2>/dev/null)" = postgres ] || continue; set -- $(cat "$d/stat" 2>/dev/null); [ "$4" = 1 ] && echo "${d#/proc/} $(cat "$d/oom_score_adj")"; done')
	printf '%s\n' "${children}" > "${SDIR}/children.txt"
	nchild=$(count_lines "${children}")
	bad=$(printf '%s\n' "${children}" | awk -v want="${S4_ADJ}" 'NF == 2 && $2 != want' | wc -l)
	oom0=$(oom_kills "${DB}")
	canary_start
	ramp 3 130 oom pad
	sleep 5
	oom1=$(oom_kills "${DB}")
	db_log "${DB}" > "${SDIR}/db.log"
	sig9=$(grep -E "${SIG9_RE}" "${SDIR}/db.log" | head -n 1)
	victim=$(printf '%s\n' "${sig9}" | sed -nE 's/.*PID ([0-9]+).*/\1/p')
	recov=$(grep -E "${RECOVERY_RE}" "${SDIR}/db.log" | head -n 1)
	state=$(container_state "${DB}")
	local fails=()
	[ -n "${boot}" ] && [ "$(kv "${boot}" state)" = on ] || fails+=("no event=oom_target state=on boot line")
	[ "${pm_adj}" = "${want_pm}" ] || fails+=("PID 1 oom_score_adj ${pm_adj}, expected ${want_pm}")
	[ "${nchild}" -gt 0 ] && [ "${bad}" = 0 ] || fails+=("${bad} of ${nchild} server processes not at ${S4_ADJ}")
	[ "${oom1}" -gt "${oom0}" ] || fails+=("no OOM kill")
	[ -n "${victim}" ] && [ "${victim}" != 1 ] || fails+=("victim not identified or PID 1")
	[ "${state%% *}" = true ] || fails+=("container not running")
	[ -n "${recov}" ] || fails+=("no crash recovery seen")
	local detail
	detail="PID1 adj=${pm_adj}; children=${nchild} bad=${bad}; oom_kill ${oom0}->$(oom_fmt "${oom1}"); victim pid=${victim:-none}; kernel killed: $(kernel_victims "${DB}" "${t0}"); state=${state}; boot: ${boot:-none}"
	if [ ${#fails[@]} -eq 0 ]; then record S4 PASS "${detail}"; else record S4 FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S5a and S5b: a signal to the guard. TERM must leave the server alone; KILL is recorded.
s5_signal() {
	local sig=$1 gp since lines restarted
	sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce || return 0
	canary_start
	gp=$(guard_pid)
	[ -n "${gp}" ] || { record "${SCN}" FAIL "guard process not found"; return 0; }
	since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	docker exec "${DB}" sh -c "kill -${sig} ${gp}"
	sleep 6
	docker logs --since "${since}" "${DB}" > "${SDIR}/after-signal.log" 2>&1
	lines=$(grep -E "PID ${gp}[^0-9]|${SIG9_RE}|${RECOVERY_RE}" "${SDIR}/after-signal.log" | head -n 5 | tr '\n' ' ')
	restarted=no
	grep -qE "${RECOVERY_RE}" "${SDIR}/after-signal.log" && restarted=yes
	canary_ok || restarted=yes
	if [ "${sig}" = TERM ]
	then
		local fails=()
		pid_alive "${DB}" "${gp}" && fails+=("guard still running")
		[ "${restarted}" = no ] || fails+=("server reacted: sessions restarted")
		local detail="guard pid ${gp}; server lines: ${lines:-none}"
		if [ ${#fails[@]} -eq 0 ]; then record "${SCN}" PASS "${detail}"; else record "${SCN}" FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
	else
		record "${SCN}" INFO "KILL to the guard: sessions restarted=${restarted}; canary=$(canary_state); server lines: ${lines:-none}"
	fi
}

# S5cd: a superuser holding memory past the active threshold and a WAL sender: never signalled.
s5_protected() {
	local oom0 oom1 ws ws_after su su_alive hits peak
	sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce \
		"POSTGRES_REPLICATOR_USER=${REPL_USER}" "POSTGRES_REPLICATOR_PASSWORD=${REPL_PW}" || return 0
	oom0=$(oom_kills "${DB}")
	canary_start
	allow_replication "${DB}"
	cxd receivewal
	wait_for 30 wal_sender_attached || true
	ws=$(asql 'SELECT pid FROM pg_stat_replication LIMIT 1')
	pad_to "${ADMIN_USER}" $(( GUARD_ACTIVE_PERC + 2 )) su
	sleep 10
	su=$(session_pid su)
	su_alive=$(asql "SELECT count(*) FROM pg_stat_activity WHERE pid = ${su:-0}")
	ws_after=$(asql 'SELECT pid FROM pg_stat_replication LIMIT 1')
	oom1=$(oom_kills "${DB}")
	db_log "${DB}" > "${SDIR}/db.log"
	hits=$(guard_events "${SDIR}/db.log" action | grep -cE " pid=(${su:-x}|${ws:-x})( |$)")
	peak=$(sampled_peak "${SDIR}/memory.tsv")
	local fails=()
	[ -n "${ws}" ] || fails+=("no WAL sender attached")
	[ -n "${su}" ] && [ "${su_alive}" = 1 ] || fails+=("superuser session gone")
	[ "${ws}" = "${ws_after}" ] || fails+=("WAL sender changed ${ws:-none}->${ws_after:-none}")
	[ "${hits}" = 0 ] || fails+=("${hits} action line(s) name them")
	[ "${oom1}" = "${oom0}" ] || fails+=("oom_kill ${oom0}->${oom1}")
	[ "${peak}" -ge "${GUARD_IDLE_PERC}" ] || fails+=("pressure never reached ${GUARD_IDLE_PERC}% (peak ${peak}%)")
	local detail
	detail="superuser pid=${su:-none} walsender pid=${ws:-none} peak=${peak}% no_candidate lines=$(count_lines "$(guard_events "${SDIR}/db.log" no_candidate)")"
	if [ ${#fails[@]} -eq 0 ]; then record S5cd PASS "${detail}"; else record S5cd FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S5e: the server crash-restarts under the guard (a backend killed by signal 9). With the idle
# threshold at 1% the guard queries on every tick, so it meets the recovery.
s5_restart() {
	local gp gp_after victim since failed
	sim_up "${IMAGE}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce MEMORY_GUARD_IDLE_PERC=1 || return 0
	gp=$(guard_pid)
	[ -n "${gp}" ] || { record S5e FAIL "guard process not found"; return 0; }
	cxd pad victim "${APP_USER}" 1 1024 0.1
	wait_for 15 client_has victim '^padded' || true
	victim=$(session_pid victim)
	since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	[ -n "${victim}" ] && docker exec "${DB}" sh -c "kill -KILL ${victim}"
	sleep 20
	docker logs --since "${since}" "${DB}" > "${SDIR}/after-crash.log" 2>&1
	gp_after=$(guard_pid)
	failed=$(guard_events "${SDIR}/after-crash.log" psql_failed | wc -l)
	local fails=()
	[ -n "${victim}" ] || fails+=("no victim session")
	grep -qE "${SIG9_RE}" "${SDIR}/after-crash.log" || fails+=("server did not see the kill")
	[ "${gp_after}" = "${gp}" ] && pid_alive "${DB}" "${gp}" || fails+=("guard gone after the restart (${gp} -> ${gp_after:-none})")
	[ "${failed}" -le 2 ] || fails+=("${failed} psql_failed lines in 20 s, not throttled")
	local detail
	detail="guard pid ${gp} -> ${gp_after:-none}; psql_failed lines=${failed}"
	if [ ${#fails[@]} -eq 0 ]; then record S5e PASS "${detail}"; else record S5e FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S6: replica built on the image under test; a read hog on the standby is ended, replay goes on.
# The primary gets the same limit: a standby takes its primary's lock table size, and one smaller
# than its primary does not start under the tuner's reserve.
s6() {
	local rimage rep oom0 oom1 limit rate rows lsn caught acts
	replica_image || { record S6 SKIP "no replica image (give --replica-image or --build)"; return 0; }
	rimage=${IMAGE_RESULT}
	db_run "${DB}" "${IMAGE}" "${MEMORY}" MEMORY_GUARD_ENABLED=false "POSTGRES_REPLICATOR_USER=${REPL_USER}" "POSTGRES_REPLICATOR_PASSWORD=${REPL_PW}" || { record S6 FAIL "primary did not start"; return 0; }
	client_run
	wait_for 240 db_ready "${DB}" || { record S6 FAIL "primary not ready"; return 0; }
	local primary_ip
	primary_ip=$(db_ip "${DB}")
	CX_HOST=${primary_ip}
	allow_replication "${DB}"
	cxd writer
	rep="${NET}-replica"
	db_run "${rep}" "${rimage}" "${MEMORY}" "COPY_ENDPOINT=${primary_ip}" COPY_PORT=5432 "MASTER_ENDPOINT=${primary_ip}" \
		"POSTGRES_REPLICATOR_USER=${REPL_USER}" "POSTGRES_REPLICATOR_PASSWORD=${REPL_PW}" REPLICATION_SLOT_NAME=simslot \
		MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce || { record S6 FAIL "replica did not start"; return 0; }
	sleep 5
	CX_HOST=$(db_ip "${rep}")
	wait_for 300 standby_serving || { record S6 FAIL "replica not serving reads in 300 s"; return 0; }
	cg_resolve "${rep}"
	sampler_start "${rep}" "${SDIR}/memory.tsv"
	oom0=$(oom_kills "${rep}")
	read -r _ _ limit <<< "$(mem_use "${rep}")"
	rate=$(( limit * 3 / 100 ))
	rows=$(( limit * 2 * 1048576 / 10240 ))
	cxd hog hog "${APP_USER}" "${rate}" "${rows}"
	wait_for 180 hog_done hog || true
	lsn=$(CX_HOST=${primary_ip} asql 'SELECT pg_current_wal_lsn()')
	sleep 5
	caught=$(asql "SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '${lsn}') >= 0")
	oom1=$(oom_kills "${rep}")
	db_log "${rep}" > "${SDIR}/replica-db.log"
	acts=$(guard_events "${SDIR}/replica-db.log" action | grep -E " pid=$(session_pid hog)( |$)")
	local fails=()
	[ -n "${acts}" ] || fails+=("no action line on the hog")
	client_log hog | grep -E '57014|57P01' >/dev/null || fails+=("hog not cancelled or terminated")
	[ "${caught}" = t ] || fails+=("replay did not reach the primary's ${lsn}")
	[ "${oom1}" = "${oom0}" ] || fails+=("oom_kill ${oom0}->${oom1}")
	local detail
	detail="actions on hog=$(count_lines "${acts}") replay caught up=${caught:-unknown} peak=$(sampled_peak "${SDIR}/memory.tsv")% oom_kill ${oom0}->${oom1}"
	if [ ${#fails[@]} -eq 0 ]; then record S6 PASS "${detail}"; else record S6 FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S7: thousands of idle backends, the guard scanning on every tick with nothing eligible (idle
# threshold at 1%). Tick cost from pg_stat_database (the guard's own sessions, database postgres)
# and from the guard's CPU; checks the self-throttling and the nice level.
s7() {
	local conns n gp nice io s0 s1 t0 t1 c0 c1 ticks interval sess_ms cpu_ms work extrap cores slow
	conns=$(( S7_BACKENDS + 60 ))
	local saved_cpus=${CPUS}
	CPUS=${S7_CPUS}
	db_run "${DB}" "${IMAGE}" "${S7_MEMORY}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce MEMORY_GUARD_IDLE_PERC=1 \
		"MAX_CONNECTIONS=${conns}" "MAX_CONNECTIONS_MIN=${conns}" CONNECTION_MEMORY=2048 || { CPUS=${saved_cpus}; record S7 FAIL "docker run failed"; return 0; }
	CPUS=${saved_cpus}
	client_run
	wait_for 300 db_ready "${DB}" || { record S7 FAIL "server not ready"; return 0; }
	CX_HOST=$(db_ip "${DB}")
	cg_resolve "${DB}"
	sampler_start "${DB}" "${SDIR}/memory.tsv"
	guard_settings
	cxd idle "${S7_BACKENDS}" 3600
	wait_for 600 app_backends_at_least "${S7_BACKENDS}" || true
	n=$(asql "SELECT count(*) FROM pg_stat_activity WHERE usename = '${APP_USER}'")
	gp=$(guard_pid)
	[ -n "${gp}" ] || { record S7 FAIL "guard process not found (backends=${n})"; return 0; }
	nice=$(docker exec "${DB}" sh -c "cut -d' ' -f19 /proc/${gp}/stat")
	io=$(docker exec "${DB}" ionice -p "${gp}" 2>/dev/null || echo unknown)
	sleep 5
	read -r s0 t0 <<< "$(asql "SELECT sessions, session_time::bigint FROM pg_stat_database WHERE datname = 'postgres'" | tr '|' ' ')"
	c0=$(guard_cpu_ms "${DB}" "${gp}")
	sleep "${S7_WINDOW}"
	read -r s1 t1 <<< "$(asql "SELECT sessions, session_time::bigint FROM pg_stat_database WHERE datname = 'postgres'" | tr '|' ' ')"
	c1=$(guard_cpu_ms "${DB}" "${gp}")
	db_log "${DB}" > "${SDIR}/db.log"
	ticks=$(( ${s1:-0} - ${s0:-0} ))
	slow=$(guard_events "${SDIR}/db.log" slow_tick | while read -r l; do kv "${l}" tick_ms; done | sort -n | tail -n 1)
	if [ "${ticks}" -le 0 ]
	then
		record S7 FAIL "guard opened no session in ${S7_WINDOW} s with ${n} backends (not scanning?); nice=${nice} ionice=${io}"
		return 0
	fi
	read -r interval sess_ms cpu_ms cores <<< "$(awk -v w="${S7_WINDOW}" -v t="${ticks}" -v st=$(( ${t1:-0} - ${t0:-0} )) -v c=$(( c1 - c0 )) \
		'BEGIN { printf "%.3f %.1f %.1f %.3f\n", w / t, st / t, c / t, c / (w * 1000) }')"
	work=$(awk -v a="${sess_ms}" -v b="${cpu_ms}" -v s="${slow:-0}" 'BEGIN { m = a; if (b > m) m = b; if (s > m) m = s; printf "%.1f", m }')
	extrap=$(awk -v w="${work}" -v n="${n}" -v t="${S7_TARGET}" 'BEGIN { printf "%.1f", w * t / (n > 0 ? n : 1) }')
	local fails=()
	awk -v e="${extrap}" -v f="${GUARD_FAST_INTERVAL}" 'BEGIN { exit !(e < f * 1000) }' || fails+=("tick of ${extrap} ms at ${S7_TARGET} backends exceeds the fast interval")
	awk -v c="${cores}" 'BEGIN { exit !(c < 1) }' || fails+=("guard used ${cores} cores")
	awk -v i="${interval}" -v m="${GUARD_MAX_INTERVAL}" -v w="${work}" 'BEGIN { exit !(i <= m + w / 1000 + 0.5) }' || fails+=("ticks ${interval} s apart, above the max interval ${GUARD_MAX_INTERVAL} s")
	[ "${nice:-0}" -gt 0 ] 2>/dev/null || fails+=("guard not reniced (nice=${nice})")
	# Self-throttling: a tick over its budget must stretch the time between ticks beyond the fast
	# interval (up to the max interval checked above).
	local throttled
	throttled=$(awk -v i="${interval}" -v f="${GUARD_FAST_INTERVAL}" -v w="${work}" 'BEGIN { print (i > f + w / 1000 + 0.1) ? "yes" : "no" }')
	if awk -v w="${work}" -v b="${GUARD_TICK_BUDGET_MS}" 'BEGIN { exit !(w > b) }' && [ "${throttled}" = no ]
	then
		fails+=("tick work ${work} ms over the ${GUARD_TICK_BUDGET_MS} ms budget but ticks not spaced out")
	fi
	local detail
	detail="backends=${n} ticks=${ticks}/${S7_WINDOW}s interval=${interval}s guard-session=${sess_ms}ms cpu/tick=${cpu_ms}ms slow_tick max=${slow:-none}ms work~${work}ms -> ${extrap}ms at ${S7_TARGET}; guard cores=${cores}; budget=${GUARD_TICK_BUDGET_MS}ms throttled=${throttled}; nice=${nice} ionice=${io}"
	if [ ${#fails[@]} -eq 0 ]; then record S7 PASS "${detail}"; else record S7 FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S8: one older major: start line and one stage 1 action.
s8_major() {
	local major=$1 image oom0 oom1 start acts
	major_image "${major}" || { record "S8-pg${major}" SKIP "no image (give --major-image ${major}=TAG or --build)"; return 0; }
	image=${IMAGE_RESULT}
	sim_up "${image}" MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce || return 0
	oom0=$(oom_kills "${DB}")
	canary_start
	ramp 3 130 action pad
	sleep 3
	oom1=$(oom_kills "${DB}")
	db_log "${DB}" > "${SDIR}/db.log"
	start=$(guard_events "${SDIR}/db.log" start | head -n 1)
	acts=$(guard_events "${SDIR}/db.log" action | grep -E ' action=terminate( |$)' | grep -E ' stage=idle( |$)')
	local fails=()
	[ -n "${start}" ] || fails+=("no start line")
	[ -n "${acts}" ] || fails+=("no terminate action at stage idle")
	[ "${oom1}" = "${oom0}" ] || fails+=("oom_kill ${oom0}->${oom1}")
	local detail
	detail="image=${image} actions=$(count_lines "${acts}") peak=$(sampled_peak "${SDIR}/memory.tsv")%"
	if [ ${#fails[@]} -eq 0 ]; then record "S8-pg${major}" PASS "${detail}"; else record "S8-pg${major}" FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# S10: overhead. pgbench TPC-B-like with the guard off (a), in dry-run (b) and enforcing (c), one
# container each, all up at once and benchmarked in turn (a b c a b c ...), so drift on the host
# falls on every case alike. First below the first threshold (S10_REPEAT rounds, medians compared:
# b and c within 2% of a on TPS and p95), then held just above it by a superuser pad, which the
# guard may not end, so it keeps scanning every tick (one round, recorded, with the guard's CPU).
declare -A S10_CTX=()
s10_save() { S10_CTX[$1]="${NET}|${DB}|${CL}|${SDIR}|${CX_HOST}|${HOST_PID1}"; }
s10_use() { IFS='|' read -r NET DB CL SDIR CX_HOST HOST_PID1 <<< "${S10_CTX[$1]}"; SCN="S10$1"; }
# One pgbench run: "tps avg_ms p95_ms p99_ms count guard_cores".
s10_bench() {
	local gp c0 c1 out
	gp=$(guard_pid)
	c0=$(guard_cpu_ms "${DB}" "${gp}")
	out=$(cx bench "${S10_SECONDS}" "${S10_CLIENTS}") || return 1
	c1=$(guard_cpu_ms "${DB}" "${gp}")
	echo "${out} $(awk -v c=$(( c1 - c0 )) -v w="${S10_SECONDS}" 'BEGIN { printf "%.4f", c / (w * 1000) }')"
}
median() { sort -n | awk '{ v[NR] = $1 } END { if (NR % 2) print v[(NR + 1) / 2]; else printf "%.3f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'; }

s10() {
	local c r line t0 low ok=true fails=() detail="" env=()
	for c in a b c
	do
		case ${c} in
			a) env=(MEMORY_GUARD_ENABLED=false) ;;
			b) env=(MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=dry-run) ;;
			c) env=(MEMORY_GUARD_ENABLED=true MEMORY_GUARD_MODE=enforce) ;;
		esac
		scn_begin "S10${c}"
		s10_save "${c}"
		if sim_up "${IMAGE}" "${env[@]}" && cx bench_init "${S10_SCALE}"
		then
			s10_save "${c}"
		else
			ok=false
		fi
	done
	if ${ok}
	then
		for r in $(seq 1 "${S10_REPEAT}")
		do
			for c in a b c
			do
				s10_use "${c}"
				line=$(s10_bench) || { ok=false; continue; }
				echo "normal ${r} ${line}" >> "${SDIR}/bench.txt"
				log "S10${c} normal ${r}: ${line}"
			done
		done
		for c in a b c
		do
			s10_use "${c}"
			pad_to "${ADMIN_USER}" $(( GUARD_IDLE_PERC + 2 )) su || log "S10${c}: pad did not reach $(( GUARD_IDLE_PERC + 2 ))%"
		done
		for c in a b c
		do
			s10_use "${c}"
			t0=$(date +%s)
			line=$(s10_bench) || { ok=false; continue; }
			low=$(sampled_low "${SDIR}/memory.tsv" "${t0}")
			echo "above 1 ${line} ${low}" >> "${SDIR}/bench.txt"
			log "S10${c} above: ${line} lowest ${low}%"
		done
	fi
	for c in a b c
	do
		s10_use "${c}"
		[ -f "${SDIR}/bench.txt" ] || continue
		printf -v "S10_${c}_TPS" '%s' "$(awk '$1 == "normal" { print $3 }' "${SDIR}/bench.txt" | median)"
		printf -v "S10_${c}_P95" '%s' "$(awk '$1 == "normal" { print $5 }' "${SDIR}/bench.txt" | median)"
		printf -v "S10_${c}_ABOVE_CORES" '%s' "$(awk '$1 == "above" { print $8 }' "${SDIR}/bench.txt")"
		record "S10${c}" INFO "tps avg_ms p95_ms p99_ms n guard_cores per run, below: $(awk '$1 == "normal" { $1 = $2 = ""; print }' "${SDIR}/bench.txt" | tr '\n' ';')$(awk -v t="${GUARD_IDLE_PERC}" '$1 == "above" { printf " above: %s %s %s %s %s %s (lowest use %s%%%s)", $3, $4, $5, $6, $7, $8, $9, ($9 < t ? ", NOT held above " t "%" : "") }' "${SDIR}/bench.txt")"
	done
	for c in a b c
	do
		s10_use "${c}"
		scn_end
	done
	SCN=S10
	${ok} || { record S10 FAIL "a case did not run (logs in ${OUT}/S10*)"; return 0; }
	for c in b c
	do
		local tps_var="S10_${c}_TPS" p95_var="S10_${c}_P95" cores_var="S10_${c}_ABOVE_CORES"
		awk -v x="${!tps_var}" -v a="${S10_a_TPS}" 'BEGIN { exit !(x >= a * 0.98) }' || fails+=("(${c}) TPS ${!tps_var} more than 2% below ${S10_a_TPS}")
		awk -v x="${!p95_var}" -v a="${S10_a_P95}" 'BEGIN { exit !(x <= a * 1.02) }' || fails+=("(${c}) p95 ${!p95_var} ms more than 2% above ${S10_a_P95} ms")
		awk -v x="${!cores_var:-0}" 'BEGIN { exit !(x <= 1) }' || fails+=("(${c}) guard used ${!cores_var} cores above the threshold")
		detail="${detail} ${c}: tps=${!tps_var} p95=${!p95_var}ms above-cores=${!cores_var};"
	done
	# How far the baseline's own runs spread: beyond twice the tolerance, a 2% difference cannot be
	# told from host noise, and the verdict says so instead of passing or failing on luck.
	local spread
	spread=$(s10_use a; awk '$1 == "normal" { v[++n] = $3 } END { lo = hi = v[1]; for (i = 2; i <= n; i++) { if (v[i] < lo) lo = v[i]; if (v[i] > hi) hi = v[i] }; printf "%.1f", (n && lo > 0) ? (hi - lo) * 100 / lo : 0 }' "${SDIR}/bench.txt")
	SCN=S10
	awk -v s="${spread}" 'BEGIN { exit !(s > 4) }' && fails=("inconclusive: the baseline's own TPS spread ${spread}% across runs, above twice the 2% tolerance; rerun on a quiet host with more --s10-repeat" "${fails[@]+"${fails[@]}"}")
	detail="medians below the threshold over ${S10_REPEAT} interleaved runs of ${S10_SECONDS}s (baseline spread ${spread}%); a: tps=${S10_a_TPS} p95=${S10_a_P95}ms;${detail}"
	if [ ${#fails[@]} -eq 0 ]; then record S10 PASS "${detail}"; else record S10 FAIL "$(IFS=';'; echo "${fails[*]}") | ${detail}"; fi
}

# Runs one scenario function in its own network and containers; a scenario that recorded nothing
# failed.
run_one() {
	local id=$1 before=${#RES_IDS[@]}
	shift
	scn_begin "${id}"
	"$@"
	scn_end
	[ ${#RES_IDS[@]} -gt "${before}" ] || record "${id}" FAIL "no result recorded"
}

# --- Main --------------------------------------------------------------------------------------

command -v docker >/dev/null || die "docker not found"
[ -n "${OUT}" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/mgsim.XXXXXX")
mkdir -p "${OUT}"
OUT=$(cd "${OUT}" && pwd)
log "run ${RUN_ID}, logs in ${OUT}"

if [ -n "${BUILD_PATH}" ]
then
	BUILD_PATH=$(cd "${BUILD_PATH}" && pwd) || die "no such worktree"
	IMAGE="mgsim-local/repository:${RUN_ID}-pg18"
	build_image "${IMAGE}" "${BUILD_PATH}/src/main/infrastructure/repository/Dockerfile7" \
		"${BUILD_PATH}/src/main/infrastructure/repository" || die "build failed"
fi
[ -n "${IMAGE}" ] || { usage >&2; die "give --image or --build"; }
docker image inspect "${IMAGE}" >/dev/null 2>&1 || docker pull -q "${IMAGE}" >/dev/null || die "no image ${IMAGE}"
CLIENT_IMAGE=${IMAGE}

for s in ${SCENARIOS//,/ }
do
	case ${s} in
		S0) run_one S0 s0 "${IMAGE}" ;;
		S0B)
			docker image inspect "${BASELINE_IMAGE}" >/dev/null 2>&1 || docker pull -q "${BASELINE_IMAGE}" >/dev/null
			run_one S0B s0 "${BASELINE_IMAGE}" ;;
		S1) run_one S1 s1 ;;
		S2) run_one S2 s2 ;;
		S3) s3 ;;
		S4) run_one S4 s4 ;;
		S5) run_one S5a s5_signal TERM; run_one S5b s5_signal KILL; run_one S5cd s5_protected; run_one S5e s5_restart ;;
		S5a) run_one S5a s5_signal TERM ;;
		S5b) run_one S5b s5_signal KILL ;;
		S5cd) run_one S5cd s5_protected ;;
		S5e) run_one S5e s5_restart ;;
		S6) run_one S6 s6 ;;
		S7) run_one S7 s7 ;;
		S8)
			for m in 15 16 17
			do
				run_one "S8-pg${m}" s8_major "${m}"
			done
			if [ -n "${BUILD_PATH}" ]
			then
				# PostgreSQL 14 does not boot on master (a known bug candidate): build only.
				if major_image 14; then record S8-pg14 PASS "build only"; else record S8-pg14 FAIL "build failed"; fi
			fi ;;
		S9) record S9 SKIP "needs host root to write memory.high; run by hand (see the header)" ;;
		S10) s10 ;;
		*) record "${s}" FAIL "unknown scenario" ;;
	esac
done

# Results.
status=0
echo
printf '%-12s %-5s %s\n' SCENARIO RESULT DETAIL
for i in "${!RES_IDS[@]}"
do
	printf '%-12s %-5s %s\n' "${RES_IDS[$i]}" "${RES_STATUS[$i]}" "${RES_DETAIL[$i]}"
	[ "${RES_STATUS[$i]}" = FAIL ] && status=1
done
echo "logs: ${OUT}"
exit "${status}"
