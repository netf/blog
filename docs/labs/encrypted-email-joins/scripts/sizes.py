"""Parquet size and compression per column, per variant.

    sizes.py > results/sizes/sizes.json

ratio = logical bytes (sum of value lengths, or fixed width) / bytes stored on disk for the column.
Also rewrites the PII columns alone with other codecs to check it isn't a codec-tuning problem.
"""
import json
import pathlib
import tempfile

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

ROOT = pathlib.Path(__file__).resolve().parent.parent
WH = ROOT / "data" / "warehouse"
MODES = ["plain", "sha256", "daead"]
PII = {"customers": ["email", "phone"], "orders": ["customer_email"]}


def logical_bytes(col):
    if pa.types.is_binary(col.type) or pa.types.is_string(col.type) or pa.types.is_large_string(col.type):
        return pc.sum(pc.binary_length(col)).as_py()
    if pa.types.is_fixed_size_binary(col.type):
        return len(col) * col.type.byte_width
    return len(col) * col.type.bit_width // 8


def columns(path):
    md = pq.ParquetFile(path).metadata
    out = {}
    for rg in range(md.num_row_groups):
        g = md.row_group(rg)
        for c in range(g.num_columns):
            cc = g.column(c)
            d = out.setdefault(cc.path_in_schema, {"stored": 0, "uncompressed": 0, "encodings": set()})
            d["stored"] += cc.total_compressed_size
            d["uncompressed"] += cc.total_uncompressed_size
            d["encodings"] |= set(cc.encodings)
    return out, md


CODEC_SAMPLE_ROW_GROUPS = 2


def main():
    res = {"files": {}, "codecs": {"sample_rows": CODEC_SAMPLE_ROW_GROUPS * 1_000_000}}
    for mode in MODES:
        for table in ("customers", "orders"):
            path = WH / mode / f"{table}.parquet"
            cols, md = columns(path)
            pf = pq.ParquetFile(path)
            per = {}
            for name, d in cols.items():
                lb = sum(logical_bytes(pf.read_row_group(i, columns=[name]).column(0)) for i in range(md.num_row_groups))
                per[name] = {"stored_bytes": d["stored"], "logical_bytes": lb,
                             "ratio": round(lb / d["stored"], 2), "encodings": sorted(d["encodings"])}
            res["files"][f"{mode}/{table}"] = {"file_bytes": path.stat().st_size, "rows": md.num_rows,
                                               "row_groups": md.num_row_groups, "columns": per}
            for name in PII[table]:
                one = pf.read_row_groups(list(range(CODEC_SAMPLE_ROW_GROUPS)), columns=[name])
                for codec, level in (("none", None), ("snappy", None), ("zstd", 3), ("zstd", 9)):
                    with tempfile.NamedTemporaryFile(suffix=".parquet") as f:
                        pq.write_table(one, f.name, compression=codec, compression_level=level, row_group_size=1_000_000)
                        res["codecs"][f"{mode}/{table}.{name}/{codec}{level or ''}"] = pathlib.Path(f.name).stat().st_size
    print(json.dumps(res, indent=1, default=list))


if __name__ == "__main__":
    main()
