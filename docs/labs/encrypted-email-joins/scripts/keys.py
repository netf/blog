"""Per-column Tink keysets, envelope-encrypted with a key-encryption key (KEK).

The KEK stands in for a cloud KMS key: in this lab it is a local AES256-GCM keyset file, because
there is no KMS on the lab VM. Column keysets on disk are only ever stored encrypted under it.

    keys/kek.json             cleartext AEAD keyset (the KMS stand-in)
    keys/<column>.json        AES-SIV keyset for one logical column, encrypted under the KEK
    keys/sha256_salt.bin      salt for the hashing baseline
"""
import os
import pathlib

import tink
from tink import aead, daead, secret_key_access
from tink.proto import tink_pb2

aead.register()
daead.register()

KEY_DIR = pathlib.Path(os.environ.get("LAB_KEYS", pathlib.Path(__file__).resolve().parent.parent / "data" / "keys"))
COLUMNS = ("email", "phone", "country")


def _kek():
    path = KEY_DIR / "kek.json"
    if not path.exists():
        KEY_DIR.mkdir(parents=True, exist_ok=True)
        h = tink.new_keyset_handle(aead.aead_key_templates.AES256_GCM)
        path.write_text(tink.json_proto_keyset_format.serialize(h, secret_key_access.TOKEN))
    h = tink.json_proto_keyset_format.parse(path.read_text(), secret_key_access.TOKEN)
    return h.primitive(aead.Aead)


def _ad(column):
    return f"column:{column}".encode()


def load(column):
    text = (KEY_DIR / f"{column}.json").read_text()
    return tink.json_proto_keyset_format.parse_encrypted(text, _kek(), _ad(column))


def save(column, handle):
    KEY_DIR.mkdir(parents=True, exist_ok=True)
    text = tink.json_proto_keyset_format.serialize_encrypted(handle, _kek(), _ad(column))
    tmp = KEY_DIR / f".{column}.json.tmp"
    tmp.write_text(text)
    tmp.replace(KEY_DIR / f"{column}.json")


def create_all(force=False):
    for col in COLUMNS:
        if force or not (KEY_DIR / f"{col}.json").exists():
            save(col, tink.new_keyset_handle(daead.deterministic_aead_key_templates.AES256_SIV))
    salt = KEY_DIR / "sha256_salt.bin"
    if force or not salt.exists():
        salt.write_bytes(os.urandom(32))


def salt():
    return (KEY_DIR / "sha256_salt.bin").read_bytes()


def primitive(column):
    return load(column).primitive(daead.DeterministicAead)


def _proto(handle):
    return tink_pb2.Keyset.FromString(tink.proto_keyset_format.serialize(handle, secret_key_access.TOKEN))


def _handle(ks):
    return tink.proto_keyset_format.parse(ks.SerializeToString(), secret_key_access.TOKEN)


def add_primary(column):
    """Step 1 of rotation: add a fresh AES-SIV key and make it primary. Old keys stay ENABLED so
    existing tokens still decrypt. Returns (old_primary_id, new_primary_id)."""
    ks = _proto(load(column))
    old = ks.primary_key_id
    new_key = _proto(tink.new_keyset_handle(daead.deterministic_aead_key_templates.AES256_SIV)).key[0]
    while new_key.key_id in {k.key_id for k in ks.key}:
        new_key = _proto(tink.new_keyset_handle(daead.deterministic_aead_key_templates.AES256_SIV)).key[0]
    ks.key.append(new_key)
    ks.primary_key_id = new_key.key_id
    save(column, _handle(ks))
    return old, new_key.key_id


def retire(column, key_id):
    """Last step of rotation: destroy key material for key_id once nothing references it."""
    ks = _proto(load(column))
    if key_id == ks.primary_key_id:
        raise ValueError("refusing to retire the primary key")
    kept = [k for k in ks.key if k.key_id != key_id]
    del ks.key[:]
    ks.key.extend(kept)
    save(column, _handle(ks))


def info(column):
    ks = _proto(load(column))
    return {"primary": ks.primary_key_id, "keys": [k.key_id for k in ks.key]}


if __name__ == "__main__":
    create_all()
    for c in COLUMNS:
        print(c, info(c))
