"""Compact output: one line per object, tab-separated, under one header line.
--json prints the full objects instead."""

import json


def cell(value):
    if value is None or value == "":
        return "-"
    if isinstance(value, bool):
        return "yes" if value else "no"
    # A value never breaks its line or shifts its columns.
    return " ".join(str(value).split())


def table(rows, cols):
    """rows: dicts, cols: the keys to print, in order. No rows, no output."""
    if not rows:
        return ""
    lines = ["\t".join(cols)]
    lines.extend("\t".join(cell(row.get(col)) for col in cols) for row in rows)
    return "\n".join(lines)


def as_json(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)
