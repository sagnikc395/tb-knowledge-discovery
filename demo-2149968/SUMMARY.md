# TB agentic search — run `demo-2149968`

| | |
| --- | --- |
| started | 2026-11-23T06:19:28 |
| model | `Qwen/Qwen3-8B-AWQ` |
| reasoning effort | low |
| isolates per drug | 4 (balanced R/S) |
| sampling seed | 0 |
| host | gpu048, Slurm job 2149968 |
| commit | `28275d546d13` (uncommitted changes) |

GPU: NVIDIA A16, 15356 MiB, 595.91.07

## Run monitoring

| stage | status | exit | started | duration |
| --- | --- | ---: | --- | ---: |
| cohort | ok | 0 | 2026-11-23T06:19:29 | 2m13s |
| predict rifampicin | ok | 0 | 2026-11-23T06:21:42 | 8m20s |
| screening | ok | 0 | 2026-11-23T06:30:02 | 29m23s |

Total stage time: 39m56s.

159 GPU sample(s); utilisation mean 91%, peak 100%, idle (<5%) 9% of the time; memory peak 12874 MiB of 15356 MiB.

159 server sample(s); generation mean 19 tok/s, peak 29 tok/s; queue peak 0 request(s).

Full timelines in `logs/gpu_timeline.csv` and `logs/server_timeline.csv`.

## Resistance prediction

Accuracy is over answered isolates only, so abstentions show up as a lower *answered* rather than as wrong calls. Sensitivity is the clinical number: a missed resistant isolate is a patient put on a drug that will not work. *Trace valid* and *hallucinated* grade the model's own reasoning against the VCF it was given — a run can be accurate and still be reasoning from variants that were never there.

| drug | isolates | answered | accuracy | sensitivity | specificity | trace valid | hallucinated | thinking |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| rifampicin | 4 | 3 | 66.7% | 100.0% | 0.0% | 100.0% | 0.0% | 100.0% |

## Literature screening

1 TB-related, 2 not, 3 unknown, over `papers`.

Against eval/screening_gold.json: 1.0 accuracy on 3 answered of 6 labelled; wrong: none; abstained: ['2026.01.16.696667v3.full.pdf', '2026.01.30.702134v1.full.pdf', '2026.05.12.724604v1.full.pdf']

## Cohort

17942 isolate(s) with a VCF; 4228 table row(s) had none.

| drug | resistant | susceptible | total |
| --- | ---: | ---: | ---: |
| rifampicin | 4869 | 12713 | 17582 |

## What is in this folder

| file | what it holds |
| --- | --- |
| `SUMMARY.md` | this file |
| `metrics.csv` | the per-drug scores above, plus the confusion counts |
| `tb_resistance_<drug>.json` | every prediction: variants given, call made, reasoning trace, trace grade |
| `tb_verdicts.json` | the screening verdict for each document |
| `tb_cohort.json` | the isolate/phenotype join the predictions sampled from |
| `run_metadata.json` | model, commit, seed, host — what the numbers are of |
| `logs/` | the full stdout of every stage |
| `logs/stages.jsonl` | per stage: exit code, start time, duration |
| `logs/gpu_timeline.csv` | utilisation, memory, power and temperature per tick |
| `logs/server_timeline.csv` | vLLM requests running/queued, KV cache, tok/s |
