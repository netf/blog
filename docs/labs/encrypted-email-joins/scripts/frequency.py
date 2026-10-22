"""Frequency analysis on a deterministically encrypted low-cardinality column (customers.country).

Deterministic encryption hides values but keeps equality, so the histogram of tokens is the
histogram of countries. An attacker who knows roughly what the distribution looks like (a UK shop,
public market-share figures) labels tokens by rank. The prior is the true mix with every weight
scaled by a random factor in [0.75, 1.33], renormalised, so the attacker is close but not exact.

Control: the same column under randomized AES-GCM (Tink AEAD). Every token is unique, so there is
no histogram to read, and no GROUP BY or join either.

    frequency.py SEEDS > results/frequency/frequency.json
"""
import collections
import importlib
import json
import pathlib
import random
import sys

import pyarrow.compute as pc
import pyarrow.parquet as pq
import tink
from tink import aead

import keys

aead.register()
gen = importlib.import_module("02-generate")

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"


def main():
    seeds = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    country = pq.read_table(WH / "plain" / "customers.parquet", columns=["country"]).column("country").to_pylist()
    n = len(country)
    p = keys.primitive("country")
    tok = [p.encrypt_deterministically(c.encode(), b"country") for c in country]
    truth = dict(zip(tok, country))
    hist = collections.Counter(tok)
    ranked_tokens = [t for t, _ in hist.most_common()]

    out = {"rows": n, "distinct_plaintext": len(set(country)), "distinct_daead_tokens": len(hist), "runs": []}
    for seed in range(seeds):
        rng = random.Random(seed)
        prior = {c: w * rng.uniform(0.75, 1.33) for c, w in gen.COUNTRIES}
        ranked_prior = sorted(prior, key=prior.get, reverse=True)
        guess = dict(zip(ranked_tokens, ranked_prior))
        right_rows = sum(cnt for t, cnt in hist.items() if guess.get(t) == truth[t])
        right_values = sum(1 for t in hist if guess.get(t) == truth[t])
        top5 = sum(1 for t in ranked_tokens[:5] if guess[t] == truth[t])
        out["runs"].append({"seed": seed, "rows_labelled_correctly_pct": round(right_rows / n * 100, 2),
                            "countries_identified": right_values, "top5_correct": top5})

    top = ranked_tokens[0]
    out["only_knowing_gb_is_biggest"] = {"token_prefix_hex": top[:8].hex(), "is": truth[top],
                                         "rows_pct": round(hist[top] / n * 100, 2)}

    g = tink.new_keyset_handle(aead.aead_key_templates.AES256_GCM).primitive(aead.Aead)
    sample = country[:1_000_000]
    rand_tokens = {g.encrypt(c.encode(), b"country") for c in sample}
    out["control_randomized_aead"] = {"rows": len(sample), "distinct_tokens": len(rand_tokens)}

    orders = pq.read_table(WH / "daead" / "orders.parquet", columns=["customer_email"]).column("customer_email")
    vc = pc.value_counts(orders)
    counts = sorted(vc.field("counts").to_pylist(), reverse=True)
    out["email_equality_in_orders"] = {"orders": len(orders), "distinct_tokens": len(counts),
                                       "max_orders_one_token": counts[0], "tokens_with_100plus_orders": sum(1 for c in counts if c >= 100)}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
