---
title: 'I encrypted every email address in the warehouse and the joins still work'
description: 'Salted SHA-256 gave up all 10 million phone numbers in two minutes. I swapped it for Tink AES-SIV on 60 million rows, measured what that costs in CPU, storage, joins and key rotation, and what it still leaks.'
pubDate: 2026-11-13
pillar: data
tags: ['data-platforms', 'security', 'duckdb', 'parquet', 'encryption']
---

It took DuckDB 123 seconds to turn 10 million "anonymised" phone numbers back into phone numbers.
No dictionary, no GPU, one SQL query on a 4 vCPU VM. Every UK mobile number has the shape `+447`
followed by nine digits, so there are only a billion of them, and a billion SHA-256 hashes is a
coffee break.

The column was salted, too. It didn't matter. A join key needs the same salt on every row,
otherwise `customers.email` and `orders.customer_email` stop matching, so the salt sits in the
pipeline config, and anyone who can read the config can run the query.

That's the usual compromise for PII in a warehouse: analysts need to join on email, security
doesn't want plaintext email in the warehouse, so someone hashes it. **A hash is a lookup table
you haven't built yet.** For emails and phone numbers, the attacker builds it.

The alternative people mention and rarely measure is deterministic authenticated encryption:
AES-SIV, [RFC 5297](https://www.rfc-editor.org/rfc/rfc5297). Same input and same key give the same
token, so joins and `GROUP BY` still work, but without the key there's nothing to precompute, and
with the key you can get the plaintext back. I built that into a real ingestion pipeline with
[Tink's deterministic AEAD](https://developers.google.com/tink/deterministic-aead) and asked three
questions:

1. **What does it cost?** Ingest throughput and CPU, Parquet size, and DuckDB join latency, against
   the same pipeline with no tokenization and with salted SHA-256.
2. **What does it stop, and what does it leak?** A dictionary attack on emails, brute force on
   phones, and frequency analysis on a low-cardinality column, because deterministic encryption
   leaks equality by design.
3. **What does running it cost?** A re-identification service gated by role, and rotating a key
   over 60 million rows.

I went in with two hypotheses: tokenized columns compress worse, and rotation, not encryption, is
the expensive part. The first one was right by more than I expected. The second was right in a way
I didn't expect.

**Same rule as always: if I didn't observe it, it isn't here.** Scripts, raw results and a
one-command reproduce live in
[`docs/labs/encrypted-email-joins/`](https://github.com/netf/blog/tree/main/docs/labs/encrypted-email-joins).
Every row of data is synthetic.

## The short version

- **Hashing PII is reversible in practice.** DuckDB brute-forced all 10,000,000 salted SHA-256
  phone hashes in about 2 minutes. A 10-million-entry dictionary recovered every email it
  contained. Against AES-SIV, both attacks recovered 0.
- **Compute is cheap: about 1 extra CPU-second per million rows at ingest,** and joins still
  work, 8% to 38% slower. Most of the join cost is Tink's constant 5-byte key prefix. Without it,
  the 50M × 10M join was 4% slower than plaintext.
- **Storage is the real bill.** The PII columns grew 4.6x (email) and 7.2x (phone), and the
  warehouse grew 2.8x, because a 45-byte random token compresses 1.07x. Sorting orders by the token
  brought that table back to roughly the unsorted plaintext size.
- **Rotation can't be gradual.** A new key gives new tokens, so 0 of 100,000 new rows joined to old
  ones. Rewriting all 60M rows took 141 s, at 2.2x the per-row cost of encrypting them in the
  first place.
- **Equality leaks.** On a 30-value country column, frequency analysis with a rough prior labelled
  83% to 89% of rows. Use deterministic encryption for identifiers, not categories.

## How a token can be both encrypted and joinable

Normal authenticated encryption (AES-GCM, say) picks a fresh random nonce for every message, so
encrypting `ana@gmail.com` twice gives two unrelated ciphertexts. That's the point of it, and it
makes the column useless as a join key.

SIV ("synthetic IV") removes the randomness and derives the IV from the message itself:

```text
                        k_email (64 bytes) = K1 ‖ K2
                                  │
  ad = "email" ─┐                 │
                ├─► S2V(K1, ad, plaintext) ──► SIV  (16 bytes, a CMAC-based PRF)
  plaintext ────┤                                │
                └──────────► AES-CTR(K2, IV = SIV) ──► ciphertext (same length as plaintext)

  Tink token:  0x01 │ key id (4 B) │ SIV (16 B) │ ciphertext (len(email) B)
               └─── same for every row ──┘
```

Same key, same associated data and same email always give the same SIV, so the same token. Change
one byte of the email and the SIV is unrelated. Decryption recomputes the SIV from the recovered
plaintext and rejects the token if it doesn't match, so a tampered token fails loudly instead of
decrypting to garbage.

**What leaks is exactly one thing: equality.** Two rows with the same token have the same email.
That's what makes the join work, and it's also the attack surface I come back to in the frequency
section. Two details of the Tink format matter later:

- The **5-byte prefix** (version byte plus key id) is the same on every row. It's how Tink knows
  which key to decrypt with after a rotation.
- The token is **21 bytes longer** than the email. An average synthetic email here is 24.3 bytes;
  its token is 45.3.

The associated data (`"email"`) is bound into the SIV. Both `customers.email` and
`orders.customer_email` must use the same keyset *and* the same associated data, or the tokens
won't match. Key per *logical* column, not per physical one.

## The lab: Postgres in, Parquet out, DuckDB on top

```text
  Postgres 18.6  shop.customers (10M)   shop.orders (50M, keyed by customer email)
        │  ADBC binary COPY → Arrow batches
        ▼
  pipeline.py ── one process, one core ─────────────────────────────────┐
  │  plain   : pass through                                             │
  │  sha256  : sha256(salt ‖ value)            one salt per warehouse   │
  │  daead   : AES-SIV(k_column, ad=column)    keysets wrapped by a KEK │
  └─────────────────────────────────────────────────────────────────────┘
        │  Parquet, zstd level 3, 1M-row groups
        ▼
  DuckDB 2.0 ── joins / GROUP BY / point lookups on the tokens
        │
        └── token ──► reid_service.py (role → columns, budget, audit) ──► plaintext
```

The data is a synthetic UK shop: 10 million customers with an email, a `+447` phone number, a
country and a plan, and 50 million orders that carry the customer's email rather than an id, the
way an order feed from a separate system often does. Emails follow a pattern mix (`first.last`,
`f.last`, a name with a birth year, random handles) over free-mail and company domains, built from
synthetic names with a skewed frequency so common names are common.

The three variants ran the same code path. Only the transform of `email`, `phone` and
`orders.customer_email` differed. Each column keyset is a Tink AES-SIV keyset, envelope-encrypted
under a key-encryption key. There's no KMS on my lab VM, so the KEK is a local Tink AES-GCM keyset
standing in for one.

Ingest ran 5 rounds and the joins 3 rounds of 5 repetitions, with the variant order rotated every
round. Everything ran on a single 4 vCPU KVM guest with Postgres on the same box. Versions and
the rest of the method are in the appendix.

## What it costs

### Ingest: 1.06 CPU-seconds per million rows

Medians over 5 runs, both tables together (60 million rows):

| variant        | rows/s    | CPU s per 1M rows | over plaintext |
| -------------- | --------- | ----------------- | -------------- |
| plaintext      | 1,695,155 | 0.58              |                |
| salted SHA-256 | 911,397   | 1.08              | +0.50          |
| AES-SIV (Tink) | 603,500   | 1.65              | +1.06          |

**Throughput fell to about a third.** That sounds bad, and on one Python process it is: the
pipeline is single-threaded, the plaintext path does almost nothing but move Arrow buffers, and
the tokenizer is a Python loop calling into Tink's C++ once per value. That loop cost 0.83 µs per
value for AES-SIV and about 0.5 µs for SHA-256, consistently on both tables.

The number I'd actually plan with is the CPU one. **Encrypting every email and phone costs about one
extra CPU-second per million rows.** At 60 million rows that's about 64 CPU-seconds, once, as the
data arrives. The Postgres backend used the same CPU (about 10.5 s for orders) in every variant;
the source doesn't care what you do with the rows afterwards. Peak RSS went from 255 MB to 545 MB.

### Storage: the hypothesis was right, by a factor of four

| file              | plaintext | salted SHA-256 | AES-SIV  |
| ----------------- | --------- | -------------- | -------- |
| customers.parquet | 154 MB    | 663 MB         | 740 MB   |
| orders.parquet    | 1,112 MB  | 2,255 MB       | 2,763 MB |
| total             | 1,266 MB  | 2,918 MB       | 3,503 MB |

**The warehouse grew 2.8x, and every byte of that growth is in the PII columns.** The other
columns were byte-for-byte the same size in all three variants.

Per column, the email went from 92.9 MB to 424.5 MB in `customers` and from 461 MB to 2,113 MB in
`orders`: 4.6x in both. Two effects multiply:

- **The values got longer.** 24.3 bytes of email became a 45.3-byte token, 1.86x.
- **They stopped compressing.** zstd squeezed the plaintext emails 2.62x. It squeezed the tokens
  1.07x, and that 7% is the 5-byte prefix repeating. The hashes compressed exactly 1.00x.

Phone numbers were worse, 7.2x (40.9 MB to 295 MB), because digits in a fixed format compress well
(3.18x) and a 34-byte token doesn't.

I checked whether a different codec would rescue it, on the first 2 million rows of each column:

| column (2M rows)     | none    | snappy  | zstd 3  | zstd 9  |
| -------------------- | ------- | ------- | ------- | ------- |
| email, plaintext     | 29.3 MB | 14.8 MB | 9.5 MB  | 8.8 MB  |
| email, AES-SIV       | 51.0 MB | 45.5 MB | 43.8 MB | 43.7 MB |
| email, salted SHA-256 | 33.3 MB | 33.3 MB | 33.3 MB | 33.3 MB |

**There is nothing for a codec to find.** Ciphertext is supposed to look random, and it does.

Parquet's dictionary encoding didn't save the orders column either, even though 50 million orders
only reference 9.67 million distinct emails. The writer abandons the dictionary once it outgrows the
1 MB dictionary page limit and falls back to plain encoding, and that happened for plaintext too:
the plaintext email compressed 2.63x in `orders` and 2.62x in `customers`, where every value is
unique. Repetition only helps if equal values end up near each other, which is what the sort
experiment below tests.

### Joins: they work, and cost 8% to 38%

The headline query joins all 50 million orders to 10 million customers on the email key and
aggregates by country. Every variant returned identical results for every query, down to the sum of
pence.

| query (ms, median)          | plaintext | salted SHA-256 | AES-SIV | AES-SIV vs plaintext |
| --------------------------- | --------- | -------------- | ------- | -------------------- |
| join + aggregate, DuckDB table | 2,248  | 2,284          | 3,108   | +38%                 |
| join + aggregate, on Parquet   | 2,801  | 2,515          | 3,016   | +8%                  |
| `count(distinct email)`, table | 2,447  | 2,211          | 3,522   | +44%                 |
| point lookup, table            | 325    | 161            | 607     | +87%                 |
| point lookup, on Parquet       | 693    | 293            | 504     | −27%                 |

Two things surprised me. The hashed column, longer than the plaintext, joined about as fast as
plaintext and ran point lookups twice as fast. And the token column was slowest on native tables
but beat plaintext on a Parquet point lookup. I don't have a full explanation for the second one.
My guess for the first is that fixed-width 32-byte values are cheap to compare, and it led to the
prefix experiment further down.

**For an analyst, a 2.2-second join became a 3.1-second join.** The difference is real, but it's
not the kind anyone files a ticket about.

### The 5 bytes that slowed the joins

Every Tink token starts with the same five bytes: `0x01` and the key id. DuckDB keeps a short prefix
of every string inline and compares that first, so it can skip most of the work when two strings
differ early. My guess was that for tokens that prefix never differs, so every comparison falls
through to the full value. Hashes, by contrast, are random from the first byte.

Tink can produce tokens without the prefix: a key with output prefix type `RAW`. I checked that a
RAW key gives exactly the Tink token minus its first 5 bytes (1,000 of 1,000 identical), then built
both versions of the tables in DuckDB the same way and timed them, 3 rounds of 5:

| query (ms, median of round medians) | plaintext | AES-SIV, Tink prefix | AES-SIV, prefix stripped |
| ----------------------------------- | --------- | -------------------- | ------------------------ |
| join + aggregate                    | 2,277     | 2,888                | 2,378                    |
| `count(distinct email)`             | 2,392     | 3,308                | 2,710                    |
| point lookup                        | 423       | 569                  | 157                      |

All three returned identical results. **Dropping five constant bytes took the join's overhead over
plaintext from +611 ms to +101 ms,** and the point lookup went from slower than plaintext to 2.7x
faster. Random bytes from position zero are easy to tell apart. That also fits the earlier puzzle
of the hashed column being quick.

The price is the key id. A RAW token doesn't say which key made it, so you have to track that
yourself (per table or per file), and Tink tries each RAW key in turn when it decrypts. I checked
that an old RAW token still decrypts after a new primary is added, and that the new primary gives a
different token, so the rotation runbook below still applies. I didn't time a full rotation with
RAW keys. If your warehouse is join-heavy, I'd still take the trade.

### Sorting wins the storage back

The other fix is layout. A 1M-row group of unsorted orders references close to a million different
emails, too many for a dictionary. Sorted by email, each row group only holds about a fiftieth of
the customers, each repeated across their orders. I rewrote `orders` with DuckDB, once unsorted and
once `ORDER BY customer_email`, for each variant:

| orders.parquet (DuckDB writer, zstd 3) | unsorted | sorted by email | email column, unsorted → sorted |
| -------------------------------------- | -------- | --------------- | ------------------------------- |
| plaintext                              | 1,039 MB | 765 MB          | 443 → 113 MB                    |
| salted SHA-256                         | 2,211 MB | 1,010 MB        | 1,616 → 358 MB                  |
| AES-SIV                                | 2,698 MB | 1,103 MB        | 2,103 → 451 MB                  |

**Sorted, the encrypted orders table is about the size of the unsorted plaintext one.** The file
metadata shows why: unsorted, DuckDB wrote the email column as `PLAIN` in all 50 row groups; sorted,
it switched to `PLAIN_DICTIONARY` in all 50. The column shrank 4.7x, to roughly what it costs to
store each of the 9.67 million distinct tokens once (9.67M × 45.3 bytes is 438 MB). The sort roughly doubled the write time, from 11.3 to 21.2 seconds
for 50 million rows. Plaintext gets the same benefit, so the *gap* doesn't close, but most of the
absolute bill does.

## What it stops

### Phones: the hash is gone in two minutes

The attacker has a copy of `customers.parquet` and the salt. Here is the whole attack:

```sql
-- n.i is every integer from 0 to 999,999,999, written to Parquet so DuckDB scans it on 4 threads
select count(*)
from read_parquet('uk-mobile-suffixes.parquet') n
join read_parquet('customers.parquet') w
  on unhex(sha256($salt || ('+447' || lpad(n.i::varchar, 9, '0'))::blob)) = w.phone;
```

| run | hashed column: recovered | seconds | AES-SIV column: recovered | seconds |
| --- | ------------------------ | ------- | ------------------------- | ------- |
| 1   | 10,000,000 (100%)        | 123.1   | 0                         | 121.9   |
| 2   | 10,000,000 (100%)        | 121.3   | 0                         | 118.3   |
| 3   | 10,000,000 (100%)        | 119.5   | 0                         | 121.9   |

**Every phone number, in about two minutes, about 8 million candidates per second.** Writing the
billion candidate numbers to Parquet took another 7 seconds. I needed that step because DuckDB's
`range()` ran on a single thread here, at 3.4 million hashes per second. I didn't try a GPU or a
dedicated cracker. This is what an analyst with SQL and a laptop-sized VM gets.

Against the AES-SIV column, the same query finds nothing, because there's nothing to compute: the
token depends on a 64-byte key the attacker doesn't have.

### Emails: a dictionary recovers exactly what's in it

Emails don't enumerate like phones, so the attacker builds a dictionary: popular first and last
names (in real life, census and breach data), the four digit-free patterns (`first.last`,
`firstlast`, `f.last`, `first_last`) and the common domains. Mine had 10 million candidates and
never touched the real customer list.

| scenario                                      | recovered | time |
| --------------------------------------------- | --------- | ---- |
| emails in the dictionary at all (upper bound) | 1,257,968 (12.58%) | |
| salted SHA-256, salt known                    | **1,257,968** | 5.8 s hashing, ~3 s matching |
| salted SHA-256, attacker guesses no salt      | 0         | |
| AES-SIV, no key (tried sha256, salted sha256, a fresh AES-SIV key) | 0 | |
| AES-SIV, attacker holds the pipeline's keyset | **1,257,968** | 9.6 s encrypting, ~3 s matching |

The counts were identical in all three runs, on both lab VMs. The 12.58% is a property of my name
generator and the attacker's list, so don't read anything into it. The part that doesn't depend on
the generator is the second row: **the hash gave up every address the attacker thought to guess, at
1.7 million guesses per second on one core in Python.**

The last row is the one to remember. **Deterministic encryption is not magic, it's a keyed
function.** Whoever holds the key, or can ask a service to tokenize for them, can run the exact
same dictionary attack, at a million guesses per second. Encryption doesn't remove the risk. It
moves it from "anyone with the salt" to "anyone with the key", and a key can live in a KMS, show up
in an audit log and be rotated without going back to the source. A salt in a dbt project can't.

If you already treat your salt like a key (in a KMS, never in config), you've built something
close to HMAC, and the dictionary attack needs it just as much. What you still don't get is the way
back to the plaintext when support legitimately needs it.

## What it leaks: equality, and therefore frequency

The honest weakness of deterministic encryption is the thing that makes it useful. Equal values get
equal tokens, so the histogram of tokens *is* the histogram of values. On an email column that's
mostly harmless, since nearly every value is unique. On a low-cardinality column, it's most of the
plaintext.

To show that, I tokenized `country` (30 values) with its own key and played the attacker. The
attacker knows roughly what a UK shop's customer mix looks like, but not exactly: I took the true
mix and scaled each country's share by a random factor between 0.75 and 1.33. Then they sort the
tokens by frequency, sort their guessed countries by share, and pair them up.

| prior (seed) | rows labelled correctly | countries identified (of 30) | top 5 correct |
| ------------ | ----------------------- | ---------------------------- | ------------- |
| 0            | 87.36%                  | 19                           | 5             |
| 1            | 88.83%                  | 17                           | 5             |
| 2            | 82.75%                  | 20                           | 3             |

**With a rough idea of the distribution and no key, the attacker labels 83% to 89% of the rows.**
They don't even need the rough idea. Knowing only that a UK shop has mostly UK customers, the
single most common token (`0121c2df…`) is GB, and that's 40.62% of all rows.

As a control I encrypted a million rows of the same column with ordinary randomized AES-GCM: a
million rows, a million distinct tokens, nothing to count. Also nothing to join or group on.

Email has the same property in a quieter form. The orders table has 50 million rows and 9,673,196
distinct email tokens. One token appears on 15,835 orders, and 6,425 tokens appear on more than 100.
Nobody learns *who* those customers are from the token alone, but anyone can see which rows belong
to the same person, across every table that shares the key. That's the feature you wanted for joins.
It's also linkage.

So the rule I'd use: **deterministic encryption for high-cardinality identifiers you need to join
on (email, phone, customer number). Not for anything with a small, guessable set of values
(country, gender, plan, birth year).** For those, either leave them in plaintext and accept that
they're quasi-identifiers, or use randomized encryption and give up grouping on them.

## What running it costs

### Rotation: there is no "new rows only"

With a normal envelope-encrypted column, rotating a key is cheap: new data gets the new key, old data
keeps decrypting with the old one, and you re-encrypt lazily or never. I assumed I could do the
same here. Tink makes the first half easy: add a key, make it primary, keep the old one enabled,
and old tokens still decrypt because the 5-byte prefix says which key made them.

So I added a new primary email key, tokenized 100,000 existing customers' emails as if new orders
had just arrived, and looked them up in `customers.parquet`:

```text
lazy_rotation_matches: {"sampled": 100000, "matched": 0}
```

**Zero.** Same email, new key, different token. Every order ingested after the rotation would
silently stop joining to every customer ingested before it. No error, just an inner join that
returns fewer rows and a dashboard that's quietly wrong. Deterministic encryption only joins
within one key, so **a rotation has to rewrite every token of that column, in every table, in
one go.**

That's what `rotate.py` does: read each file row group by row group, decrypt with the keyset,
re-encrypt under the new primary, write a new file, swap it in, check that no token still carries
the old key id, then destroy the old key. Three runs, each from a fresh copy:

| key   | rows rewritten | wall (median) | CPU s | CPU s per 1M rows | old-key tokens left |
| ----- | -------------- | ------------- | ----- | ----------------- | ------------------- |
| email | 60,000,000 (customers + orders) | 140.8 s | 142.8 | 2.38 | 0 |
| phone | 10,000,000 (customers)          | 24.1 s  | 24.5  | 2.45 | 0 |

After each email rotation the 100,000 sampled emails matched again (100,000 of 100,000), and the
full orders-to-customers join returned all 50,000,000 rows, the same as plaintext.

Where the time went, for the 50M-row orders file: 3 s reading, 95 s decrypting and re-encrypting
(1.9 µs per value, a decrypt plus an encrypt), 17.5 s writing.

**So the hypothesis holds, with a twist.** Per row, rotating costs 2.38 CPU-seconds per million rows.
That's 2.2x the 1.06 it cost to encrypt at ingest, and more than ingesting the whole row with
encryption from scratch (1.65), because a rotation does two crypto operations per value and
rewrites every other column along the way. Per-column keys help: rotating the phone key touched one
file instead of two.

But in absolute terms, rotating the key on all 60 million rows took two and a half minutes of one
core. **The expensive part isn't the CPU. It's that you can't do it gradually.** Every table that
holds the column has to move to the new key together, while writers are either paused or also on
the new key, or the joins drift. That's a coordination problem, and the CPU bill is the small part
of it.

Hashing has a worse version of the same problem. To rotate a salt you need the plaintext, and the
warehouse doesn't have it, so you re-ingest everything from the source. That assumes the source
still has every row the warehouse does.

### Re-identification: a small service with a big policy

Analysts never get the keyset. The only way back from a token is `reid_service.py`, a stdlib HTTP
service that holds the email and phone keysets and answers two questions: *what is this token* and
*what is this value's token*. I tested four callers:

| caller   | role     | reidentify email | reidentify phone | tokenize email | tokenize phone |
| -------- | -------- | ---------------- | ---------------- | -------------- | -------------- |
| ana      | analyst  | 403              | 403              | 403            | 403            |
| sam      | support  | 200              | 403              | 200            | 403            |
| fio      | fraud    | 200              | 200              | 200            | 200            |
| etl      | pipeline | 403              | 403              | 200            | 200            |

The rest of the checks, from `results/reid/reid.json`:

- 100 tokens round-tripped to exactly the plaintext in the source, and tokenizing 100 source
  emails produced exactly the tokens in the warehouse.
- A phone token sent as an email got a 400. Different keyset, different associated data, so it
  doesn't decrypt. That's per-column keys doing their job.
- An unknown bearer token got a 401. A support request for 21 tokens got a 413 (the cap is 20).
- Support's budget is 60 values a minute. Two earlier test calls had used 2 of them, so of four
  back-to-back 20-token requests, two succeeded and two got a 429.
- 3,025 audit records, each with caller, role, action, column, count and status, and **zero
  plaintext emails** in the log.
- A single-token lookup took 0.38 to 0.77 ms at the median and under 1.3 ms at p99 on localhost,
  across three runs of 1,000 calls. The median crept up run over run. My guess is the rate limiter,
  which re-sums its one-minute window on every call. I didn't confirm that.

**Look at the `etl` row.** The pipeline can't decrypt anything, but it can tokenize, and the
dictionary section showed that tokenize access is a dictionary attack at a million guesses per
second. **Tokenize is as sensitive as decrypt.** Give it a budget too. At support's 60 a minute,
the 10-million-entry dictionary from earlier would take about 115 days.

## What I'd do: the config

### One keyset per logical column, wrapped by a KMS key

```python
import tink
from tink import aead, daead

aead.register()
daead.register()

# In production: kek = tink.KmsClient(...).get_aead("gcp-kms://..." or "aws-kms://...")
kek = tink.new_keyset_handle(aead.aead_key_templates.AES256_GCM).primitive(aead.Aead)

for column in ("email", "phone"):
    handle = tink.new_keyset_handle(daead.deterministic_aead_key_templates.AES256_SIV)
    wrapped = tink.json_proto_keyset_format.serialize_encrypted(handle, kek, f"column:{column}".encode())
    open(f"keys/{column}.json", "w").write(wrapped)
```

### The tokenizer

The same keyset *and* the same associated data for every physical column that holds the same
logical value, or the tokens won't join:

```python
import pyarrow as pa

PII = {
    "customers": {"email": "email", "phone": "phone"},
    "orders": {"customer_email": "email"},  # same key and ad as customers.email
}

def tokenizer(logical: str):
    handle = tink.json_proto_keyset_format.parse_encrypted(
        open(f"keys/{logical}.json").read(), kek, f"column:{logical}".encode())
    enc = handle.primitive(daead.DeterministicAead).encrypt_deterministically
    ad = logical.encode()
    return lambda values: pa.array([enc(v.encode(), ad) for v in values], pa.binary())

def transform(table: pa.Table, name: str) -> pa.Table:
    fns = {col: tokenizer(logical) for col, logical in PII[name].items()}
    for col, fn in fns.items():
        table = table.set_column(table.schema.get_field_index(col), col, fn(table.column(col).to_pylist()))
    return table
```

The full pipeline, with ADBC reads and the Parquet writer, is
[`pipeline.py`](https://github.com/netf/blog/tree/main/docs/labs/encrypted-email-joins/scripts/pipeline.py).

### Write sorted by the join key

```sql
copy (select * from read_parquet('staging/orders.parquet') order by customer_email)
to 'warehouse/orders.parquet' (format parquet, compression zstd, row_group_size 1000000);
```

### The re-identification policy

```python
ROLES = {
    "analyst":  {"reidentify": [],                 "tokenize": [],                 "per_request": 0,      "per_minute": 0},
    "support":  {"reidentify": ["email"],          "tokenize": ["email"],          "per_request": 20,     "per_minute": 60},
    "fraud":    {"reidentify": ["email", "phone"], "tokenize": ["email", "phone"], "per_request": 100,    "per_minute": 60_000},
    "pipeline": {"reidentify": [],                 "tokenize": ["email", "phone"], "per_request": 10_000, "per_minute": 10_000_000},
}
```

Decrypt and tokenize are separate grants, both budgeted, both audited with counts and never values.
The service is
[`reid_service.py`](https://github.com/netf/blog/tree/main/docs/labs/encrypted-email-joins/scripts/reid_service.py).

### The rotation runbook

1. Add a new AES-SIV key to the column's keyset and make it primary. Keep the old key enabled.
2. Pause the writers for every table that holds the column, or switch them to the new keyset at
   the same moment the rewrite starts. Never let new rows land under the new key while old rows
   are still on the old one.
3. Rewrite every file holding the column: decrypt with the keyset, re-encrypt under the primary,
   swap the file in.
4. Verify that no token still carries the old key id and that the join row count is unchanged.
5. Destroy the old key.

That's [`rotate.py`](https://github.com/netf/blog/tree/main/docs/labs/encrypted-email-joins/scripts/rotate.py).
Budget about 2.4 CPU-seconds per million rows for step 3, plus the time it takes to read and write
your files.

## What this lab tells you

- **A salted hash of an email or phone number is a pseudonym, not protection.** The phone space
  enumerated completely in about two minutes in SQL, and the email dictionary matched every address
  it contained. If the salt is readable by the people you're protecting against, so is the column.
- **AES-SIV removes the offline attack, and nothing else.** Without the key both attacks found 0.
  With the pipeline's keyset, the dictionary attack recovered exactly what it recovered against the
  hash. Your security is now your key custody: KMS, audit, and budgets on both decrypt and tokenize.
- **CPU is not the reason to say no.** About 1.06 extra CPU-seconds per million rows at ingest,
  measured on one Python process.
- **Storage is the cost to plan for.** Expect identifier columns to grow about 4.6x (email) and 7x
  (phone) under zstd, and no codec to help. Sorting by the join key gives most of it back, because
  each row group becomes small enough for a dictionary.
- **Strip Tink's prefix if joins matter.** With RAW keys the join cost dropped from +27% to +4% over
  plaintext, and point lookups got faster than plaintext. You then track key versions yourself.
- **Rotation is all-or-nothing per column.** A new key silently breaks joins until every table
  holding that column is rewritten. At this scale the rewrite was minutes of CPU (2.38 s per
  million rows). The hard part is pausing or coordinating the writers.
- **Equality is the leak you accept.** Fine for high-cardinality identifiers, bad for small
  categories. A rough prior labelled up to 89% of a 30-value column.

If I had to change one thing on Monday, I'd find every `sha256(` in the dbt project that touches an
email or phone column and ask who can read the salt. The answer is usually "everyone who can read
the repo".

What I still don't know is how much of the ingest cost is Python. The tokenizer spent 0.83 µs per
value calling into Tink's C++ one value at a time. A vectorised tokenizer, or doing it inside the
engine, would probably cut that, and that's the next lab.

## Reproduce it

```bash
git clone https://github.com/netf/blog && cd blog/docs/labs/encrypted-email-joins
./reproduce.sh     # Ubuntu 24.04, 4 vCPU, ~20 GB disk, about 1.5 hours
```

`N_CUSTOMERS=1000000 N_ORDERS=5000000 ./reproduce.sh` runs a smaller version in a fraction of the
time. Corrections are welcome. If you get different numbers, I'd like to see them.

## Appendix A: Methodology

**Scope.** Synthetic data only, on one 4 vCPU KVM guest with Postgres on the same machine. Every
pipeline variant is a single Python process, so throughput is per core, not per cluster. DuckDB ran
with `threads = 4` and `memory_limit = '3GB'`, because the VM's memory balloon made "available
memory" move during the runs. There's no KMS on the lab VM, so the key-encryption key is a local
Tink AES-GCM keyset; that changes key custody, not any measured cost. The lab VM was recycled
partway through: ingest, size, join and rotation numbers come from the first VM, and the attacks,
frequency analysis, re-identification checks and the sort and prefix follow-ups come from a second
VM of the same shape. The data was regenerated from the same seeds, and the plaintext and hashed
Parquet files came out byte-for-byte the same size.

**Ingest.** `pipeline.py` reads each table with ADBC (Postgres binary COPY into Arrow), transforms
the PII columns in 1M-row batches and writes Parquet with zstd level 3. CPU is the process's
user + system time from `getrusage`; the Postgres backend's CPU is read from `/proc` separately.
5 rounds, variant order rotated each round.

**Sizes.** Stored bytes are the column chunks' compressed sizes from the Parquet footer. Logical
bytes are the sum of value lengths. The codec check rewrote the first 2M rows of each PII column
with each codec.

**Joins.** Native DuckDB tables (`create table as select * from read_parquet(...)`) and direct
`read_parquet` scans. 3 rounds, variant order rotated, one warm-up then 5 timed runs per query. The
point lookup uses the customer with the most orders (15,835) in every variant. The prefix follow-up
used the same protocol on tables with only the columns the queries need, built with the same
expression for both token variants.

**Rotation.** Each of the 3 runs started from a fresh copy of the encrypted warehouse and keyset.
Wall and CPU time cover the rewrite only, not the checks before and after it.

**Attacks.** The dictionary is 10M unique candidates built from the same synthetic name lists, the
four digit-free patterns, the six free-mail domains and 200 of the 2,000 company domains, sampled
by name frequency. The phone attack enumerates all 1e9 `+447` numbers. Frequency analysis uses
three random priors, each scaling every country's true share by a factor in [0.75, 1.33].

**Data model.** 10M customers. Email patterns: `first.last` 30%, `firstlast` 15%, `f.last` 10%,
`first_last` 10%, `first.last` plus two digits 15%, first name plus a year 10%, random handle 10%.
Domains: six free-mail providers (75%) and 2,000 company domains (25%). 50M orders, with customers
picked with a skew (`power(random(), 2)`), so 9.67M customers have orders.

## Appendix B: Full tables

**Ingest per table** (median, min–max over 5 runs):

| variant        | table     | rows/s                          | CPU s per 1M rows  | transform s       |
| -------------- | --------- | ------------------------------- | ------------------ | ----------------- |
| plaintext      | customers | 1,461,684 (1,147,292–1,479,541) | 0.68 (0.67–0.86)   | 0                 |
| salted SHA-256 | customers | 628,386 (624,136–638,730)       | 1.55 (1.53–1.56)   | 10.0 (9.7–10.0)   |
| AES-SIV        | customers | 395,027 (391,270–399,260)       | 2.49 (2.46–2.51)   | 16.4 (16.2–16.5)  |
| plaintext      | orders    | 1,748,272 (1,453,794–1,754,209) | 0.56 (0.56–0.69)   | 0                 |
| salted SHA-256 | orders    | 1,002,143 (934,685–1,010,826)   | 0.99 (0.98–1.06)   | 25.9 (25.7–28.9)  |
| AES-SIV        | orders    | 674,719 (577,800–679,975)       | 1.48 (1.47–1.72)   | 41.5 (41.3–47.8)  |

The wide ranges come from the last round, where three runs (AES-SIV orders, both plaintext tables)
were 15% to 22% slower than the other four rounds. I don't know why. They're included rather than
dropped, and the medians barely notice them.

**Joins** (ms, median of all timed runs, min–max of the per-round medians):

| source  | query            | plaintext             | salted SHA-256        | AES-SIV               |
| ------- | ---------------- | --------------------- | --------------------- | --------------------- |
| table   | join + aggregate | 2,248 (2,169–2,366)   | 2,284 (2,249–2,310)   | 3,108 (3,006–3,150)   |
| table   | count distinct   | 2,447 (2,347–2,514)   | 2,211 (2,206–2,279)   | 3,522 (3,372–3,614)   |
| table   | point lookup     | 325 (307–340)         | 161 (157–166)         | 607 (594–634)         |
| Parquet | join + aggregate | 2,801 (2,742–2,936)   | 2,515 (2,477–2,548)   | 3,016 (2,991–3,104)   |
| Parquet | count distinct   | 2,841 (2,619–2,900)   | 2,586 (2,523–2,783)   | 3,553 (3,461–3,671)   |
| Parquet | point lookup     | 693 (678–722)         | 293 (273–312)         | 504 (499–522)         |

**Prefix follow-up** (ms, median of round medians, min–max):

| query            | plaintext           | Tink prefix         | stripped            |
| ---------------- | ------------------- | ------------------- | ------------------- |
| join + aggregate | 2,277 (2,250–2,344) | 2,888 (2,858–2,953) | 2,378 (2,361–2,404) |
| count distinct   | 2,392 (2,328–2,490) | 3,308 (3,292–3,497) | 2,710 (2,638–2,791) |
| point lookup     | 423 (412–437)       | 569 (566–570)       | 157 (155–158)       |

**Rotation** (3 runs each): email 141.4 / 139.7 / 140.8 s wall, 143.7 / 142.0 / 142.8 CPU s; phone
24.3 / 24.1 / 23.7 s wall, 24.8 / 24.5 / 24.0 CPU s. Old-key tokens left: 0 in every run.

## Appendix C: Versions and evidence

| component  | version                                                               |
| ---------- | --------------------------------------------------------------------- |
| host       | Ubuntu 24.04.5, 4 vCPU Xeon (AES-NI, VAES, SHA-NI), kernels 6.12.94+ and 6.12.113+ |
| PostgreSQL | 18.6 (PGDG `18.6-1.pgdg24.04+2`), stock settings                      |
| Python     | 3.12.3                                                                |
| Tink       | tink 1.16.1 (Python), protobuf 7.36.2                                 |
| DuckDB     | 2.0.0                                                                 |
| Arrow      | pyarrow 26.0.0, adbc-driver-postgresql 1.12.0                         |

| claim                              | script                          | raw evidence                       |
| ---------------------------------- | ------------------------------- | ---------------------------------- |
| environment and workarounds        | `00-preflight.sh`               | `environment.md`, `results/environment-raw*.txt` |
| ingest throughput and CPU          | `03-bench-ingest.sh`, `pipeline.py` | `results/ingest/runs.jsonl`     |
| Parquet sizes and codecs           | `sizes.py`                      | `results/sizes/sizes.json`         |
| join latency                       | `bench_join.py`                 | `results/join/runs.jsonl`          |
| rotation                           | `04-rotate.sh`, `rotate.py`     | `results/rotation/`                |
| dictionary and phone attacks       | `attack_dictionary.py`, `attack_phone.py` | `results/attack/`        |
| frequency analysis                 | `frequency.py`                  | `results/frequency/frequency.json` |
| re-identification service          | `test_reid.py`, `reid_service.py` | `results/reid/reid.json`         |
| sorting and the Tink prefix        | `extra_layout.py`               | `results/layout/`                  |
| VM 2 rebuild check                 | `rebuild.sh`                    | `results/rebuild/`                 |
