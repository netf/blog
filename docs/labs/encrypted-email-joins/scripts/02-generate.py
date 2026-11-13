"""Generate synthetic customers (Python, seeded) and orders (Postgres SQL) in database `shop`.

Usage: 02-generate.py [n_customers] [n_orders]   (defaults 10_000_000 and 50_000_000)
Everything is synthetic. No real names, addresses or numbers.
"""
import itertools
import random
import sys
import time

import psycopg

from names import (COMPANY_SHARE, FREE_DOMAINS, PATTERNS, company_domains, first_names,
                   last_names, render, zipf_weights)

DSN = "host=localhost dbname=shop user=lab password=lab"

# A UK-based shop. The attacker in the frequency demo knows roughly this, not exactly.
COUNTRIES = [("GB", 41.0), ("US", 14.0), ("DE", 8.0), ("FR", 7.0), ("IE", 5.0), ("NL", 4.0),
             ("ES", 3.5), ("IT", 3.0), ("PL", 2.5), ("SE", 2.0), ("BE", 1.6), ("CA", 1.5),
             ("AU", 1.3), ("DK", 1.0), ("NO", 0.9), ("CH", 0.8), ("AT", 0.7), ("PT", 0.6),
             ("FI", 0.5), ("NZ", 0.4), ("CZ", 0.35), ("GR", 0.3), ("HU", 0.25), ("RO", 0.2),
             ("JP", 0.15), ("SG", 0.12), ("IN", 0.1), ("BR", 0.08), ("MX", 0.06), ("ZA", 0.05)]
PLANS = [("free", 70), ("pro", 25), ("team", 5)]


def cum(ws):
    return list(itertools.accumulate(ws))


def customers(n, seed=42):
    rng = random.Random(seed)
    fn, ln, comp = first_names(), last_names(), company_domains()
    firsts = rng.choices(fn, cum_weights=cum(zipf_weights(len(fn))), k=n)
    lasts = rng.choices(ln, cum_weights=cum(zipf_weights(len(ln))), k=n)
    pats = rng.choices([p for p, _ in PATTERNS], cum_weights=cum([w for _, w in PATTERNS]), k=n)
    dom_pop = [d for d, _ in FREE_DOMAINS] + ["<company>"]
    doms = rng.choices(dom_pop, cum_weights=cum([w for _, w in FREE_DOMAINS] + [COMPANY_SHARE]), k=n)
    ctry = rng.choices([c for c, _ in COUNTRIES], cum_weights=cum([w for _, w in COUNTRIES]), k=n)
    plans = rng.choices([p for p, _ in PLANS], cum_weights=cum([w for _, w in PLANS]), k=n)
    seen = set()
    for i in range(n):
        dom = doms[i] if doms[i] != "<company>" else rng.choice(comp)
        local = render(pats[i], firsts[i], lasts[i], rng)
        email = f"{local}@{dom}"
        k = 1
        while email in seen:
            email = f"{local}{k}@{dom}"
            k += 1
        seen.add(email)
        # Bijective map of i onto 9-digit numbers, so phones are unique: +447 + 9 digits.
        phone = "+447%09d" % ((i * 982_451_653 + 123_456_789) % 1_000_000_000)
        yield (i + 1, email, phone, ctry[i], plans[i], f"20{18 + i % 8}-{1 + i % 12:02d}-{1 + i % 28:02d}")


def main():
    n_cust = int(sys.argv[1]) if len(sys.argv) > 1 else 10_000_000
    n_ord = int(sys.argv[2]) if len(sys.argv) > 2 else 50_000_000
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute("drop table if exists orders; drop table if exists customers")
        conn.execute("""create table customers (
            customer_id bigint primary key, email text not null unique, phone text not null,
            country text not null, plan text not null, signup_date date not null)""")
        t = time.time()
        with conn.cursor().copy("copy customers from stdin") as cp:
            for row in customers(n_cust):
                cp.write_row(row)
        print(f"customers: {n_cust} rows in {time.time() - t:.0f}s", flush=True)

        t = time.time()
        conn.execute("set work_mem = '1GB'")
        conn.execute("select setseed(0.42)")
        conn.execute("""create table orders as
            with o as (
              select g as order_id,
                     -- skewed: a minority of customers place most orders
                     1 + floor(%s * power(random(), 2))::bigint as cid,
                     (500 + floor(random() * 20000))::int as amount_pence,
                     timestamp '2024-01-01' + random() * interval '700 days' as ordered_at,
                     (array['paid','paid','paid','refunded','cancelled'])[1 + floor(random()*5)::int] as status
              from generate_series(1, %s) g)
            select o.order_id, c.email as customer_email, o.amount_pence, o.ordered_at, o.status
            from o join customers c on c.customer_id = o.cid
            order by o.order_id""", (n_cust, n_ord))
        conn.execute("alter table orders add primary key (order_id)")
        conn.execute("vacuum analyze customers")
        conn.execute("vacuum analyze orders")
        print(f"orders: {n_ord} rows in {time.time() - t:.0f}s", flush=True)
        for r in conn.execute("""select relname, pg_size_pretty(pg_total_relation_size(oid)), reltuples::bigint
                                 from pg_class where relname in ('customers','orders')"""):
            print("size", *r)


if __name__ == "__main__":
    main()
