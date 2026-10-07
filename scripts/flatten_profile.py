#!/usr/bin/env python3
"""Flatten vendor presets for the command-line slicer.

`snapmaker-orca --load-settings/--load-filaments` reads a preset JSON as-is and does not follow
"inherits", so a system preset passed straight from resources/profiles/<Vendor>/ lacks every value
it inherits (e.g. filament_density -> 0 g reported). This resolves the inherits chain the same way
the GUI does (child keys override parent keys; parents are looked up by name in <Vendor>.json) and
writes self-contained presets.

  scripts/flatten_profile.py -o /tmp/u1 \
      --machine "Snapmaker U1 (0.4 nozzle)" \
      --process "0.20mm Standard @Snapmaker U1 (0.4 nozzle)" \
      --filament "Snapmaker PLA Basic @U1"

prints the written paths; pass them to --load-settings "machine;process" and --load-filaments.
"""

import argparse
import json
import sys
from pathlib import Path

LISTS = {"machine": "machine_list", "process": "process_list", "filament": "filament_list"}


def load_index(vendor_json: Path) -> dict[tuple[str, str], Path]:
    vendor = json.loads(vendor_json.read_text(encoding="utf-8"))
    vendor_dir = vendor_json.with_suffix("")
    return {
        (kind, entry["name"]): vendor_dir / entry["sub_path"]
        for kind, key in LISTS.items()
        for entry in vendor.get(key, [])
    }


def flatten(index: dict[tuple[str, str], Path], kind: str, name: str) -> dict:
    chain = []
    seen = set()
    while name:
        if name in seen:
            raise SystemExit(f"inherits cycle at {kind} '{name}'")
        seen.add(name)
        path = index.get((kind, name))
        if path is None:
            raise SystemExit(f"{kind} preset '{name}' not found in vendor index")
        preset = json.loads(path.read_text(encoding="utf-8"))
        chain.append(preset)
        name = preset.get("inherits", "")

    merged: dict = {}
    for preset in reversed(chain):
        merged.update(preset)
    merged.pop("inherits", None)
    if merged.get("instantiation") == "false":
        print(f"warning: {kind} '{chain[0]['name']}' is an abstract base preset", file=sys.stderr)
    return merged


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vendor", default="Snapmaker", help="vendor under resources/profiles (default: Snapmaker)")
    parser.add_argument("--profiles", type=Path, default=root / "resources" / "profiles")
    parser.add_argument("-o", "--outdir", type=Path, required=True)
    for kind in LISTS:
        parser.add_argument(f"--{kind}", action="append", default=[], metavar="NAME")
    args = parser.parse_args()

    index = load_index(args.profiles / f"{args.vendor}.json")
    args.outdir.mkdir(parents=True, exist_ok=True)
    for kind in LISTS:
        for name in getattr(args, kind):
            out = args.outdir / f"{kind}-{name.replace('/', '_')}.json"
            out.write_text(json.dumps(flatten(index, kind, name), indent=4, ensure_ascii=False), encoding="utf-8")
            print(out)


if __name__ == "__main__":
    main()
