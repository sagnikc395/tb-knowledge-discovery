#!/bin/bash
#SBATCH --job-name=tb-demo
#SBATCH --partition=gpu-preempt
#SBATCH --gres=gpu:1
#SBATCH --constraint="vram16&[sm_80|sm_86|sm_89|sm_90]"
#SBATCH --cpus-per-task=4
#SBATCH --mem=24G
#SBATCH --time=01:00:00
#SBATCH --requeue
#SBATCH --output=logs/tb-demo-%j.out
# The smallest job that still runs all three stages end to end — the one to
# submit when the point is to show the pipeline working, not to report numbers.
#
# run_unity_quick.sbatch already relaxed the partition, the walltime and the
# card. What it could not relax is the context window: A1 carries all 218 tools
# in its system prompt, measured at 156k characters — ~39k tokens — so the run
# needs 40k of context, so it needs >=23 GB, so it waits for an Ampere card
# that large. That single number is what decides which nodes can take the job.
#
# So this job breaks it instead. --tools (TOOLS=1) switches on biomni's
# prompt-based tool retriever: one selection call per run carrying the tool
# names and descriptions (~12k tokens), and then a system prompt holding only
# the tools it picked — ~4.5k tokens per step, measured on a retrieval-shaped
# selection. Peak prompt ~13k rather than 39k, so 32k of context is generous
# rather than marginal, and a 4-bit 8B at 32k is ~6 GB of weights plus room to
# spare for KV cache on a 16 GB card. On gpu-preempt that is the a16/l4 pool
# rather than a handful of nodes, and with one hour of walltime it backfills
# into almost any gap.
#
# What you give up, and should say out loud when showing it:
#
#   - the tool retriever means A1 sees a subset of its tools, so a retrieval
#     run can miss a tool the full catalogue would have offered;
#   - an 8B calls tools less reliably than the 32B, so expect more `unknown`
#     verdicts and the odd malformed reply that gets retried;
#   - 4 isolates on one drug is a demo, not a sample size. The accuracy and
#     trace-validity rates in SUMMARY.md are illustrative only.
#
# Everything structural is unchanged: the same cohort join, the same variant
# naming and WHO panel filtering, the same three mechanical trace checks, the
# same monitoring timelines and the same run folder. That is the part worth
# showing.
#
# If the submission is rejected as unsatisfiable, the constraint is the thing
# to check first: `sinfo -o '%P %G %f'` lists the partitions and the feature
# names they actually carry, and `vram16` has to be one of them. Dropping to
# `--constraint=vram23` (the quick job's pool) always works and is still a far
# shorter queue than the A100 partitions.
#
#   sbatch scripts/run_unity_demo.sbatch      # or: ./run.sh demo
#   tail -f logs/tb-demo-<jobid>.out
#
# Every knob is overridable at submit time:
#
#   DEMO_DRUGS="rifampicin isoniazid" DEMO_LIMIT=8 sbatch scripts/run_unity_demo.sbatch
#   MODEL=Qwen/Qwen3-14B-AWQ MAX_MODEL_LEN=24576 \
#     sbatch --constraint=vram23 scripts/run_unity_demo.sbatch

set -euo pipefail

# A 4-bit 8B: ~6 GB of weights. awq_marlin needs sm_80, which the constraint
# above already guarantees.
export MODEL="${MODEL:-Qwen/Qwen3-8B-AWQ}"
# Only safe because TOOLS=1 below cuts the peak prompt to ~13k. Lowering this
# without that is what makes a run die on context length mid-agent-loop; the
# headroom above ~13k is for the agent's own history and its tool outputs.
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
export GPU_UTIL="${GPU_UTIL:-0.92}"
export TOOLS="${TOOLS:-1}"

# One drug, four isolates, one document per screening run, and the least
# thinking that still leaves a trace to read.
export DRUGS="${DEMO_DRUGS:-rifampicin}"
export LIMIT="${DEMO_LIMIT:-4}"
export EFFORT="${DEMO_EFFORT:-low}"
export BATCH_SIZE="${BATCH_SIZE:-1}"
export BALANCE="${BALANCE:-1}"
export SEED="${SEED:-0}"
export RUN_ID="${RUN_ID:-demo-${SLURM_JOB_ID:-local}}"

echo "Demo run: ${MODEL} at ${MAX_MODEL_LEN} ctx, tool retriever on"
echo "  drugs=${DRUGS}, limit=${LIMIT}, effort=${EFFORT}"
echo "Results will land in results/${RUN_ID}/"

# sbatch copies the submitted file to the node's spool directory, so $0 cannot
# locate its sibling; SLURM_SUBMIT_DIR is where sbatch was run from.
SERVE=""
for dir in "${SLURM_SUBMIT_DIR:-$PWD}" "${SLURM_SUBMIT_DIR:-$PWD}/scripts" \
           "${SLURM_SUBMIT_DIR:-$PWD}/.."; do
    if [ -f "${dir}/scripts/run_unity_a100.sbatch" ]; then
        SERVE="${dir}/scripts/run_unity_a100.sbatch"
        break
    elif [ -f "${dir}/run_unity_a100.sbatch" ]; then
        SERVE="${dir}/run_unity_a100.sbatch"
        break
    fi
done
if [ -z "${SERVE}" ]; then
    echo "Cannot find run_unity_a100.sbatch next to ${SLURM_SUBMIT_DIR:-$PWD}." >&2
    echo "Submit this from the repo: sbatch scripts/run_unity_demo.sbatch" >&2
    exit 1
fi

# Serving, waiting on the server, running the pipeline and freeing the card are
# identical to the full job, so that script does them — with the environment
# above in place of its defaults.
exec bash "${SERVE}" experiment
