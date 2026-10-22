"""Deterministic synthetic name lists and the email-pattern model.

Shared by the data generator and the attacker's dictionary builder, because in real life the
attacker's name-frequency lists (census data, other breaches) describe the same population.
"""
import itertools
import random

SYL_A = ["al", "ben", "car", "dan", "el", "fa", "ga", "han", "is", "jo", "ka", "li", "ma", "ni",
         "ol", "pe", "ra", "sa", "ta", "vi", "wil", "za", "ro", "mi", "an", "le", "so", "de"]
SYL_B = ["a", "e", "i", "o", "y", "ie", "ah", "on", "en", "an", "el", "ia", "ey", "us", "in"]
SYL_C = ["son", "ton", "ley", "man", "field", "wood", "ford", "well", "by", "ham", "er", "ing",
         "worth", "croft", "ridge", "stone", "brook", "dale", "more", "wick"]

N_FIRST = 2000
N_LAST = 5000

FREE_DOMAINS = [("gmail.com", 0.35), ("outlook.com", 0.12), ("yahoo.com", 0.10),
                ("hotmail.co.uk", 0.08), ("icloud.com", 0.07), ("proton.me", 0.03)]
N_COMPANY_DOMAINS = 2000
COMPANY_SHARE = 1.0 - sum(w for _, w in FREE_DOMAINS)

# (pattern, weight). Patterns without digits are guessable from name lists alone.
PATTERNS = [("first.last", 0.30), ("firstlast", 0.15), ("f.last", 0.10), ("first_last", 0.10),
            ("first.lastNN", 0.15), ("firstYYYY", 0.10), ("random", 0.10)]
GUESSABLE = ["first.last", "firstlast", "f.last", "first_last"]


def _unique_names(rng, n, parts):
    pool = sorted({"".join(c) for c in itertools.product(*parts) if 3 <= len("".join(c)) <= 14})
    if len(pool) < n:
        raise ValueError(f"only {len(pool)} distinct names for {n}")
    rng.shuffle(pool)
    return pool[:n]


def zipf_weights(n, s=0.8):
    return [1.0 / (r ** s) for r in range(1, n + 1)]


def first_names():
    return _unique_names(random.Random(1), N_FIRST, [SYL_A, SYL_B, ["", "n", "l", "r", "s", "th", "x", "k"]])


def last_names():
    return _unique_names(random.Random(2), N_LAST, [SYL_A, SYL_B, SYL_C])


def company_domains():
    rng = random.Random(3)
    tlds = ["com", "co.uk", "io", "de", "net"]
    return [f"{d}.{rng.choice(tlds)}" for d in _unique_names(rng, N_COMPANY_DOMAINS, [SYL_A, SYL_C, ["", "corp", "labs", "hq"]])]


def render(pattern, first, last, rng):
    if pattern == "first.last":
        return f"{first}.{last}"
    if pattern == "firstlast":
        return f"{first}{last}"
    if pattern == "f.last":
        return f"{first[0]}.{last}"
    if pattern == "first_last":
        return f"{first}_{last}"
    if pattern == "first.lastNN":
        return f"{first}.{last}{rng.randrange(100):02d}"
    if pattern == "firstYYYY":
        return f"{first}{rng.randrange(1950, 2010)}"
    if pattern == "random":
        return "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(10))
    raise ValueError(pattern)
