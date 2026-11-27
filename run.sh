#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: ./run.sh [--profile demo|quick|full] [--local|--slurm] [options]
       ./run.sh --attach [JOB_ID]
       ./run.sh --collect [RUN_DIR]
       ./run.sh --status RUN_DIR

By default, submit on Slurm if sbatch is available, or use an existing
local model server. The default profile is quick.

Experiment options:
  --drugs "DRUG ..."     Space-separated drug list
  --limit N             Isolates per drug
  --balance             Sample equal R/S counts (default)
  --no-balance          Sample without equal R/S counts
  --seed N              Sampling seed (default 0)
  --effort LEVEL        Prediction reasoning effort
  --tools / --no-tools  Enable or disable agent tool selection
  --batch-size N        Documents per screening batch
  --vcf-root DIR        Override the VCF location
  --papers PATH         Screening input (default papers)
  --gold FILE           Screening labels (default eval/screening_gold.json)
  --run-id ID           Name the result folder

Server and Slurm options:
  --model MODEL         Override the profile's model
  --base-url URL        Existing OpenAI-compatible endpoint for --local
  --source SOURCE       Local backend: Custom (default) or Ollama
  --port N              vLLM port on Slurm (default 8000)
  --max-model-len N     vLLM context length
  --submit-only         Print the Slurm job ID and return
  --sbatch-arg ARG      Add one sbatch option, such as --time=04:00:00
                        Repeat for multiple options
  --serve-only          On Slurm, serve vLLM until the job ends
  --cli ARGS...         Run a single cli.py command against the selected server
  -h, --help            Show this help
HELP
}

die() {
    echo "$*" >&2
    exit 1
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        die "$1 requires a value. See ./run.sh --help."
    fi
}

safe_id() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worker=0
# Slurm runs a spool copy, so the submitter passes the checkout explicitly.
if [[ "${1:-}" == --worker ]]; then
    [[ -n "${SLURM_JOB_ID:-}" && -d "${2:-}" ]] || die "Invalid Slurm worker invocation."
    worker=1
    REPO="$2"
    shift 2
fi

collect() {
    local folder="${1:-}" candidate
    if [[ -z "$folder" ]]; then
        for candidate in "$REPO"/results/*/; do
            [[ -d "$candidate" ]] || continue
            if [[ -z "$folder" || "$candidate" -nt "$folder" ]]; then
                folder="$candidate"
            fi
        done
    fi
    [[ -n "$folder" && -d "$folder" ]] || die "No run directory found: ${folder:-$REPO/results}"
    python3 -m tb_search.experiment_report "$folder"
}

show_status() {
    local folder="$1" file
    [[ -d "$folder/logs" ]] || die "No logs in $folder"
    if [[ -f "$folder/logs/stages.txt" ]]; then
        cat "$folder/logs/stages.txt"
    fi
    for file in "$folder"/logs/*_timeline.csv; do
        [[ -f "$file" ]] || continue
        printf '\n%s\n' "$(basename "$file")"
        head -n 1 "$file"
        tail -n +2 "$file" | tail -n 3
    done
}

follow_job() {
    local job="$1" log="$REPO/logs/tb-$1.out" candidate status last="" follower="" queue_error=0
    local account state="" folder=""
    [[ "$job" =~ ^[0-9]+$ ]] || die "Invalid Slurm job ID: $job"
    for candidate in "$REPO"/logs/tb-{demo,quick,a100}-"$job".out; do
        if [[ ! -e "$log" && -f "$candidate" ]]; then
            log="$candidate"
        fi
    done
    trap 'if [[ -n "$follower" ]]; then kill "$follower" 2>/dev/null || true; fi
          printf "\nDetached. Reattach with ./run.sh --attach %s\n" "$job"
          exit 0' INT

    while :; do
        if ! status="$(squeue -h -j "$job" -o '%T %R' 2>/dev/null)"; then
            queue_error=1
            break
        fi
        [[ -n "$status" ]] || break
        if [[ "$status" != "$last" ]]; then
            printf '%s  %s\n' "$(date '+%H:%M:%S')" "$status"
            last="$status"
        fi
        if [[ "$status" == RUNNING* && -z "$follower" ]]; then
            tail -n +1 -F "$log" 2>/dev/null &
            follower=$!
        fi
        sleep "${POLL:-10}"
    done
    if [[ -n "$follower" ]]; then
        kill "$follower" 2>/dev/null || true
        wait "$follower" 2>/dev/null || true
    fi
    [[ ! -f "$log" || -n "$follower" ]] || tail -n 20 "$log"

    account="$(sacct -X -n -P -j "$job" -o JobIDRaw,State,ExitCode 2>/dev/null)" || account=""
    if [[ -n "$account" ]]; then
        printf '\nJobID|State|ExitCode\n%s\n' "$account"
        state="$(awk -F'|' -v job="$job" '$1 == job {print $2; exit}' <<< "$account")"
    fi
    case "$state" in
        PENDING|RUNNING|COMPLETING|CONFIGURING|REQUEUED|SUSPENDED)
            die "Job $job is $state. Reattach with ./run.sh --attach $job"
            ;;
        "") [[ "$queue_error" == 0 ]] || die "Could not verify job $job has stopped. Reattach later." ;;
    esac
    folder="$(python3 - "$job" <<'PY'
import json
import sys
from pathlib import Path

matches = []
for path in Path("results").glob("*/run_metadata.json"):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        continue
    if str(data.get("slurm_job_id")) == sys.argv[1]:
        matches.append((data.get("started_at", ""), path.parent))
if matches:
    print(max(matches)[1])
PY
)"
    if [[ -n "$folder" ]]; then
        # A cancelled or timed-out job can still have usable stage artifacts.
        if [[ ! -f "$folder/SUMMARY.md" || ! -f "$folder.tar.gz" ]]; then
            collect "$folder"
        fi
        printf '\n'
        cat "$folder/SUMMARY.md"
        printf '\nSummary: %s/SUMMARY.md\nArchive: %s.tar.gz\n' "$folder" "$folder"
        if [[ -f "$folder/logs/stages.txt" ]] && grep -q $'\tFAILED$' "$folder/logs/stages.txt"; then
            return 1
        fi
    fi
    if [[ -n "$state" ]]; then
        [[ "$state" == COMPLETED ]]
    elif [[ -z "$folder" ]]; then
        die "Slurm has no final status for job $job yet. Log: $log"
    fi
}

start_server() {
    local venv="${VLLM_VENV:-$HOME/vllm-venv}" capability value
    local timeout="${STARTUP_TIMEOUT:-1200}" deadline
    module load cuda/12.6 2>/dev/null || true
    capability="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n 1)" || capability=""
    value="${capability/./}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value < ${MIN_CC:-80} )); then
        die "GPU compute capability $capability is below the minimum SM ${MIN_CC:-80}."
    fi

    if [[ ! -x "$venv/bin/vllm" ]]; then
        mkdir -p "$(dirname "$venv")"
        (
            flock 9
            if [[ ! -x "$venv/bin/vllm" ]]; then
                python3 -m venv "$venv"
                "$venv/bin/python" -m pip install vllm autoawq
            fi
        ) 9>"$venv.lock"
    fi

    BASE_URL="http://127.0.0.1:$PORT/v1"
    echo "Serving $MODEL at http://$(hostname):$PORT/v1"
    "$venv/bin/vllm" serve "$MODEL" --port "$PORT" --host "${VLLM_HOST:-0.0.0.0}" \
        --tensor-parallel-size "${TP_SIZE:-1}" --gpu-memory-utilization "$GPU_UTIL" \
        --reasoning-parser "${REASONING_PARSER:-qwen3}" --enable-auto-tool-choice \
        --tool-call-parser hermes --max-model-len "$MAX_MODEL_LEN" &
    server_pid=$!
    deadline=$(( SECONDS + timeout ))
    until curl -fsS --max-time 5 "$BASE_URL/models" >/dev/null 2>&1; do
        kill -0 "$server_pid" 2>/dev/null || die "vLLM exited before it was ready."
        (( SECONDS < deadline )) || die "vLLM did not start within ${timeout}s."
        sleep 5
    done
}

metric() {
    awk -v name="$2" '$1 == name || index($1, name "{") == 1 { print $2; exit }' <<< "$1"
}

monitor_run() {
    local metrics_url="${MONITOR_METRICS_URL:-${BASE_URL%/v1}/metrics}"
    local stamp body now running queued cache generation rate last_count="" last_time="" sleep_pid=""
    local gpu_query="index,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,temperature.gpu"

    trap 'if [[ -n "$sleep_pid" ]]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM
    while :; do
        stamp="$(date '+%Y-%m-%dT%H:%M:%S')"
        if command -v nvidia-smi >/dev/null; then
            nvidia-smi --query-gpu="$gpu_query" --format=csv,noheader,nounits 2>/dev/null \
                | sed "s/^/$stamp, /" >> "$RUN_DIR/logs/gpu_timeline.csv" || true
        fi
        if [[ "$SOURCE" == Custom ]]; then
            if body="$(curl -fsS --max-time 5 "$metrics_url" 2>/dev/null)"; then
                running="$(metric "$body" vllm:num_requests_running)"
                queued="$(metric "$body" vllm:num_requests_waiting)"
                cache="$(metric "$body" vllm:kv_cache_usage_perc)"
                [[ -n "$cache" ]] || cache="$(metric "$body" vllm:gpu_cache_usage_perc)"
                generation="$(metric "$body" vllm:generation_tokens_total)"
                now="$(date +%s)"
                rate=""
                if [[ -n "$generation" && -n "$last_count" ]]; then
                    rate="$(awk -v a="$generation" -v b="$last_count" -v d="$(( now - last_time ))" \
                        'BEGIN { if (d > 0 && a >= b) printf "%.1f", (a - b) / d }')"
                fi
                last_count="$generation"
                last_time="$now"
                printf '%s,%s,%s,%s,%s,%s,ok\n' "$stamp" "$running" "$queued" "$cache" "$generation" "$rate"
            else
                printf '%s,,,,,,unreachable\n' "$stamp"
            fi >> "$RUN_DIR/logs/server_timeline.csv"
        fi
        sleep "${MONITOR_INTERVAL:-15}" &
        sleep_pid=$!
        wait "$sleep_pid"
        sleep_pid=""
    done
}

stop_monitor() {
    if [[ -n "$monitor_pid" ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        monitor_pid=""
    fi
}

cleanup() {
    stop_monitor
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}

stage() {
    local name="$1" log="$2"
    shift 2
    local started="$SECONDS" stamp code status
    local -a pipeline
    stamp="$(date '+%Y-%m-%dT%H:%M:%S')"
    echo "=== $name ($stamp) ==="
    if "$@" 2>&1 | tee "$RUN_DIR/logs/$log"; then
        code=0
    else
        pipeline=("${PIPESTATUS[@]}")
        code="${pipeline[0]}"
        [[ "$code" -ne 0 ]] || code="${pipeline[1]}"
    fi
    status=ok
    if [[ "$code" -ne 0 ]]; then
        status=FAILED
        echo "$name failed (exit $code). See logs/$log."
    fi
    printf '%s\t%s\n' "$name" "$status" >> "$RUN_DIR/logs/stages.txt"
    printf '{"stage":"%s","status":"%s","exit_code":%s,"started_at":"%s","seconds":%s,"log":"%s"}\n' \
        "$name" "$status" "$code" "$stamp" "$(( SECONDS - started ))" "$log" >> "$RUN_DIR/logs/stages.jsonl"
}

run_experiment() {
    local drug
    local -a prediction=(--limit "$LIMIT" --seed "$SEED" --reasoning-effort "$EFFORT")
    local -a screening=(--batch-size "$BATCH_SIZE")
    # Check names before using them as file names and JSON strings.
    for drug in "${drugs[@]}"; do
        safe_id "$drug" || die "Invalid drug name: $drug"
    done

    RUN_ID="${RUN_ID:-$PROFILE-${SLURM_JOB_ID:-$(date +%Y%m%d-%H%M%S)-$$}}"
    if [[ "${SLURM_RESTART_COUNT:-0}" != 0 ]]; then
        RUN_ID="$RUN_ID-r$SLURM_RESTART_COUNT"
    fi
    RUN_DIR="$REPO/results/$RUN_ID"
    mkdir -p "$REPO/results"
    mkdir "$RUN_DIR" || die "Could not create run directory $RUN_DIR. Use a new --run-id."
    mkdir "$RUN_DIR/logs"
    echo "Writing results to $RUN_DIR"

    python3 - "$RUN_DIR" "$MODEL" "$BASE_URL" "$SOURCE" "$EFFORT" \
        "$LIMIT" "$BALANCE" "$SEED" "$PROFILE" "$TOOLS" "$BATCH_SIZE" "${drugs[@]}" <<'PY'
from datetime import datetime
import json
from pathlib import Path
import os
import platform
import subprocess
import sys

def git(*args):
    try:
        return subprocess.check_output(("git", *args), text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None

folder, model, url, source, effort, limit, balance, seed, profile, tools, batch, *drugs = sys.argv[1:]
run = Path(folder)
(run / "run_metadata.json").write_text(json.dumps({
    "run_id": run.name,
    "started_at": datetime.now().isoformat(timespec="seconds"),
    "model": model,
    "base_url": url if source == "Custom" else None,
    "source": source,
    "profile": profile,
    "tool_retriever": tools == "1",
    "screening_batch_size": int(batch),
    "reasoning_effort": effort,
    "drugs": drugs,
    "isolates_per_drug": int(limit),
    "balanced": balance == "1",
    "seed": int(seed),
    "host": platform.node(),
    "slurm_job_id": os.environ.get("SLURM_JOB_ID"),
    "git_commit": git("rev-parse", "HEAD"),
    "git_dirty": bool(git("status", "--porcelain")),
}, indent=2) + "\n")
PY

    if command -v nvidia-smi >/dev/null; then
        nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv \
            > "$RUN_DIR/logs/gpu.txt" 2>&1 || true
    fi
    printf '%s\n' 'timestamp,gpu,util_gpu_pct,util_mem_pct,mem_used_mib,mem_total_mib,power_w,temp_c' \
        > "$RUN_DIR/logs/gpu_timeline.csv"
    if [[ "$SOURCE" == Custom ]]; then
        printf '%s\n' 'timestamp,requests_running,requests_waiting,kv_cache_usage,generation_tokens_total,generation_tok_per_s,status' \
            > "$RUN_DIR/logs/server_timeline.csv"
    fi
    monitor_run &
    monitor_pid=$!

    stage cohort cohort.log uv run cli.py --cohort -o "$RUN_DIR/tb_cohort.json"
    [[ "$BALANCE" != 1 ]] || prediction+=(--balance)
    [[ -z "$VCF_ROOT" ]] || prediction+=(--vcf-root "$VCF_ROOT")
    for drug in "${drugs[@]}"; do
        stage "predict $drug" "predict-$drug.log" uv run cli.py --predict "$drug" \
            "${prediction[@]}" "${common[@]}" -o "$RUN_DIR/tb_resistance_$drug.json"
    done
    if [[ -e "$PAPERS" ]]; then
        [[ ! -f "$GOLD" ]] || screening+=(--gold "$GOLD")
        stage screening screening.log uv run cli.py "$PAPERS" "${screening[@]}" "${common[@]}" \
            -o "$RUN_DIR/tb_verdicts.json"
    else
        echo "Skipping screening. Input missing: $PAPERS"
        printf 'screening\tskipped\n' >> "$RUN_DIR/logs/stages.txt"
        printf '{"stage":"screening","status":"skipped","seconds":0}\n' >> "$RUN_DIR/logs/stages.jsonl"
    fi

    stop_monitor
    collect "$RUN_DIR"
    if grep -q $'\tFAILED$' "$RUN_DIR/logs/stages.txt"; then
        return 1
    fi
}

# Resolve paths for utility actions from the caller's directory.
case "${1:-}" in
    --collect|--status)
        [[ $# -le 2 ]] || die "$1 accepts a single run directory."
        folder="${2:-}"
        if [[ -n "$folder" && "$folder" != /* ]]; then
            folder="$PWD/$folder"
        fi
        cd "$REPO"
        if [[ "$1" == --collect ]]; then
            collect "$folder"
        else
            need_value "$@"
            show_status "$folder"
        fi
        exit
        ;;
    --attach)
        [[ $# -le 2 ]] || die "--attach accepts a single job ID."
        cd "$REPO"
        job="${2:-}"
        if [[ -z "$job" ]]; then
            jobs="$(squeue -h -u "$(id -un)" -o '%i %j' --sort=-V)"
            job="$(awk '$2 ~ /^tb-(demo|quick|a100)$/ {print $1; exit}' <<< "$jobs")"
        fi
        [[ -n "$job" ]] || die "No TB job found. Pass a job ID to attach to a finished job."
        follow_job "$job"
        exit
        ;;
esac
cd "$REPO"

PROFILE=quick
target=auto
action=experiment
submit_only=0
original=("$@")
slurm_args=()
cli_args=()
DRUGS="${DRUGS:-}"
LIMIT="${LIMIT:-}"
EFFORT="${EFFORT:-}"
TOOLS="${TOOLS:-}"
BATCH_SIZE="${BATCH_SIZE:-}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-}"
GPU_UTIL="${GPU_UTIL:-}"
MODEL="${MODEL:-${VLLM_MODEL:-}}"
BASE_URL="${BASE_URL:-${VLLM_BASE_URL:-http://localhost:8000/v1}}"
SOURCE="${SOURCE:-Custom}"
PORT="${PORT:-8000}"
SEED="${SEED:-0}"
BALANCE="${BALANCE:-1}"
RUN_ID="${RUN_ID:-}"
VCF_ROOT="${VCF_ROOT:-}"
PAPERS="${PAPERS:-papers}"
GOLD="${GOLD:-eval/screening_gold.json}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        demo|quick|full) PROFILE="$1"; shift; continue ;;
        --local|--slurm) target="${1#--}"; shift; continue ;;
        --tools) TOOLS=1; shift; continue ;;
        --no-tools) TOOLS=0; shift; continue ;;
        --balance) BALANCE=1; shift; continue ;;
        --no-balance) BALANCE=0; shift; continue ;;
        --submit-only) submit_only=1; shift; continue ;;
        --serve-only) action=serve; shift; continue ;;
        --cli)
            shift
            [[ $# -gt 0 ]] || die "--cli requires cli.py arguments."
            action=cli
            cli_args=("$@")
            break
            ;;
        --sbatch-arg)
            [[ $# -ge 2 && "$2" == -* ]] || die "--sbatch-arg requires a Slurm option."
            slurm_args+=("$2")
            ;;
        --profile|--drugs|--limit|--effort|--batch-size|--vcf-root|--papers|--gold|--run-id|\
        --model|--base-url|--source|--port|--max-model-len|--seed)
            need_value "$@"
            key="${1#--}"
            key="${key//-/_}"
            # The case matches a fixed list of configurable variables.
            printf -v "$(tr '[:lower:]' '[:upper:]' <<< "$key")" '%s' "$2"
            ;;
        *) die "Unknown option: $1. See ./run.sh --help." ;;
    esac
    shift 2
done

case "$PROFILE" in
    demo)
        MODEL="${MODEL:-Qwen/Qwen3-8B-AWQ}"
        MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
        GPU_UTIL="${GPU_UTIL:-0.92}"
        DRUGS="${DRUGS:-${DEMO_DRUGS:-rifampicin}}"
        LIMIT="${LIMIT:-${DEMO_LIMIT:-4}}"
        EFFORT="${EFFORT:-${DEMO_EFFORT:-low}}"
        TOOLS="${TOOLS:-1}"
        BATCH_SIZE="${BATCH_SIZE:-1}"
        job_name=tb-demo
        resources=(--partition=gpu-preempt --gres=gpu:1 '--constraint=vram16&[sm_80|sm_86|sm_89|sm_90]'
                   --cpus-per-task=4 --mem=24G --time=01:00:00 --requeue)
        ;;
    quick)
        MODEL="${MODEL:-Qwen/Qwen3-14B-AWQ}"
        MAX_MODEL_LEN="${MAX_MODEL_LEN:-40960}"
        GPU_UTIL="${GPU_UTIL:-0.95}"
        DRUGS="${DRUGS:-${QUICK_DRUGS:-rifampicin}}"
        LIMIT="${LIMIT:-${QUICK_LIMIT:-8}}"
        EFFORT="${EFFORT:-${QUICK_EFFORT:-medium}}"
        job_name=tb-quick
        resources=(--partition=gpu-preempt --gres=gpu:1 '--constraint=vram23&[sm_80|sm_86|sm_89|sm_90]'
                   --cpus-per-task=4 --mem=32G --time=02:00:00 --requeue)
        ;;
    full)
        MODEL="${MODEL:-Qwen/Qwen3-32B-AWQ}"
        MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
        GPU_UTIL="${GPU_UTIL:-0.90}"
        DRUGS="${DRUGS:-rifampicin isoniazid ethambutol pyrazinamide}"
        LIMIT="${LIMIT:-20}"
        EFFORT="${EFFORT:-high}"
        job_name=tb-a100
        resources=(--partition=gpu-highvram --gres=gpu:a100:1 --cpus-per-task=16 --mem=96G --time=08:00:00)
        ;;
    *) die "Unknown profile: $PROFILE. Choose demo, quick, or full." ;;
esac

TOOLS="${TOOLS:-0}"
BATCH_SIZE="${BATCH_SIZE:-2}"
BASE_URL="${BASE_URL%/}"
read -r -a drugs <<< "$DRUGS"
[[ ${#drugs[@]} -gt 0 ]] || die "Provide at least one drug."
[[ -z "$RUN_ID" ]] || safe_id "$RUN_ID" || die "Invalid run ID: $RUN_ID"
for value in "$LIMIT" "$BATCH_SIZE" "$PORT" "$MAX_MODEL_LEN"; do
    [[ "$value" =~ ^[0-9]+$ && "$value" =~ [1-9] ]] || die "Expected a positive integer, got: $value"
done
[[ "$SEED" =~ ^-?[0-9]+$ ]] || die "Invalid seed: $SEED"
case "$EFFORT" in
    none|minimal|low|medium|high|xhigh|max) ;;
    *) die "Invalid reasoning effort: $EFFORT" ;;
esac

if [[ "$target" == auto ]]; then
    target=local
    if command -v sbatch >/dev/null && [[ -z "${SLURM_JOB_ID:-}" ]]; then
        target=slurm
    fi
fi
if [[ "$worker" == 1 ]]; then
    target=worker
fi
case "$SOURCE" in
    Custom) ;;
    Ollama) [[ "$target" == local ]] || die "Ollama requires --local." ;;
    *) die "Invalid source: $SOURCE. Choose Custom or Ollama." ;;
esac
if [[ "$target" == local && ( "$action" == serve || "$submit_only" == 1 || ${#slurm_args[@]} -gt 0 ) ]]; then
    die "--serve-only, --submit-only and --sbatch-arg require Slurm."
fi
if [[ "$action" != serve ]]; then
    command -v uv >/dev/null || die "uv is required. On Unity, load it with: module load uv"
fi
if [[ "$action" == experiment ]]; then
    for path in data/cleaned_vcf_paths/{master_resistance_table.csv,big_tb_file_paths.txt}; do
        [[ -r "$path" ]] || die "Missing cohort input: $path"
    done
fi

if [[ "$target" == slurm ]]; then
    command -v sbatch >/dev/null || die "sbatch is required for --slurm."
    mkdir -p logs
    read -r -a environment_sbatch_args <<< "${SBATCH_ARGS:-}"
    job="$(sbatch --parsable --job-name="$job_name" --chdir="$REPO" --output="$REPO/logs/tb-%j.out" \
        "${resources[@]}" ${environment_sbatch_args[@]+"${environment_sbatch_args[@]}"} \
        ${slurm_args[@]+"${slurm_args[@]}"} "$REPO/run.sh" --worker "$REPO" \
        ${original[@]+"${original[@]}"})"
    job="${job%%;*}"
    [[ "$job" =~ ^[0-9]+$ ]] || die "Unexpected sbatch job ID: $job"
    echo "Job $job submitted. Log: logs/tb-$job.out"
    if [[ "$submit_only" != 1 ]]; then
        follow_job "$job"
    fi
    exit
fi

server_pid=""
monitor_pid=""
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "$target" == worker ]]; then
    start_server
fi
if [[ "$action" == serve ]]; then
    wait "$server_pid"
    exit
fi

common=(--model "$MODEL" --source "$SOURCE")
if [[ "$SOURCE" == Custom ]]; then
    common+=(--base-url "$BASE_URL")
fi
if [[ "$TOOLS" == 1 ]]; then
    common+=(--tools)
else
    common+=(--no-tools)
fi
if [[ "$action" == cli ]]; then
    uv run cli.py "${common[@]}" "${cli_args[@]}"
    exit
fi
if [[ "$target" == local && "$SOURCE" == Custom ]]; then
    curl -fsS --max-time 10 "$BASE_URL/models" >/dev/null || die "No model server at $BASE_URL"
fi
run_experiment
