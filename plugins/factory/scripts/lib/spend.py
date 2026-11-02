#!/usr/bin/env python3
"""Prices a Claude Code transcript (JSONL) from the usage each assistant message records.

  spend.py <transcript.jsonl> <prices.json>
      Prints JSON: {"usd", "messages", "tokens": {...}, "by_model": {model: usd}, "unpriced_models": [...]}

Each assistant message is counted once (transcripts repeat a message's usage on every content-block
line; the last line for a message id wins). Cache writes are split into 5-minute and 1-hour tiers from
usage.cache_creation when present, else counted as 5-minute. usage.speed == "fast" applies the model's
fast_multiplier; usage.inference_geo == "us" applies us_inference_multiplier. Haiku prompts over its
threshold use the long-prompt prices. Models missing from the table are listed, not priced.
This is an estimate: it doesn't price server tools (web search) or batch discounts.
"""
import json
import sys


def price_for(models, model):
    for key in sorted(models, key=len, reverse=True):
        if model == key or model.startswith(key + "-") or model.startswith(key + "["):
            return models[key]
    return None


def main(argv):
    if len(argv) != 3:
        print("usage: spend.py <transcript.jsonl> <prices.json>", file=sys.stderr)
        return 2
    with open(argv[2], encoding="utf-8") as f:
        table = json.load(f)
    models = table["models"]
    us_mult = float(table.get("us_inference_multiplier", 1.0))
    last = {}
    try:
        with open(argv[1], encoding="utf-8") as f:
            for i, line in enumerate(f):
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                m = o.get("message") if isinstance(o, dict) else None
                if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
                    continue
                key = m.get("id") or o.get("requestId") or f"line{i}"
                last[key] = (m.get("model") or "unknown", m["usage"])
    except OSError as e:
        print(f"spend: {argv[1]}: {e.strerror}", file=sys.stderr)
        return 2

    tokens = {"input": 0, "cache_write_5m": 0, "cache_write_1h": 0, "cache_read": 0, "output": 0}
    by_model, unpriced, usd = {}, set(), 0.0
    for model, u in last.values():
        cc = u.get("cache_creation") or {}
        w1h = int(cc.get("ephemeral_1h_input_tokens") or 0)
        w5m = int(cc.get("ephemeral_5m_input_tokens") or 0)
        if not cc:
            w5m = int(u.get("cache_creation_input_tokens") or 0)
        t = {
            "input": int(u.get("input_tokens") or 0),
            "cache_write_5m": w5m,
            "cache_write_1h": w1h,
            "cache_read": int(u.get("cache_read_input_tokens") or 0),
            "output": int(u.get("output_tokens") or 0),
        }
        for k in tokens:
            tokens[k] += t[k]
        p = price_for(models, model)
        if p is None:
            if model not in ("<synthetic>", "unknown"):
                unpriced.add(model)
            continue
        rates = p
        thr = p.get("long_prompt_threshold")
        if thr and t["input"] + t["cache_read"] + t["cache_write_5m"] + t["cache_write_1h"] > thr:
            rates = p["long"]
        cost = sum(t[k] * float(rates[k]) for k in tokens) / 1_000_000
        if u.get("speed") == "fast":
            cost *= float(p.get("fast_multiplier", 1.0))
        if str(u.get("inference_geo", "")).lower() == "us":
            cost *= us_mult
        usd += cost
        by_model[model] = round(by_model.get(model, 0.0) + cost, 6)
    json.dump({
        "usd": round(usd, 6),
        "messages": len(last),
        "tokens": tokens,
        "by_model": by_model,
        "unpriced_models": sorted(unpriced),
    }, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
