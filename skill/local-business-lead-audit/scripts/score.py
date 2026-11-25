#!/usr/bin/env python3
"""Check rubric parts in a leads CSV, total both scores and assign grades.

No network use. Reads the CSV, writes <name>_scored.csv next to it, and prints
a summary. Usage: python3 scripts/score.py leads.csv
"""
import csv
import sys
from pathlib import Path

DIGITAL = {"dp_website": 20, "dp_seo": 20, "dp_social": 20, "dp_brand": 15,
           "dp_content": 15, "dp_conversion": 10}
COMMERCIAL = {"co_problems": 20, "co_value": 20, "co_social": 15, "co_web": 15,
              "co_growth": 10, "co_contact": 10, "co_fit": 10}


def grade(score: int) -> str:
    if score >= 80:
        return "A"
    if score >= 65:
        return "B"
    if score >= 45:
        return "C"
    return "Low"


def total(row: dict, parts: dict, problems: list) -> int:
    s = 0
    for col, cap in parts.items():
        raw = (row.get(col) or "").strip()
        try:
            v = int(float(raw)) if raw else 0
        except ValueError:
            problems.append(f"{row.get('business')}: {col}={raw!r} is not a number")
            v = 0
        if not 0 <= v <= cap:
            problems.append(f"{row.get('business')}: {col}={v} outside 0-{cap}, clamped")
            v = max(0, min(v, cap))
        s += v
    return s


def main(path: str) -> None:
    src = Path(path)
    with src.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        fields = list(reader.fieldnames or [])
    problems: list = []
    for r in rows:
        r["digital_score"] = total(r, DIGITAL, problems)
        r["commercial_score"] = total(r, COMMERCIAL, problems)
        r["grade"] = grade(r["commercial_score"])
        if r["grade"] in ("A", "B") and not (r.get("generic_email") or "").strip():
            r["notes"] = ((r.get("notes") or "") + " | no generic email: call list, no draft").strip(" |")
    order = {"A": 0, "B": 1, "C": 2, "Low": 3}
    rows.sort(key=lambda r: (order[r["grade"]], -r["commercial_score"]))
    for extra in ("digital_score", "commercial_score", "grade"):
        if extra not in fields:
            fields.append(extra)
    out = src.with_name(src.stem + "_scored.csv")
    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    counts = {g: sum(1 for r in rows if r["grade"] == g) for g in order}
    print(f"{len(rows)} businesses -> {out.name}")
    print("Grades: " + ", ".join(f"{g} {n}" for g, n in counts.items()))
    for p in problems:
        print("CHECK:", p)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
