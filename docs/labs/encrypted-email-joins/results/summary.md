## Ingest (median, min–max across runs)

runs per cell: 5

| variant | table | rows/s | CPU s per 1M rows | transform s | Postgres backend CPU s | peak RSS MB |
|---|---|---|---|---|---|---|
| plaintext | customers | 1,461,684 (1,147,292–1,479,541) | 0.68 (0.67–0.86) | 0.0 (0.0–0.0) | 2.5 (2.3–3.2) | 244 |
| salted SHA-256 | customers | 628,386 (624,136–638,730) | 1.55 (1.53–1.56) | 10.0 (9.7–10.0) | 2.4 (2.4–2.5) | 485 |
| AES-SIV (Tink) | customers | 395,027 (391,270–399,260) | 2.49 (2.46–2.51) | 16.4 (16.2–16.5) | 2.5 (2.3–2.5) | 534 |
| plaintext | orders | 1,748,272 (1,453,794–1,754,209) | 0.56 (0.56–0.69) | 0.0 (0.0–0.0) | 10.4 (10.4–13.5) | 255 |
| salted SHA-256 | orders | 1,002,143 (934,685–1,010,826) | 0.99 (0.98–1.06) | 25.9 (25.7–28.9) | 10.5 (10.3–11.1) | 483 |
| AES-SIV (Tink) | orders | 674,719 (577,800–679,975) | 1.48 (1.47–1.72) | 41.5 (41.3–47.8) | 10.5 (10.4–12.7) | 545 |

- plaintext, both tables (60M rows): 1,695,155 (1,391,821–1,701,548) rows/s, 0.582 (0.580–0.714) CPU s per 1M rows
- salted SHA-256, both tables (60M rows): 911,397 (863,670–917,740) rows/s, 1.084 (1.076–1.147) CPU s per 1M rows
- AES-SIV (Tink), both tables (60M rows): 603,500 (537,726–607,195) rows/s, 1.645 (1.635–1.843) CPU s per 1M rows
- salted SHA-256 extra CPU over plaintext: 0.502 s per 1M rows
- AES-SIV (Tink) extra CPU over plaintext: 1.063 s per 1M rows

## Parquet size (zstd level 3)

| file | plaintext | salted SHA-256 | AES-SIV |
|---|---|---|---|
| customers.parquet | 154 MB | 663 MB | 740 MB |
| orders.parquet | 1,112 MB | 2,255 MB | 2,763 MB |

| column | variant | stored MB | logical MB | ratio | encodings |
|---|---|---|---|---|---|
| customers.email | plaintext | 92.9 | 243.1 | 2.62 | PLAIN, RLE, RLE_DICTIONARY |
| customers.email | salted SHA-256 | 321.2 | 320.0 | 1.0 | PLAIN, RLE, RLE_DICTIONARY |
| customers.email | AES-SIV (Tink) | 424.5 | 453.1 | 1.07 | PLAIN, RLE, RLE_DICTIONARY |
| customers.phone | plaintext | 40.9 | 130.0 | 3.18 | PLAIN, RLE, RLE_DICTIONARY |
| customers.phone | salted SHA-256 | 321.2 | 320.0 | 1.0 | PLAIN, RLE, RLE_DICTIONARY |
| customers.phone | AES-SIV (Tink) | 295.3 | 340.0 | 1.15 | PLAIN, RLE, RLE_DICTIONARY |
| customers.country | plaintext | 5.1 | 20.0 | 3.91 | PLAIN, RLE, RLE_DICTIONARY |
| customers.country | salted SHA-256 | 5.1 | 20.0 | 3.91 | PLAIN, RLE, RLE_DICTIONARY |
| customers.country | AES-SIV (Tink) | 5.1 | 20.0 | 3.91 | PLAIN, RLE, RLE_DICTIONARY |
| orders.customer_email | plaintext | 461.2 | 1,211.9 | 2.63 | PLAIN, RLE, RLE_DICTIONARY |
| orders.customer_email | salted SHA-256 | 1,604.9 | 1,600.0 | 1.0 | PLAIN, RLE, RLE_DICTIONARY |
| orders.customer_email | AES-SIV (Tink) | 2,113.0 | 2,261.9 | 1.07 | PLAIN, RLE, RLE_DICTIONARY |
| orders.amount_pence | plaintext | 97.7 | 200.0 | 2.05 | PLAIN, RLE, RLE_DICTIONARY |
| orders.amount_pence | salted SHA-256 | 97.7 | 200.0 | 2.05 | PLAIN, RLE, RLE_DICTIONARY |
| orders.amount_pence | AES-SIV (Tink) | 97.7 | 200.0 | 2.05 | PLAIN, RLE, RLE_DICTIONARY |

Codec check on the first 2,000,000 rows of each PII column (bytes):

| column / variant | none | snappy | zstd3 | zstd9 |
|---|---|---|---|---|
| daead/customers.email | 51.0 MB | 45.5 MB | 43.8 MB | 43.7 MB |
| daead/customers.phone | 39.5 MB | 33.1 MB | 30.6 MB | 30.5 MB |
| daead/orders.customer_email | 60.8 MB | 54.2 MB | 52.1 MB | 51.9 MB |
| plain/customers.email | 29.3 MB | 14.8 MB | 9.5 MB | 8.8 MB |
| plain/customers.phone | 17.8 MB | 9.6 MB | 4.3 MB | 4.1 MB |
| plain/orders.customer_email | 35.0 MB | 17.7 MB | 11.4 MB | 10.5 MB |
| sha256/customers.email | 33.3 MB | 33.3 MB | 33.3 MB | 33.3 MB |
| sha256/customers.phone | 33.3 MB | 33.3 MB | 33.3 MB | 33.3 MB |
| sha256/orders.customer_email | 39.6 MB | 39.6 MB | 39.6 MB | 39.6 MB |

## DuckDB query latency, ms (median of all timed reps, min–max of per-round medians)

| source | query | plaintext | salted SHA-256 | AES-SIV |
|---|---|---|---|---|
| table | join_agg | 2,248.1 (2,169.4–2,365.6) | 2,284.3 (2,248.6–2,310.3) | 3,108.3 (3,006.0–3,149.6) |
| table | distinct | 2,446.6 (2,346.7–2,514.1) | 2,210.7 (2,206.2–2,278.9) | 3,521.6 (3,372.1–3,614.2) |
| table | point | 324.9 (307.3–339.7) | 160.7 (156.6–166.1) | 607.4 (593.5–634.0) |
| parquet | join_agg | 2,800.6 (2,741.7–2,935.5) | 2,514.6 (2,476.5–2,548.0) | 3,016.2 (2,991.2–3,104.3) |
| parquet | distinct | 2,840.8 (2,619.2–2,900.4) | 2,585.9 (2,522.9–2,782.8) | 3,553.0 (3,461.1–3,671.1) |
| parquet | point | 692.8 (677.6–721.5) | 293.0 (273.4–312.2) | 504.4 (498.5–521.9) |

identical results across variants: True

## Key rotation (single process)

| column | run | rows rewritten | wall s | CPU s | CPU s per 1M rows | lazy-rotation matches | after rewrite | old-key tokens left |
|---|---|---|---|---|---|---|---|---|
| email | 1 | 60,000,000 | 141.44 | 143.73 | 2.395 | 0 / 100000 | 100000 | 0 |
| email | 2 | 60,000,000 | 139.66 | 141.95 | 2.366 | 0 / 100000 | 100000 | 0 |
| email | 3 | 60,000,000 | 140.76 | 142.75 | 2.379 | 0 / 100000 | 100000 | 0 |
| phone | 1 | 10,000,000 | 24.31 | 24.75 | 2.475 | - / - | - | 0 |
| phone | 2 | 10,000,000 | 24.12 | 24.52 | 2.452 | - / - | - | 0 |
| phone | 3 | 10,000,000 | 23.69 | 24.04 | 2.404 | - / - | - | 0 |

## Dictionary attack on email (10M candidates)

| run | upper bound | sha256, salt known | sha256, no salt | AES-SIV, no key | AES-SIV, pipeline key | hash s | encrypt s |
|---|---|---|---|---|---|---|---|
| 1 | 1,257,968 | 1,257,968 | 0 | 0 | 1,257,968 | 5.9 | 9.6 |
| 2 | 1,257,968 | 1,257,968 | 0 | 0 | 1,257,968 | 5.7 | 9.6 |
| 3 | 1,257,968 | 1,257,968 | 0 | 0 | 1,257,968 | 5.8 | 10.1 |

## Phone enumeration (1e9 candidates)

| run | sha256 recovered | s | AES-SIV recovered | s |
|---|---|---|---|---|
| 1 | 10,000,000 | 123.1 | 0 | 121.9 |
| 2 | 10,000,000 | 121.3 | 0 | 118.3 |
| 3 | 10,000,000 | 119.5 | 0 | 121.9 |

## Frequency analysis on tokenized country

- prior seed 0: 87.36% rows, 19/30 countries, top-5 5/5
- prior seed 1: 88.83% rows, 17/30 countries, top-5 5/5
- prior seed 2: 82.75% rows, 20/30 countries, top-5 3/5
- most frequent token alone: GB = 40.62% of rows
- randomized AEAD control: 1,000,000 distinct tokens for 1,000,000 rows

## Re-identification service

matrix: ana/reidentify/email=403, ana/reidentify/phone=403, ana/tokenize/email=403, ana/tokenize/phone=403, sam/reidentify/email=200, sam/reidentify/phone=403, sam/tokenize/email=200, sam/tokenize/phone=403, fio/reidentify/email=200, fio/reidentify/phone=200, fio/tokenize/email=200, fio/tokenize/phone=200, etl/reidentify/email=403, etl/reidentify/phone=403, etl/tokenize/email=200, etl/tokenize/phone=200

round trip ok: True, tokenize matches warehouse: True, phone token as email: 400, unknown caller: 401, over cap: 413, budget: [200, 200, 429, 429], audit records: 3025, plaintext in audit: 0
latency: p50 0.38 ms p99 0.93 ms; p50 0.587 ms p99 0.988 ms; p50 0.773 ms p99 1.244 ms

## orders.parquet sorted vs unsorted (DuckDB writer)

| variant | unsorted MB | sorted MB | email col unsorted MB | email col sorted MB |
|---|---|---|---|---|
| plaintext | 1,039 | 765 | 443 | 113 |
| salted SHA-256 | 2,211 | 1,010 | 1,616 | 358 |
| AES-SIV (Tink) | 2,698 | 1,103 | 2,103 | 451 |

## Tink prefix vs stripped (ms, median of round medians, min–max)

| query | plaintext | Tink prefix | stripped |
|---|---|---|---|
| join_agg | 2,277 (2,250–2,344) | 2,888 (2,858–2,953) | 2,378 (2,361–2,404) |
| distinct | 2,392 (2,328–2,490) | 3,308 (3,292–3,497) | 2,710 (2,638–2,791) |
| point | 423 (412–437) | 569 (566–570) | 157 (155–158) |

