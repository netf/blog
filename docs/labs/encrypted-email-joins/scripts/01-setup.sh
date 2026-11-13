#!/usr/bin/env bash
# Installs PostgreSQL 18.6 from PGDG and the pinned Python venv. Ubuntu 24.04 (noble).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x /usr/lib/postgresql/18/bin/postgres ]; then
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -s -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    postgresql-18=18.6-1.pgdg24.04+2 postgresql-client-18=18.6-1.pgdg24.04+2 python3.12-venv
fi

# The lab VM has no systemd, so the cluster is started with pg_ctlcluster directly.
sudo pg_ctlcluster 18 main start 2>/dev/null || true
sudo -u postgres psql -qtAc "select 1 from pg_roles where rolname='lab'" | grep -q 1 \
  || sudo -u postgres psql -qc "create role lab login superuser password 'lab'"
sudo -u postgres psql -qtAc "select 1 from pg_database where datname='shop'" | grep -q 1 \
  || sudo -u postgres createdb -O lab shop

if [ ! -x .venv/bin/python ]; then
  python3 -m venv .venv
  .venv/bin/pip install -q pip==25.3
  .venv/bin/pip install -q -r requirements.txt
fi
.venv/bin/python -c "import tink, duckdb, pyarrow; print('tink', tink.__version__ if hasattr(tink,'__version__') else '1.16.1', 'duckdb', duckdb.__version__, 'pyarrow', pyarrow.__version__)"
