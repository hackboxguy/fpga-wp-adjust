"""Boot-time calibration loader for wp_adjust profiles."""

from __future__ import annotations

import argparse
import json
import logging
import time
from dataclasses import dataclass
from json import JSONDecodeError
from pathlib import Path
from typing import Any, Callable, Dict, Optional

import jsonschema

from host.wp_registers import (
    DEFAULT_FRAC_BITS,
    DryRunBackend,
    MockWpAdjustBackend,
    Register,
    Status,
    Transaction,
    WpAdjustRegisters,
)


DEFAULT_SCHEMA_PATH = Path(__file__).resolve().parent / "schema" / "wp-cal-v1.schema.json"
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class LoadResult:
    state: str
    status: Status
    transactions: list[Transaction]


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return data


def validate_profile(profile: Dict[str, Any], schema_path: Path = DEFAULT_SCHEMA_PATH) -> None:
    schema = load_json(schema_path)
    jsonschema.Draft7Validator.check_schema(schema)
    jsonschema.Draft7Validator(schema).validate(profile)


def load_profile(path: Path, schema_path: Path = DEFAULT_SCHEMA_PATH) -> Dict[str, Any]:
    profile = load_json(path)
    validate_profile(profile, schema_path=schema_path)
    return profile


def apply_profile(
    regs: WpAdjustRegisters,
    profile: Dict[str, Any],
    allow_pending_until_video: bool = True,
    timeout_sec: float = 0.0,
    poll_interval_sec: float = 0.02,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> LoadResult:
    """Load a v1 profile and enable wp_adjust.

    V1 profiles are calibration profiles, not pass-through profiles; this helper
    always writes CONTROL.enable=1. Use DEFAULTS for explicit pass-through.
    """

    expected_frac_bits = int(profile["fpga"].get("frac_bits", DEFAULT_FRAC_BITS))
    status = regs.probe(expected_frac_bits=expected_frac_bits)
    if status.commit_pending:
        raise RuntimeError("refusing to load calibration while commit is already pending")

    offsets = profile.get("offsets", {})
    regs.write_calibration(
        gains={channel: int(profile["gains"][channel]) for channel in ("r", "g", "b")},
        offsets={channel: int(offsets.get(channel, 0)) for channel in ("r", "g", "b")},
        offset_enable=bool(offsets.get("enabled", False)),
        enable=True,
    )

    post_status = _poll_commit_status(
        regs,
        timeout_sec=max(0.0, timeout_sec),
        poll_interval_sec=max(0.0, poll_interval_sec),
        sleep_fn=sleep_fn,
    )
    if post_status.commit_consumed:
        state = "committed"
    elif post_status.commit_pending and allow_pending_until_video:
        state = "pending_until_video"
    elif post_status.commit_pending:
        raise TimeoutError("commit is pending and video/vsync has not consumed it")
    else:
        state = "commit_status_unknown"

    return LoadResult(
        state=state,
        status=post_status,
        transactions=_backend_transactions(regs),
    )


def make_dry_run_registers() -> WpAdjustRegisters:
    backend = DryRunBackend(
        reads={
            Register.ID: 0x57A1,
            Register.VERSION: 0x0112,
            Register.STATUS: 0x0C00,
        }
    )
    return WpAdjustRegisters(backend)


def make_mock_registers() -> WpAdjustRegisters:
    return WpAdjustRegisters(MockWpAdjustBackend())


def _poll_commit_status(
    regs: WpAdjustRegisters,
    timeout_sec: float,
    poll_interval_sec: float,
    sleep_fn: Callable[[float], None],
) -> Status:
    deadline = time.monotonic() + timeout_sec

    while True:
        status = regs.read_status()
        if status.commit_consumed or not status.commit_pending:
            return status
        if timeout_sec <= 0.0 or time.monotonic() >= deadline:
            return status
        sleep_fn(min(poll_interval_sec, max(0.0, deadline - time.monotonic())))


def main(argv: Optional[list[str]] = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s:%(message)s")

    parser = argparse.ArgumentParser(description="Load a wp_adjust calibration profile.")
    parser.add_argument("--cal", required=True, type=Path, help="Calibration JSON path.")
    parser.add_argument(
        "--schema",
        type=Path,
        default=DEFAULT_SCHEMA_PATH,
        help="Calibration schema path.",
    )
    parser.add_argument(
        "--backend",
        choices=("dry-run", "mock"),
        default="dry-run",
        help="Backend to use. Hardware backends are board-specific and added later.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_const",
        dest="backend",
        const="dry-run",
        help="Alias for --backend dry-run.",
    )
    parser.add_argument(
        "--timeout-sec",
        type=float,
        default=0.0,
        help="Seconds to poll for commit-consumed before reporting pending-until-video.",
    )
    parser.add_argument(
        "--poll-interval-sec",
        type=float,
        default=0.02,
        help="Seconds between commit status polls.",
    )
    parser.add_argument(
        "--strict-commit",
        action="store_true",
        help="Treat pending-until-video as a failure.",
    )
    args = parser.parse_args(argv)

    try:
        profile = load_profile(args.cal, schema_path=args.schema)
        regs = (
            make_mock_registers()
            if args.backend == "mock"
            else make_dry_run_registers()
        )
        result = apply_profile(
            regs,
            profile,
            allow_pending_until_video=not args.strict_commit,
            timeout_sec=args.timeout_sec,
            poll_interval_sec=max(0.001, args.poll_interval_sec),
        )
    except OSError as exc:
        LOGGER.warning("calibration unavailable; not applying calibration: %s", exc)
        return 2
    except (
        JSONDecodeError,
        ValueError,
        jsonschema.SchemaError,
        jsonschema.ValidationError,
    ) as exc:
        LOGGER.error("invalid calibration; not applying calibration: %s", exc)
        return 3
    except (RuntimeError, TimeoutError) as exc:
        LOGGER.error("failed to load calibration: %s", exc)
        return 4

    LOGGER.info("state=%s", result.state)
    for transaction in result.transactions:
        if transaction.value is None:
            LOGGER.info("%s 0x%02X", transaction.op, transaction.addr)
        else:
            LOGGER.info(
                "%s 0x%02X 0x%04X",
                transaction.op,
                transaction.addr,
                transaction.value,
            )
    return 0


def _backend_transactions(regs: WpAdjustRegisters) -> list[Transaction]:
    transactions = getattr(regs.backend, "transactions", None)
    return list(transactions or [])


if __name__ == "__main__":
    raise SystemExit(main())
