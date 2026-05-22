#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

import jsonschema


def load_json(path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(
        description="Validate wp_adjust calibration JSON files against a schema."
    )
    parser.add_argument(
        "--schema",
        default="host/schema/wp-cal-v1.schema.json",
        help="Path to the calibration JSON schema.",
    )
    parser.add_argument(
        "profiles",
        nargs="+",
        help="Calibration JSON profile(s) to validate.",
    )
    args = parser.parse_args()

    schema_path = Path(args.schema)
    schema = load_json(schema_path)
    jsonschema.Draft7Validator.check_schema(schema)
    validator = jsonschema.Draft7Validator(schema)

    failed = False
    for profile_arg in args.profiles:
        profile_path = Path(profile_arg)
        profile = load_json(profile_path)
        errors = sorted(validator.iter_errors(profile), key=lambda e: list(e.path))
        if errors:
            failed = True
            for error in errors:
                location = ".".join(str(part) for part in error.path) or "<root>"
                print(f"{profile_path}: {location}: {error.message}")
        else:
            print(f"{profile_path}: ok")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
