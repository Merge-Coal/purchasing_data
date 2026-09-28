"""
push_items_clickhouse.py — Push pre-exported items JSON into ClickHouse.

Wipes the existing items table then inserts from items_for_clickhouse.json.

Usage:
  python3 push_items_clickhouse.py --host 76.13.19.246 --password "$CLICKHOUSE_PASSWORD"
  python3 push_items_clickhouse.py --host localhost
"""

import json, sys, os, argparse, requests

parser = argparse.ArgumentParser()
parser.add_argument('--host',     default='localhost')
parser.add_argument('--port',     type=int, default=8123)
parser.add_argument('--db',       default='procurement')
parser.add_argument('--user',     default='procurement_user')
parser.add_argument('--password', default=os.environ.get('CLICKHOUSE_PASSWORD', 'changeme'))
parser.add_argument('--json',     default='items_for_clickhouse.json', help='Path to items JSON export')
args = parser.parse_args()

CH_URL  = f"http://{args.host}:{args.port}"
CH_AUTH = (args.user, args.password)
CH_DB   = args.db

def ping():
    try:
        r = requests.get(f"{CH_URL}/ping", auth=CH_AUTH, timeout=5)
        return r.status_code == 200
    except Exception:
        return False

def ch_exec(sql):
    r = requests.post(f"{CH_URL}/?database={CH_DB}", data=sql.encode(), auth=CH_AUTH)
    if r.status_code != 200:
        raise RuntimeError(f"ClickHouse error: {r.text[:500]}")

def ch_insert(table, rows):
    ndjson = '\n'.join(json.dumps(row) for row in rows)
    url = f"{CH_URL}/?database={CH_DB}&query=INSERT+INTO+{table}+FORMAT+JSONEachRow"
    r = requests.post(url, data=ndjson.encode('utf-8'), auth=CH_AUTH,
                      headers={'Content-Type': 'application/x-ndjson'})
    if r.status_code != 200:
        raise RuntimeError(f"ClickHouse insert failed: {r.text[:500]}")

print(f"Connecting to ClickHouse at {CH_URL} ...")
if not ping():
    print(f"ERROR: Cannot reach ClickHouse at {CH_URL}")
    sys.exit(1)
print("Connected.\n")

json_path = os.path.join(os.path.dirname(__file__), args.json)
with open(json_path, encoding='utf-8') as f:
    items = json.load(f)
print(f"Loaded {len(items)} items from {args.json}")

print("Deleting existing items from ClickHouse ...")
ch_exec("ALTER TABLE items DELETE WHERE 1=1")
print("Waiting for delete to settle ...")
import time; time.sleep(3)

print(f"Inserting {len(items)} items ...")
ch_insert('items', items)

print(f"\nDone. {len(items)} items pushed to ClickHouse.")
