"""lakegate's client-side pieces that are not just configuration.

PyIceberg 0.12.0 never calls the refresh endpoint: a table's FileIO keeps the credentials from
loadTable until they expire. `refreshing(catalog, table)` wraps the table's FileIO so that every
new_input/new_output first checks the expiry and, inside the prefetch window, re-fetches the
credentials from GET .../credentials (the same window Iceberg Java uses: 5 minutes)."""
import threading, time
from functools import lru_cache

PREFETCH_S = 300
EXPIRES = "s3.session-token-expires-at-ms"


def refreshing(catalog, table, log=None):
    io = table.io
    lock = threading.Lock()
    ident = table.name()
    orig_in, orig_out = io.new_input, io.new_output

    def maybe_refresh():
        exp = io.properties.get(EXPIRES)
        if not exp or int(exp) / 1000 - time.time() > PREFETCH_S:
            return
        with lock:
            exp = io.properties.get(EXPIRES)
            if int(exp) / 1000 - time.time() > PREFETCH_S:
                return
            fresh = catalog.load_credentials(ident, table.location())
            io.properties.update(fresh)
            io.fs_by_scheme = lru_cache(io._initialize_fs)
            if log:
                log(f"refreshed credentials for {'.'.join(ident)}; new expiry in "
                    f"{int(fresh[EXPIRES]) / 1000 - time.time():.0f}s")

    def new_input(location):
        maybe_refresh()
        return orig_in(location)

    def new_output(location):
        maybe_refresh()
        return orig_out(location)

    io.new_input, io.new_output = new_input, new_output
    return table
