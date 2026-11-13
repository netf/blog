"""Dictionary attack on the email column: hashed vs encrypted warehouse.

The attacker has a copy of customers.parquet (hashed or tokenized) and builds a dictionary of
candidate emails from popular names in common patterns and domains. They never see the real
customer list. Scenarios:

  sha256_salt_known     the salt is a value in the pipeline's config, like most join salts
  sha256_salt_unknown   the attacker guesses plain sha256(email)
  daead_no_key          the attacker has no keyset: tries sha256 forms and a fresh AES-SIV key
  daead_pipeline_key    the attacker holds the ingestion job's keyset (or tokenize access)

upper_bound is how many customers' plaintext emails are in the dictionary at all.

    attack_dictionary.py [N_CANDIDATES] > results/attack/dictionary-runN.json
"""
import hashlib
import json
import pathlib
import random
import sys
import time

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq
import tink
from tink import daead

import keys
from names import FREE_DOMAINS, GUESSABLE, company_domains, first_names, last_names, render, zipf_weights

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"
COMPANY_DOMAINS_GUESSED = 200


def candidate_emails(n, seed=99):
    rng = random.Random(seed)
    fn, ln = first_names(), last_names()
    domains = [d for d, _ in FREE_DOMAINS] + company_domains()[:COMPANY_DOMAINS_GUESSED]
    dom_w = [w for _, w in FREE_DOMAINS] + [0.0005] * COMPANY_DOMAINS_GUESSED
    seen = set()
    k = n * 2
    while len(seen) < n:
        firsts = rng.choices(fn, weights=zipf_weights(len(fn)), k=k)
        lasts = rng.choices(ln, weights=zipf_weights(len(ln)), k=k)
        pats = rng.choices(GUESSABLE, k=k)
        doms = rng.choices(domains, weights=dom_w, k=k)
        for f, l, p, d in zip(firsts, lasts, pats, doms):
            seen.add(f"{render(p, f, l, rng)}@{d}")
            if len(seen) >= n:
                break
    return sorted(seen)


def matches(col, guesses):
    t = time.perf_counter()
    present = pc.is_in(col, value_set=pa.array(guesses, col.type))
    n = pc.sum(present).as_py() or 0
    return n, time.perf_counter() - t


def timed(fn, cand):
    t = time.perf_counter()
    g = [fn(e.encode()) for e in cand]
    return g, time.perf_counter() - t


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10_000_000
    t = time.perf_counter()
    cand = candidate_emails(n)
    out = {"candidates": len(cand), "dictionary_build_s": round(time.perf_counter() - t, 1)}

    plain = pq.read_table(WH / "plain" / "customers.parquet", columns=["email"]).column("email")
    hit, _ = matches(plain, cand)
    out["warehouse_rows"] = len(plain)
    out["upper_bound"] = {"rows": hit, "pct": round(hit / len(plain) * 100, 2)}
    del plain

    hashed = pq.read_table(WH / "sha256" / "customers.parquet", columns=["email"]).column("email")
    salt = keys.salt()
    g, gs = timed(lambda e: hashlib.sha256(salt + e).digest(), cand)
    hit, ms = matches(hashed, g)
    out["sha256_salt_known"] = {"recovered_rows": hit, "pct": round(hit / len(hashed) * 100, 2),
                                "hash_s": round(gs, 1), "match_s": round(ms, 1), "guesses_per_s": round(len(cand) / gs)}
    g, gs = timed(lambda e: hashlib.sha256(e).digest(), cand)
    hit, ms = matches(hashed, g)
    out["sha256_salt_unknown"] = {"recovered_rows": hit, "hash_s": round(gs, 1)}
    del hashed, g

    tokens = pq.read_table(WH / "daead" / "customers.parquet", columns=["email"]).column("email")
    tried = {}
    for name, fn in (("sha256", lambda e: hashlib.sha256(e).digest()),
                     ("sha256_with_salt", lambda e: hashlib.sha256(salt + e).digest())):
        g, _ = timed(fn, cand)
        tried[name] = matches(tokens, g)[0]
    wrong = tink.new_keyset_handle(daead.deterministic_aead_key_templates.AES256_SIV).primitive(daead.DeterministicAead)
    g, _ = timed(lambda e: wrong.encrypt_deterministically(e, b"email"), cand)
    tried["fresh_aes_siv_key"] = matches(tokens, g)[0]
    out["daead_no_key"] = {"recovered_rows": sum(tried.values()), "tried": tried}

    p = keys.primitive("email")
    g, gs = timed(lambda e: p.encrypt_deterministically(e, b"email"), cand)
    hit, ms = matches(tokens, g)
    out["daead_pipeline_key"] = {"recovered_rows": hit, "pct": round(hit / len(tokens) * 100, 2),
                                 "encrypt_s": round(gs, 1), "match_s": round(ms, 1), "guesses_per_s": round(len(cand) / gs)}
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
