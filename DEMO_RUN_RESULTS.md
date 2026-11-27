# Demo run results — job 2149968

Source log: `logs/tb-demo-2149968.out` (3,214 lines). Run folder on the cluster:
`results/demo-2149968/`, also tarred as `results/demo-2149968.tar.gz`.

These numbers are illustrative. Four isolates on one drug and six papers is a
demonstration that the pipeline runs end to end, not a sample size — read the
"How a full run differs" section before quoting anything here.

## Configuration

Submitted as `scripts/run_unity_demo.sbatch` (`./run.sh demo`), which sets the
environment below and then execs `scripts/run_unity_a100.sbatch experiment`.

| | demo 2149968 |
|---|---|
| model | `Qwen/Qwen3-8B-AWQ` (4-bit, ~6 GB of weights) |
| `MAX_MODEL_LEN` | 32,768 |
| `GPU_UTIL` | 0.92 |
| `TOOLS` | 1 — biomni's prompt-based tool retriever |
| drugs | rifampicin |
| isolates (`LIMIT`) | 4, balanced (`BALANCE=1`), `SEED=0` |
| reasoning effort | low |
| screening `BATCH_SIZE` | 1 document per agent call |
| papers / gold | `papers/` (6 PDFs) against `eval/screening_gold.json` |
| partition | `gpu-preempt`, `--constraint="vram16&[sm_80\|sm_86\|sm_89\|sm_90]"` |
| walltime / cpus / mem | 1h, 4 cores, 24G |

Allocated hardware: **NVIDIA A16, 15,356 MiB, sm_86** on `gpu048`. vLLM 0.34.0,
FlashAttention 2, `awq_marlin` via `MarlinLinearKernel`, `--reasoning-parser
qwen3`, `--enable-auto-tool-choice --tool-call-parser hermes`.

Observed utilisation: 12,606–12,874 MiB of 15,356 used, 100% GPU and memory
util during both agent stages, 59 W, 69 °C, generation 23–29 tok/s. Server came
up 280 s after launch; 41,595 generation tokens over the run.

## Timing

| stage | status | wall |
|---|---|---|
| cohort | ok | 2m13s |
| predict rifampicin | ok | 8m20s |
| screening | ok | 29m23s |
| **total** | | **~40 min** inside the 1h walltime |

## Stage 1 — cohort (2m13s)

Joined the resistance table against the VCF paths: **17,942 isolates with a
VCF; 4,228 table rows had none.** Per-drug phenotype counts (R / S / total):

| drug | R | S | total |
|---|---|---|---|
| rifampicin | 4,869 | 12,713 | 17,582 |
| isoniazid | 5,825 | 11,611 | 17,436 |
| ethambutol | 2,945 | 12,166 | 15,111 |
| pyrazinamide | 2,131 | 10,773 | 12,904 |
| streptomycin | 2,416 | 5,266 | 7,682 |
| capreomycin | 675 | 3,179 | 3,854 |
| amikacin | 707 | 2,998 | 3,705 |
| kanamycin | 703 | 2,873 | 3,576 |
| ofloxacin | 824 | 2,590 | 3,414 |
| moxifloxacin | 388 | 2,480 | 2,868 |
| ethionamide | 690 | 1,463 | 2,153 |
| rifabutin | 566 | 535 | 1,101 |
| para_aminosalicylic_acid | 77 | 757 | 834 |
| prothionamide | 184 | 381 | 565 |
| cycloserine | 100 | 412 | 512 |
| ciprofloxacin | 106 | 332 | 438 |
| levofloxacin | 76 | 193 | 269 |
| amoxicillin | 16 | 215 | 231 |
| clarithromycin | 19 | 16 | 35 |
| nicotinamide | 28 | 4 | 32 |
| clofazimine | 16 | 1 | 17 |
| gatifloxacin | 8 | 0 | 8 |
| amoxicillin_clavulanate | 3 | 0 | 3 |

This stage is model-independent, so these counts are the real cohort and carry
over to a full run unchanged. Written to `tb_cohort.json`.

## Stage 2 — predict rifampicin (8m20s, 4 isolates)

`rifampicin: 3 answered of 4, 1 unknown`

| metric | value |
|---|---|
| accuracy | 0.667 |
| sensitivity | 1.0 |
| specificity | 0.0 |
| PPV | 0.667 |
| NPV | None (no S calls made) |
| confusion | R→R 2, R→S 0, S→R 1, S→S 0 |

Trace checks: **1.0 valid of 4 graded** — 0.0 hallucinated variants, 0.0
off-panel genes, 0.0 ungrounded R calls, tier-1 support 1.0. Thinking captured
for 1.0 of graded calls, median 1,541 words.

Per isolate:

| isolate | DST | variants shown | call | outcome |
|---|---|---|---|---|
| SAMEA3258487 | R | `rpoB D435V`, `rpoB A1075A` syn | resistant, high | hit |
| SAMEA3558779 | R | `rpoB P45A`, `rpoB S450L`, `rpoC A542A` syn | resistant, high | hit |
| SAMEA3220395 | S | `rpoB A1075A` syn only | **unknown**, low | not answered |
| SAMN03647287 | S | `rpoB -61` promoter, two syn | **resistant**, high | miss |

What this says, with the sample size in mind: the agent never cited a variant
that was not in the prompt and never reached outside the WHO panel, and it
applied the synonymous-variant rule correctly in prose every time. Its two
failures are both on the susceptible side.

- On SAMEA3220395 it reasoned correctly that a synonymous variant is not
  evidence, then returned `unknown` rather than `not_resistant` — the prompt
  tells it absence is evidence too, and it did not act on that.
- On SAMN03647287 it asserted that `rpoB -61 (promoter) C>T` "is a known
  rifampicin resistance mutation" and called resistant with high confidence
  against a susceptible DST. That is the one substantive reasoning error.

Specificity 0.0 is therefore structural in this run, not noise: neither
susceptible isolate produced a susceptible call.

Written to `tb_resistance_rifampicin.json`.

## Stage 3 — screening (29m23s, 6 papers, batch size 1)

`Verdicts: 1 TB-related, 2 not, 3 unknown`

Against `eval/screening_gold.json`: **1.0 accuracy on 3 answered of 6
labelled; wrong: none; abstained:** `2026.01.16.696667v3.full.pdf`,
`2026.01.30.702134v1.full.pdf`, `2026.05.12.724604v1.full.pdf`.

| batch | document | verdict |
|---|---|---|
| 1/6 | 2026.01.16.696667v3.full.pdf | `[??]` agent call failed |
| 2/6 | 2026.01.30.702134v1.full.pdf | `[??]` agent call failed |
| 3/6 | 2026.05.12.724604v1.full.pdf | `[??]` agent call failed |
| 4/6 | 2405.17631v3.pdf | not TB (low) — AI agent for genetic perturbation experiments |
| 5/6 | 2606.12736v1.pdf | not TB (low) — AI agents for scientific research |
| 6/6 | nihms-2147410.pdf | **TB** (high) — WHO TB mutation-catalogue benchmarking |

The three abstentions were not judgment calls. All three failed identically:

```
! agent call 1/6 failed, marking batch unknown: Error code: 400 -
  This model's maximum context length is 32768 tokens. However, your prompt
  contains at least 32769 input tokens, which exceeds this limit even without
  any output tokens.
  hint: A1's system prompt is ~35k tokens; serve the model with a larger
        --max-model-len, or cut --batch-size / --max-chars
```

Over by a single token, on the three longest excerpts. This is the budget the
demo script is explicitly trading away: the tool retriever cuts the peak prompt
to ~13k so the job fits a 16 GB card, but a long document excerpt plus agent
history still lands on the 32,768 ceiling.

## The dominant cost was format thrash, not reasoning

Error counts across the log:

| pattern | count |
|---|---|
| `<observation>Error: name 'false' is not defined</observation>` | 74 |
| `parsing error... / no tags in the current response` | 8 |
| `<observation>Error: invalid syntax (<string>, line 1)</observation>` | 2 |

The failure shape is consistent: the 8B writes a correct JSON verdict and wraps
it in `<execute>` instead of `<solution>`, so the harness executes it as Python,
where JSON `false` is an undefined name and a bare `{` is a syntax error. The
agent then re-emits the identical block, sometimes a dozen times, until the
retry budget runs out. Most of the 29 minutes screening spent on six abstracts
went here rather than into reasoning — the 8B's weaker instruction-following is
the documented cost of the demo sizing.

## How a full run differs

The full run is `./run_experiment.sh` on `scripts/run_unity_a100.sbatch`
(`gpu-highvram`, `--gres=gpu:a100:1`, 8h, 16 cores, 96G).

| | demo 2149968 | full run (defaults) |
|---|---|---|
| card | A16 15 GB, sm_86, preemptible | A100 40/80 GB, non-preemptible |
| model | Qwen3-8B-AWQ (~6 GB) | **Qwen3-32B-AWQ** (~18 GB) |
| `MAX_MODEL_LEN` | 32,768 | **65,536** |
| `TOOLS` | 1 (retriever, ~13k peak prompt) | **0 — all 218 tools in the system prompt, ~39k tokens/step** |
| drugs | rifampicin | **rifampicin, isoniazid, ethambutol, pyrazinamide** |
| `LIMIT` | 4 isolates | **20 per drug** (80 predictions) |
| effort | low | **high** |
| screening `BATCH_SIZE` | 1 | **2** documents per call |
| walltime | 1h (used ~40m) | 8h |

What changes in the numbers, and what does not:

- **Cohort is identical.** No model involved; the 17,942/4,228 split and the
  per-drug R/S table above are the full-run cohort already. Only the sampling
  on top of it changes.
- **Resistance metrics become readable.** 4 graded calls → 80, balanced across
  four drugs. Every rate in stage 2 currently moves in steps of 0.25 or 0.33;
  at n=20 per drug a specificity figure starts to mean something. Expect the
  demo's accuracy 0.667 / specificity 0.0 to move substantially — and expect
  per-drug differences, since rifampicin (`rpoB`, one dominant hotspot) is the
  easiest of the four and pyrazinamide (`pncA`, loss of function) the hardest.
- **The screening context failures should disappear.** 65,536 context clears
  A1's ~39k untruncated system prompt with room for two document excerpts, so
  the three `[??]` abstentions become real verdicts and screening is scored on
  6 of 6 rather than 3 of 6. Note the demo got 1.0 accuracy on what it did
  answer, so the full run's screening score is a genuinely new number, not a
  refinement of this one.
- **Format thrash should drop sharply.** The 74 `false is not defined` loops
  are the 8B mishandling the `<execute>` / `<solution>` protocol; the 32B
  follows tool and tag conventions far more reliably. This is also where the
  wall-clock saving comes from, offsetting the larger model.
- **Tool coverage widens.** With `TOOLS=0` the agent sees all 218 tools rather
  than a retrieved subset, so a `--search` run can reach a tool this demo was
  never offered.
- **Runtime grows by roughly an order of magnitude.** 20× the predictions, 4
  drugs, high effort and a 32B on a faster card; the 8h walltime is sized for
  that, and the demo's ~40 min is no guide to it.

Everything structural is the same in both: the same cohort join, the same
variant naming and WHO tier-1/tier-2 panel filtering, the same three mechanical
trace checks (hallucinated variants, off-panel genes, ungrounded R calls), the
same `gpu_timeline.csv` / `server_timeline.csv` monitoring, and the same run
folder with `SUMMARY.md`, `metrics.csv` and the appended `results/runs.csv`.

## Fixes this run points to

1. Raise `MAX_MODEL_LEN` past ~40k, or cut `--batch-size` / `--max-chars`, so
   screening stops losing documents to a one-token overrun. On a 16 GB card the
   second option is the only one available.
2. Parse `<execute>` blocks that contain JSON instead of `eval`-ing them, and
   state in the prompt that JSON answers belong in `<solution>`. That removes
   the 74-iteration loops without touching the model.
3. Make the susceptible rule explicit in the resistance prompt — no
   non-synonymous variant in any panel gene means `not_resistant`, not
   `unknown` — so specificity is not structurally zero.
4. Bootstrap the vLLM venv in a separate CPU-only job. The companion quick run
   (`logs/tb-quick-2010370.out`, Qwen3-14B-AWQ, limit=8, effort=medium) spent
   its whole allocation on the first-run install and was cancelled mid-wheel
   build, producing no pipeline output at all.
