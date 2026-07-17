"""Argparse CLI for the ledger tool."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import store as _store


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ledger",
        description="A simple CLI for storing text entries in a local JSON file.",
    )
    parser.add_argument(
        "--data",
        default="ledger.json",
        metavar="FILE",
        help="Path to the JSON data file (default: ledger.json in CWD).",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # add
    add_p = sub.add_parser("add", help="Append a new entry.")
    add_p.add_argument("text", help="Text of the entry to add.")

    # list
    sub.add_parser("list", help="Print all entries as JSON Lines to stdout.")

    return parser


def cmd_add(args: argparse.Namespace) -> int:
    data_file = Path(args.data)
    entry = _store.add_entry(data_file, args.text)
    print(json.dumps(entry))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    data_file = Path(args.data)
    entries = _store.list_entries(data_file)
    for entry in entries:
        print(json.dumps(entry))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "add":
        return cmd_add(args)
    if args.command == "list":
        return cmd_list(args)

    return 0  # unreachable; argparse required=True handles unknown subcommands
