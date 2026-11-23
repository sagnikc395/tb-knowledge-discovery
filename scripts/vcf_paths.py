"""Print the VCF paths one --predict run will read, and nothing else.

The point is the laptop path. The BIG-TB VCFs live in Unity project space, so
running --predict anywhere else means first copying the ones the run will
actually touch — four of them for a demo, not 17,942. Which four is decided by
cohort.dataset(), which is deterministic given the same drug, limit, balance
and seed, so the same arguments that will run the prediction select the files
to bring down:

    # on Unity, or anywhere the cohort files are (they are in the repo)
    uv run scripts/vcf_paths.py rifampicin --limit 4 --balance > vcfs.txt
    rsync -av --no-relative --files-from=vcfs.txt unity.rc.umass.edu:/ ./vcfs/

    uv run cli.py --predict rifampicin --limit 4 --balance --vcf-root ./vcfs

Paths are printed absolute, as the cohort records them, which is what rsync's
--files-from wants against a `:/` source. --no-relative is not optional there:
--vcf-root looks for each VCF as `<root>/<filename>`, so the copy has to land
them flat rather than rebuilding the cluster's directory tree under ./vcfs.
--relative-to prints them relative to a directory instead, for the copy tools
that want that.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tb_search.cohort import CohortError, load_cohort


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("drug")
    parser.add_argument("--limit", type=int, default=4)
    parser.add_argument("--balance", action="store_true")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument(
        "--relative-to",
        help="Print each path relative to this directory instead of absolute.",
    )
    args = parser.parse_args()

    try:
        cohort = load_cohort()
        samples = cohort.dataset(
            args.drug, limit=args.limit, balance=args.balance, seed=args.seed
        )
    except CohortError as e:
        print(e, file=sys.stderr)
        return 1

    if not samples:
        print(f"No labelled isolates for {args.drug!r}.", file=sys.stderr)
        return 1

    for sample in samples:
        path = sample.vcf_path
        if args.relative_to:
            try:
                path = str(Path(path).relative_to(args.relative_to))
            except ValueError:
                print(f"{path} is not under {args.relative_to}", file=sys.stderr)
                return 1
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
