"""Reads the outputs of a subscription deployment, whatever casing the Azure CLI gives their names.

Some Azure CLI versions change the case of output names (ACR_NAME comes back as acR_NAME), so scripts look them up
case-insensitively here instead of with az --query.

  python scripts/outputs.py <deployment> ACR_NAME     # one value
  python scripts/outputs.py <deployment> --env        # every text output as NAME=value, for .env
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any


def normalize(outputs: dict[str, Any]) -> dict[str, Any]:
    return {name.upper(): (item or {}).get("value") for name, item in (outputs or {}).items()}


def deployment_outputs(deployment: str) -> dict[str, Any]:
    result = subprocess.run(
        ["az", "deployment", "sub", "show", "-n", deployment, "--query", "properties.outputs", "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
    )
    return normalize(json.loads(result.stdout or "{}"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("deployment")
    parser.add_argument("name", nargs="?", help="output name, in any case")
    parser.add_argument("--env", action="store_true", help="print every text output as NAME=value")
    args = parser.parse_args(argv)
    outputs = deployment_outputs(args.deployment)
    if args.env:
        for name, value in outputs.items():
            if isinstance(value, str):
                print(f"{name}={value}")
        return 0
    if not args.name:
        parser.error("give an output name, or --env")
    if args.name.upper() not in outputs:
        print(f"ERROR no output {args.name} in {args.deployment}", file=sys.stderr)
        return 1
    value = outputs[args.name.upper()]
    print(value if isinstance(value, str) else json.dumps(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
