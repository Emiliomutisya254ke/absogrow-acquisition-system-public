#!/usr/bin/env python3
"""Mobile PageSpeed test for one or more URLs.

Network use (disclosed): calls only Google's public PageSpeed Insights API,
https://www.googleapis.com/pagespeedonline/v5/runPagespeed
An API key is optional; set PAGESPEED_API_KEY to raise Google's rate limit.

Usage: python3 scripts/pagespeed.py https://example.com [https://other.com ...]
Output: one JSON line per URL with score, LCP, TBT and CLS.
"""
import json
import os
import sys
import urllib.parse
import urllib.request

API = "https://www.googleapis.com/pagespeedonline/v5/runPagespeed"


def run(url: str) -> dict:
    params = {"url": url, "strategy": "mobile", "category": "performance"}
    key = os.environ.get("PAGESPEED_API_KEY")
    if key:
        params["key"] = key
    req = API + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.load(resp)
    except Exception as exc:  # report, never crash the batch
        return {"url": url, "error": str(exc)}
    lh = data.get("lighthouseResult", {})
    audits = lh.get("audits", {})
    score = lh.get("categories", {}).get("performance", {}).get("score")

    def num(audit_id):
        return audits.get(audit_id, {}).get("numericValue")

    lcp = num("largest-contentful-paint")
    tbt = num("total-blocking-time")
    return {
        "url": url,
        "performance_score": round(score * 100) if score is not None else None,
        "lcp_seconds": round(lcp / 1000, 1) if lcp is not None else None,
        "tbt_ms": round(tbt) if tbt is not None else None,
        "cls": num("cumulative-layout-shift"),
        "fetched": lh.get("fetchTime"),
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for u in sys.argv[1:]:
        print(json.dumps(run(u)))
