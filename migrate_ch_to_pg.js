#!/usr/bin/env node
'use strict';
/**
 * migrate_ch_to_pg.js — ONE-TIME copy of the live procurement data from
 * ClickHouse (old OLTP store) into PostgreSQL (new OLTP store).
 * ClickHouse itself is only read, never written.
 *
 * USAGE
 *   node migrate_ch_to_pg.js --dry-run              read + check everything, write nothing
 *   node migrate_ch_to_pg.js                        migrate (refuses if any target table has rows)
 *   node migrate_ch_to_pg.js --truncate             TRUNCATE the 14 tables + doc_counters first,
 *                                                   in the same transaction, then migrate
 *   node migrate_ch_to_pg.js --dry-run --truncate   dry run that ignores existing target rows
 *
 * ENVIRONMENT
 *   ClickHouse (source):  CLICKHOUSE_HOST (default localhost), CLICKHOUSE_PORT (8123),
 *                         CLICKHOUSE_DB (procurement), CLICKHOUSE_USER (procurement_user),
 *                         CLICKHOUSE_PASSWORD (required)
 *   Postgres (target):    PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD (standard libpq vars)
 *                         The schema (db/postgres_schema.sql) must already be loaded.
 *
 * EXIT CODES
 *   0  success (or dry run with all checks passing)
 *   1  pre-flight check failed / refused to run — NOTHING was written
 *   2  data was committed but post-load verification found a difference
 *   3  unexpected error — the transaction was rolled back, NOTHING was written
 *
 * WHAT IT DOES
 *   1. Reads the 14 tables from ClickHouse (ReplacingMergeTree tables with FINAL,
 *      soft-deleted rows included), then collapses any id that still appears more
 *      than once (FINAL dedups on the ORDER BY key, which for some tables contains
 *      a date) keeping the highest `version`.
 *   2. Converts every value to the Postgres column type and runs pre-flight checks
 *      (duplicates, orphans, roles, bad uuids/dates). Any failure ⇒ exit 1, no write.
 *   3. In ONE transaction: inserts everything in foreign-key order, lets the identity
 *      columns assign missing legacy ids (each one is reported), sets every identity
 *      sequence past max(legacy id), seeds doc_counters. COMMIT.
 *   4. Re-reads both sides and compares counts, ids and money sums. Mismatch ⇒ exit 2.
 *
 * Passwords are never printed.
 */

const http = require('http');
const { Client } = require('pg');

// ClickHouse DateTime64 columns are declared 'Asia/Jakarta'; their text output is
// Jakarta wall-clock time, so Postgres must parse them in the same zone.
const SOURCE_TIMEZONE = 'Asia/Jakarta';

// Insert order respects foreign keys.
const TABLES = [
  'purposes', 'users', 'vendors', 'items', 'pr_templates', 'pr_template_items',
  'purchase_requests', 'purchase_request_items', 'purchase_orders',
  'purchase_order_items', 'purchase_order_charges', 'approval_actions',
  'gl_exports', 'item_requests',
];

const PK = {
  purposes: 'purpose_id', users: 'user_id', vendors: 'vendor_id', items: 'item_id',
  pr_templates: 'template_id', pr_template_items: 'template_item_id',
  purchase_requests: 'pr_id', purchase_request_items: 'pr_item_id',
  purchase_orders: 'po_id', purchase_order_items: 'po_item_id',
  purchase_order_charges: 'charge_id', approval_actions: 'approval_action_id',
  gl_exports: 'gl_export_id', item_requests: 'request_id',
};

// Created at runtime by older server.js versions — may not exist yet.
const OPTIONAL_TABLES = new Set(['item_requests', 'pr_templates', 'pr_template_items', 'purchase_order_charges']);

// '' in ClickHouse means "no reference" for these uuid columns ⇒ NULL in Postgres.
const EMPTY_TO_NULL = new Set(['purchase_orders.primary_pr_id', 'purchase_order_items.pr_item_id']);

// Identity columns whose values appear in frontend URLs.
const LEGACY_COLS = {
  users: 'legacy_user_id', purchase_requests: 'legacy_pr_id',
  purchase_request_items: 'legacy_pr_item_id', purchase_orders: 'legacy_po_id',
  purchase_order_items: 'legacy_po_item_id',
};

const CAP = 50;          // max lines listed per check
const EXIT_PREFLIGHT = 1, EXIT_VERIFY = 2, EXIT_ERROR = 3;

// ── CLI ──────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const opts = { dryRun: false, truncate: false };
for (const a of argv) {
  if (a === '--dry-run') opts.dryRun = true;
  else if (a === '--truncate') opts.truncate = true;
  else if (a === '--help' || a === '-h') {
    console.log(require('fs').readFileSync(__filename, 'utf8').split('\n').slice(2, 36).join('\n'));
    process.exit(0);
  } else { console.error(`Unknown argument: ${a}  (use --dry-run, --truncate, --help)`); process.exit(EXIT_PREFLIGHT); }
}

// ── ClickHouse (read-only, minimal HTTP client) ──────────────────────────────
if (!process.env.CLICKHOUSE_PASSWORD) { console.error('CLICKHOUSE_PASSWORD env var is required'); process.exit(EXIT_PREFLIGHT); }
const CH = {
  host: process.env.CLICKHOUSE_HOST || 'localhost',
  port: parseInt(process.env.CLICKHOUSE_PORT || '8123', 10),
  db:   process.env.CLICKHOUSE_DB   || 'procurement',
  user: process.env.CLICKHOUSE_USER || 'procurement_user',
  password: process.env.CLICKHOUSE_PASSWORD,
};

const chSettings = {
  output_format_json_quote_64bit_integers: '1',   // Int64/UInt64 as strings (no precision loss)
  date_time_output_format: 'simple',              // 'YYYY-MM-DD hh:mm:ss.mmm' in the column's zone
};

function chQuery(sql) {
  const params = new URLSearchParams({ database: CH.db, ...chSettings });
  const body = Buffer.from(`${sql.trim()}\nFORMAT JSONEachRow`, 'utf8');
  const auth = Buffer.from(`${CH.user}:${CH.password}`).toString('base64');
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: CH.host, port: CH.port, path: `/?${params}`, method: 'POST', timeout: 300000,
      headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': body.length, Authorization: `Basic ${auth}` },
    }, (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      // Connection dropped mid-body: Node emits neither 'end' nor 'error' here, so
      // without this the promise would never settle and the migration would hang.
      res.on('close', () => { if (!res.complete) reject(new Error('ClickHouse connection closed before the response body was complete (truncated read)')); });
      res.on('error', reject);
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode !== 200) return reject(new Error(`ClickHouse HTTP ${res.statusCode}: ${text.slice(0, 500)}`));
        try { resolve(text.split('\n').filter(l => l.trim()).map(l => JSON.parse(l))); }
        catch (e) { reject(new Error(`Cannot parse ClickHouse JSON: ${e.message}`)); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('ClickHouse request timed out')));
    req.on('error', reject);
    req.end(body);
  });
}

const sqlStr = s => `'${String(s).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;

// ── Small helpers ────────────────────────────────────────────────────────────
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TS_RE   = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{1,9})?$/;
const DEC_RE  = /^-?\d+(\.\d+)?$/;
const INT_RE  = /^-?\d+$/;
const INT_RANGE = { smallint: [-32768n, 32767n], integer: [-2147483648n, 2147483647n], bigint: [-(2n ** 63n), 2n ** 63n - 1n] };

function capList(lines) {
  if (lines.length <= CAP) return lines;
  return [...lines.slice(0, CAP), `... and ${lines.length - CAP} more`];
}

function pad(s, n) { s = String(s); return s.length >= n ? s : s + ' '.repeat(n - s.length); }
function lpad(s, n) { s = String(s); return s.length >= n ? s : ' '.repeat(n - s.length) + s; }
function printTable(headers, rows) {
  const w = headers.map((h, i) => Math.max(h.length, ...rows.map(r => String(r[i]).length)));
  const line = cells => cells.map((c, i) => (i === 0 ? pad(c, w[i]) : lpad(c, w[i]))).join('  ');
  console.log('  ' + line(headers));
  console.log('  ' + w.map(n => '-'.repeat(n)).join('  '));
  for (const r of rows) console.log('  ' + line(r));
}

// Exact decimal arithmetic on strings (scaled BigInt with 9 decimals).
const DEC_SCALE = 9;
function decToBig(s) {
  s = String(s);
  if (!DEC_RE.test(s)) throw new Error(`not a decimal: ${s}`);
  const neg = s.startsWith('-'); if (neg) s = s.slice(1);
  const [i, f = ''] = s.split('.');
  const v = BigInt(i) * 10n ** BigInt(DEC_SCALE) + BigInt((f + '0'.repeat(DEC_SCALE)).slice(0, DEC_SCALE) || '0');
  return neg ? -v : v;
}
function bigToDec(v) {
  const neg = v < 0n; if (neg) v = -v;
  const base = 10n ** BigInt(DEC_SCALE);
  let f = (v % base).toString().padStart(DEC_SCALE, '0').replace(/0+$/, '');
  return `${neg ? '-' : ''}${v / base}${f ? '.' + f : ''}`;
}
function sumDec(values) { let t = 0n; for (const v of values) if (v !== null && v !== undefined) t += decToBig(v); return bigToDec(t); }
function normDec(s) { return s === null || s === undefined ? '0' : bigToDec(decToBig(s)); }

function numToDecString(v) {
  if (typeof v === 'number') {
    if (!Number.isFinite(v)) return null;
    let s = String(v);
    if (/e/i.test(s)) s = v.toFixed(12).replace(/\.?0+$/, '');
    return s;
  }
  return String(v);
}

// ── Source: read + dedup ─────────────────────────────────────────────────────
async function readMeta() {
  const list = TABLES.map(sqlStr).join(', ');
  const tables = await chQuery(`SELECT name, engine, sorting_key FROM system.tables WHERE database = currentDatabase() AND name IN (${list})`);
  const cols = await chQuery(`SELECT table, name, type FROM system.columns WHERE database = currentDatabase() AND table IN (${list})`);
  const quoteDec = await chQuery(`SELECT name FROM system.settings WHERE name = 'output_format_json_quote_decimals'`);
  const meta = {};
  for (const t of tables) meta[t.name] = { engine: t.engine, sortingKey: t.sorting_key, columns: {} };
  for (const c of cols) if (meta[c.table]) meta[c.table].columns[c.name] = c.type;
  return { meta, quoteDecimalsSupported: quoteDec.length > 0 };
}

async function readSource(meta) {
  const src = {};
  for (const t of TABLES) {
    const m = meta[t];
    if (!m) { src[t] = { missing: true, raw: 0, rows: [], collapsed: [], engine: '-' }; continue; }
    const replacing = /ReplacingMergeTree/.test(m.engine);
    const rows = await chQuery(`SELECT * FROM ${t}${replacing ? ' FINAL' : ''}`);
    const pk = PK[t];
    const byId = new Map(); const collapsed = []; const badPk = []; const ambiguous = [];
    for (const r of rows) {
      const id = r[pk];
      if (id === null || id === undefined || id === '') { badPk.push(r); continue; }
      const prev = byId.get(id);
      if (!prev) { byId.set(id, r); continue; }
      const same = JSON.stringify(prev) === JSON.stringify(r);
      if (!('version' in r)) {   // plain MergeTree: no version to choose by
        collapsed.push(`${id} (duplicate row, ${same ? 'identical' : 'CONTENT DIFFERS'})`);
        if (!same) ambiguous.push(`${id}: two different rows, no version column to choose by`);
        continue;
      }
      const pv = BigInt(prev.version ?? 0), rv = BigInt(r.version ?? 0);
      collapsed.push(`${id} (versions ${pv} / ${rv}${pv === rv ? (same ? ' — identical' : ' — SAME VERSION, CONTENT DIFFERS') : ''})`);
      if (pv === rv && !same) ambiguous.push(`${id}: two different rows with the same version ${rv}`);
      if (rv > pv) byId.set(id, r);
    }
    src[t] = { missing: false, engine: m.engine, final: replacing, raw: rows.length, rows: [...byId.values()], collapsed, badPk, ambiguous };
  }
  return src;
}

// ── Target metadata ──────────────────────────────────────────────────────────
async function readTargetCols(pg) {
  const r = await pg.query(`
    SELECT table_name, column_name, data_type, is_nullable, is_identity
      FROM information_schema.columns
     WHERE table_schema = current_schema() AND table_name = ANY($1)
     ORDER BY table_name, ordinal_position`, [TABLES]);
  const out = {};
  for (const c of r.rows) (out[c.table_name] ||= []).push({
    name: c.column_name, type: c.data_type, nullable: c.is_nullable === 'YES', identity: c.is_identity === 'YES',
  });
  const missing = TABLES.filter(t => !out[t]);
  if (missing.length) throw new Error(`Postgres is missing tables: ${missing.join(', ')} — load db/postgres_schema.sql first`);
  return out;
}

// ── Convert one value to what Postgres expects (string/null) ─────────────────
function convert(t, col, v, chType) {
  const key = `${t}.${col.name}`;
  const nul = () => {
    if (col.nullable) return { v: null };
    if (col.identity) return { v: null, deferIdentity: true };
    return { err: 'NULL for NOT NULL column' };
  };
  if (v === null || v === undefined) return nul();
  switch (col.type) {
    case 'uuid': {
      if (v === '' && EMPTY_TO_NULL.has(key)) return { v: null };
      if (typeof v !== 'string' || !UUID_RE.test(v)) return { err: `invalid uuid ${JSON.stringify(v)}` };
      return { v: v.toLowerCase() };
    }
    case 'date':
      if (typeof v !== 'string' || !DATE_RE.test(v)) return { err: `invalid date ${JSON.stringify(v)}` };
      return { v };
    case 'timestamp with time zone':
      if (typeof v !== 'string' || !TS_RE.test(v)) return { err: `invalid timestamp ${JSON.stringify(v)}` };
      return { v };
    case 'numeric': {
      const s = numToDecString(v);
      if (s === null || !DEC_RE.test(s)) return { err: `invalid numeric ${JSON.stringify(v)}` };
      return { v: s };
    }
    case 'smallint': case 'integer': case 'bigint': {
      const s = typeof v === 'number' ? (Number.isSafeInteger(v) ? String(v) : null) : String(v);
      if (s === null || !INT_RE.test(s)) return { err: `invalid ${col.type} ${JSON.stringify(v)}` };
      const [lo, hi] = INT_RANGE[col.type]; const b = BigInt(s);
      if (b < lo || b > hi) return { err: `${col.type} out of range ${s}` };
      return { v: s };
    }
    case 'text': case 'character': case 'character varying': {
      let s = typeof v === 'string' ? v : (typeof v === 'number' || typeof v === 'boolean' ? String(v) : null);
      if (s === null) return { err: `non-scalar value for text column` };
      let stripped = false;
      if (chType && /FixedString/.test(chType) && /\u0000+$/.test(s)) { s = s.replace(/\u0000+$/, ''); stripped = true; }
      if (s.includes('\u0000')) return { err: 'contains NUL byte (not storable in Postgres text)' };
      return { v: s, stripped };
    }
    default:
      return { err: `unsupported Postgres type ${col.type}` };
  }
}

// Build the insert plan for every table + collect conversion errors.
function buildPlan(src, meta, tcols) {
  const plan = {}; const convErrors = []; const notes = [];
  for (const t of TABLES) {
    const s = src[t];
    const cols = tcols[t];
    const srcCols = s.missing ? [] : Object.keys(meta[t].columns);
    const tNames = new Set(cols.map(c => c.name));
    const used = cols.filter(c => srcCols.includes(c.name));
    const dropped = srcCols.filter(c => !tNames.has(c));
    const defaulted = cols.filter(c => !srcCols.includes(c.name)).map(c => c.name);
    const explicit = []; const deferred = []; let strippedNul = 0;
    for (const p of s.badPk || []) convErrors.push(`${t}: row with empty/NULL ${PK[t]} ${JSON.stringify(p).slice(0, 200)}`);
    for (const r of s.rows) {
      const out = {}; let defer = null;
      for (const c of used) {
        const res = convert(t, c, r[c.name], meta[t].columns[c.name]);
        if (res.err) { convErrors.push(`${t} ${r[PK[t]]} .${c.name}: ${res.err}`); continue; }
        if (res.stripped) strippedNul++;
        if (res.deferIdentity) defer = c.name; else out[c.name] = res.v;
      }
      (defer ? deferred : explicit).push({ row: out, deferCol: defer });
    }
    // Soft-delete flag present in ClickHouse but no such column in Postgres?
    if (!s.missing && dropped.includes('is_deleted')) {
      const del = s.rows.filter(r => Number(r.is_deleted) === 1).map(r => r[PK[t]]);
      if (del.length) notes.push({ table: t, lines: capList(del),
        title: `${t}: ${del.length} row(s) are is_deleted=1 in ClickHouse but Postgres ${t} has no is_deleted column — they will be loaded as normal rows` });
    }
    if (strippedNul) notes.push({ table: t, title: `${t}: stripped trailing NUL padding from ${strippedNul} FixedString value(s)`, lines: [] });
    deferred.sort((a, b) => String(a.row.created_at || '').localeCompare(String(b.row.created_at || '')) || String(a.row[PK[t]]).localeCompare(String(b.row[PK[t]])));
    plan[t] = { used: used.map(c => c.name), dropped, defaulted, explicit, deferred,
      identityCols: cols.filter(c => c.identity).map(c => c.name) };
  }
  return { plan, convErrors, notes };
}

// ── Pre-flight checks ────────────────────────────────────────────────────────
function preflight(src, plan, convErrors) {
  const fails = [];
  const add = (title, lines) => { if (lines.length) fails.push({ title, lines: capList(lines) }); };
  const rows = t => src[t].rows;
  const live = r => Number(r.is_deleted ?? 0) === 0;

  add('Values that cannot be converted to the Postgres column type', convErrors);
  for (const t of TABLES) add(`${t}: same id twice and no way to tell which row is current`, src[t].ambiguous || []);

  // Duplicate primary keys after dedup (sanity — dedup makes this impossible).
  for (const t of TABLES) {
    const seen = new Set(); const d = [];
    for (const e of [...plan[t].explicit, ...plan[t].deferred]) { const id = e.row[PK[t]]; if (seen.has(id)) d.push(id); seen.add(id); }
    add(`${t}: duplicate ${PK[t]} after dedup`, d);
  }

  const dupBy = (list, keyFn, labelFn) => {
    const m = new Map();
    for (const r of list) { const k = keyFn(r); if (k === null) continue; (m.get(k) || m.set(k, []).get(k)).push(r); }
    const out = [];
    for (const [k, rs] of m) if (rs.length > 1) out.push(`${k}: ${rs.map(labelFn).join(', ')}`);
    return out;
  };
  const lbl = t => r => `${r[PK[t]]}${live(r) ? '' : ' (deleted)'}`;
  add('purchase_requests: duplicate pr_number (all rows, incl. deleted — UNIQUE in Postgres)',
    dupBy(rows('purchase_requests'), r => r.pr_number, lbl('purchase_requests')));
  add('purchase_orders: duplicate po_number (all rows, incl. deleted — UNIQUE in Postgres)',
    dupBy(rows('purchase_orders'), r => r.po_number, lbl('purchase_orders')));
  add('users: duplicate live username per company (is_deleted = 0)',
    dupBy(rows('users').filter(live), r => `${r.company_id}/${r.username}`, lbl('users')));
  for (const [t, col] of Object.entries(LEGACY_COLS)) {
    add(`${t}: duplicate ${col}`, dupBy(rows(t), r => (r[col] === null || r[col] === undefined ? null : String(r[col])), lbl(t)));
  }

  // Orphans (all rows — the foreign keys apply to deleted rows too).
  const ids = t => new Set(rows(t).map(r => String(r[PK[t]]).toLowerCase()));
  const prIds = ids('purchase_requests'), itemIds = new Set(rows('items').map(r => r.item_id));
  const poIds = ids('purchase_orders'), priIds = ids('purchase_request_items'), tplIds = new Set(rows('pr_templates').map(r => r.template_id));
  const orphan = (t, col, set, allowEmpty, ci = true) => rows(t)
    .filter(r => { const v = r[col]; if (allowEmpty && (v === '' || v === null)) return false; return !set.has(ci ? String(v).toLowerCase() : v); })
    .map(r => `${r[PK[t]]} -> ${col}=${JSON.stringify(r[col])}${live(r) ? '' : ' (deleted)'}`);
  add('purchase_request_items.pr_id not in purchase_requests', orphan('purchase_request_items', 'pr_id', prIds, false));
  add('purchase_request_items.item_id not in items', orphan('purchase_request_items', 'item_id', itemIds, false, false));
  add('purchase_order_items.po_id not in purchase_orders', orphan('purchase_order_items', 'po_id', poIds, false));
  add('purchase_order_items.pr_item_id (non-empty) not in purchase_request_items', orphan('purchase_order_items', 'pr_item_id', priIds, true));
  add('purchase_order_items.item_id not in items', orphan('purchase_order_items', 'item_id', itemIds, false, false));
  add('purchase_orders.primary_pr_id (non-empty) not in purchase_requests', orphan('purchase_orders', 'primary_pr_id', prIds, true));
  add('purchase_order_charges.po_id not in purchase_orders', orphan('purchase_order_charges', 'po_id', poIds, false));
  add('pr_template_items.template_id not in pr_templates', orphan('pr_template_items', 'template_id', tplIds, false, false));

  const ROLES = new Set(['requester', 'purchasing', 'md', 'admin']);
  add("users.role not in ('requester','purchasing','md','admin')",
    rows('users').filter(r => !ROLES.has(r.role)).map(r => `${r.user_id} ${r.username}: role=${JSON.stringify(r.role)}${live(r) ? '' : ' (deleted)'}`));
  return fails;
}

// doc_counters from document numbers (all rows, incl. deleted: numbers are UNIQUE).
function computeCounters(src) {
  const c = new Map();
  const bump = (type, year, n) => { const k = `${type}|${year}`; if (!c.has(k) || c.get(k) < n) c.set(k, n); };
  for (const r of src.purchase_requests.rows) { const m = /^PR-(\d{4})-(\d+)$/.exec(r.pr_number); if (m) bump('PR', +m[1], +m[2]); }
  for (const r of src.purchase_orders.rows)   { const m = /^PO-(\d{4})-(\d+)$/.exec(r.po_number); if (m) bump('PO', +m[1], +m[2]); }
  for (const r of src.items.rows)   { const m = /^ITEM-(\d+)$/.exec(r.item_id);   if (m) bump('ITEM', 0, +m[1]); }
  for (const r of src.vendors.rows) { const m = /^V-(\d+)$/.exec(r.vendor_id);    if (m) bump('V', 0, +m[1]); }
  return [...c.entries()].map(([k, n]) => { const [t, y] = k.split('|'); return { doc_type: t, year: +y, last_no: n }; })
    .sort((a, b) => a.doc_type.localeCompare(b.doc_type) || a.year - b.year);
}

// ── Postgres write ───────────────────────────────────────────────────────────
const qi = s => `"${s.replace(/"/g, '""')}"`;

async function insertRows(pg, t, cols, rows, returning) {
  if (!rows.length || !cols.length) return [];
  const batch = Math.max(1, Math.min(500, Math.floor(30000 / cols.length)));
  const out = [];
  for (let i = 0; i < rows.length; i += batch) {
    const chunk = rows.slice(i, i + batch);
    const vals = []; const tuples = [];
    for (const r of chunk) {
      tuples.push(`(${cols.map(c => { vals.push(r[c] === undefined ? null : r[c]); return `$${vals.length}`; }).join(', ')})`);
    }
    const sql = `INSERT INTO ${qi(t)} (${cols.map(qi).join(', ')}) VALUES ${tuples.join(', ')}${returning ? ` RETURNING ${returning}` : ''}`;
    const res = await pg.query(sql, vals);
    out.push(...res.rows);
  }
  return out;
}

async function setIdentitySeq(pg, t, col) {
  const r = await pg.query(
    `SELECT setval(pg_get_serial_sequence($1, $2), COALESCE(max(${qi(col)}), 1), max(${qi(col)}) IS NOT NULL) AS v FROM ${qi(t)}`, [t, col]);
  return r.rows[0].v;
}

async function targetCounts(pg) {
  const out = {};
  for (const t of [...TABLES, 'doc_counters']) out[t] = Number((await pg.query(`SELECT count(*) AS n FROM ${qi(t)}`)).rows[0].n);
  return out;
}

async function write(pg, plan, counters) {
  const assigned = [];
  const seqs = [];
  await pg.query('BEGIN');
  try {
    await pg.query(`SET LOCAL TIME ZONE '${SOURCE_TIMEZONE}'`);
    if (opts.truncate) {
      console.log(`  TRUNCATE ${TABLES.length} tables + doc_counters RESTART IDENTITY CASCADE`);
      await pg.query(`TRUNCATE TABLE ${[...TABLES, 'doc_counters'].map(qi).join(', ')} RESTART IDENTITY CASCADE`);
    } else {
      await pg.query(`LOCK TABLE ${TABLES.map(qi).join(', ')} IN SHARE ROW EXCLUSIVE MODE`);
      const counts = await targetCounts(pg);
      const nonEmpty = TABLES.filter(t => counts[t] > 0);
      if (nonEmpty.length) throw Object.assign(new Error(`target tables not empty: ${nonEmpty.join(', ')}`), { refusal: true });
    }
    for (const t of TABLES) {
      const p = plan[t];
      await insertRows(pg, t, p.used, p.explicit.map(e => e.row));
      for (const col of p.identityCols) await setIdentitySeq(pg, t, col);
      for (const d of p.deferred) {
        const cols = p.used.filter(c => c !== d.deferCol);
        const [r] = await insertRows(pg, t, cols, [d.row], `${qi(PK[t])}::text AS id, ${qi(d.deferCol)}::text AS legacy`);
        assigned.push({ table: t, id: r.id, col: d.deferCol, legacy: r.legacy });
      }
      for (const col of p.identityCols) seqs.push({ table: t, col, value: await setIdentitySeq(pg, t, col) });
      process.stdout.write(`  ${pad(t, 24)} ${lpad(p.explicit.length + p.deferred.length, 6)} rows\n`);
    }
    for (const c of counters) {
      await pg.query(`INSERT INTO doc_counters (doc_type, year, last_no) VALUES ($1, $2, $3)
                      ON CONFLICT (doc_type, year) DO UPDATE SET last_no = GREATEST(doc_counters.last_no, EXCLUDED.last_no)`,
        [c.doc_type, c.year, c.last_no]);
    }
    await pg.query('COMMIT');
  } catch (e) {
    await pg.query('ROLLBACK').catch(() => {});
    throw e;
  }
  return { assigned, seqs };
}

// ── Verification ─────────────────────────────────────────────────────────────
async function verify(pg, meta) {
  console.log('\n== Verification (re-reading ClickHouse and Postgres) ==');
  const src = await readSource(meta);
  let ok = true;
  const rowsOut = [];
  for (const t of TABLES) {
    const s = src[t];
    const chIds = new Set(s.rows.map(r => String(r[PK[t]]).toLowerCase()));
    const pgIds = new Set((await pg.query(`SELECT ${qi(PK[t])}::text AS id FROM ${qi(t)}`)).rows.map(r => r.id.toLowerCase()));
    const hasDel = (await pg.query(`SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND column_name = 'is_deleted'`, [t])).rowCount > 0;
    const chLive = hasDel ? s.rows.filter(r => Number(r.is_deleted ?? 0) === 0).length : '-';
    const pgLive = hasDel ? Number((await pg.query(`SELECT count(*) AS n FROM ${qi(t)} WHERE is_deleted = 0`)).rows[0].n) : '-';
    const missing = [...chIds].filter(i => !pgIds.has(i)).length;
    const extra = [...pgIds].filter(i => !chIds.has(i)).length;
    const good = chIds.size === pgIds.size && chLive === pgLive && !missing && !extra;
    if (!good) ok = false;
    rowsOut.push([t, chIds.size, pgIds.size, chLive, pgLive, missing, extra, good ? 'OK' : 'MISMATCH']);
  }
  printTable(['table', 'ch_rows', 'pg_rows', 'ch_live', 'pg_live', 'missing_in_pg', 'extra_in_pg', ''], rowsOut);

  const sums = [];
  const liveRows = t => src[t].rows.filter(r => Number(r.is_deleted ?? 0) === 0);
  const pgSum = async (t, col) => normDec((await pg.query(`SELECT COALESCE(sum(${qi(col)}), 0)::text AS s FROM ${qi(t)} WHERE is_deleted = 0`)).rows[0].s);
  for (const [t, col] of [['purchase_orders', 'total_amount'], ['purchase_orders', 'subtotal_amount'], ['purchase_request_items', 'requested_qty']]) {
    const c = sumDec(liveRows(t).map(r => numToDecString(r[col])));
    const p = await pgSum(t, col);
    if (c !== p) ok = false;
    sums.push([`${t}.${col} (live)`, c, p, c === p ? 'OK' : 'MISMATCH']);
  }
  console.log('');
  printTable(['sum', 'clickhouse', 'postgres', ''], sums);
  return ok;
}

// ── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  const t0 = Date.now();
  console.log(`migrate_ch_to_pg  mode=${opts.dryRun ? 'DRY-RUN' : 'WRITE'}${opts.truncate ? ' +TRUNCATE' : ''}`);
  console.log(`  source  ClickHouse http://${CH.user}@${CH.host}:${CH.port}/${CH.db}`);

  const pg = new Client();
  pg.on('notice', n => console.log(`  [postgres notice] ${n.message}`));
  await pg.connect();
  const who = (await pg.query('SELECT current_user AS u, current_database() AS d, inet_server_addr()::text AS h, inet_server_port() AS p, version() AS v')).rows[0];
  console.log(`  target  Postgres ${who.u}@${who.h || 'socket'}:${who.p || ''}/${who.d}  (${who.v.split(' on ')[0]})`);
  await pg.query(`SET TIME ZONE '${SOURCE_TIMEZONE}'`);

  try {
    // 1. Read source
    console.log('\n== Reading ClickHouse ==');
    const { meta, quoteDecimalsSupported } = await readMeta();
    if (quoteDecimalsSupported) chSettings.output_format_json_quote_decimals = '1';
    else console.log('  WARNING: server lacks output_format_json_quote_decimals — Decimals arrive as JSON numbers (possible float rounding > 15 significant digits)');
    const missingRequired = TABLES.filter(t => !meta[t] && !OPTIONAL_TABLES.has(t));
    if (missingRequired.length) {
      console.error(`\nPRE-FLIGHT FAILED: ClickHouse database '${CH.db}' has no table(s): ${missingRequired.join(', ')}`);
      return EXIT_PREFLIGHT;
    }
    const src = await readSource(meta);
    const tcols = await readTargetCols(pg);
    const { plan, convErrors, notes } = buildPlan(src, meta, tcols);

    printTable(['table', 'engine', 'read', 'collapsed', 'rows', 'live', 'deleted', 'new_legacy_id'],
      TABLES.map(t => {
        const s = src[t];
        if (s.missing) return [t, 'MISSING (treated as empty)', 0, 0, 0, 0, 0, 0];
        const lv = s.rows.filter(r => Number(r.is_deleted ?? 0) === 0).length;
        return [t, `${s.engine}${s.final ? ' FINAL' : ''}`, s.raw, s.collapsed.length, s.rows.length, lv, s.rows.length - lv, plan[t].deferred.length];
      }));

    for (const t of TABLES) {
      if (src[t].missing) console.log(`  note: ClickHouse table ${t} does not exist — treated as empty`);
      if (src[t].collapsed.length) {
        console.log(`  note: ${t}: ${src[t].collapsed.length} id(s) appeared more than once after ${src[t].final ? 'FINAL' : 'SELECT'}; kept the highest version (or the identical copy):`);
        for (const l of capList(src[t].collapsed)) console.log(`        ${l}`);
      }
      const dropped = plan[t].dropped.filter(c => c !== 'version');
      if (dropped.length) console.log(`  note: ${t}: ClickHouse columns not copied: ${dropped.join(', ')}`);
      if (!src[t].missing && plan[t].defaulted.length) console.log(`  note: ${t}: Postgres columns absent in ClickHouse (DB default used): ${plan[t].defaulted.join(', ')}`);
    }
    console.log('  note: the ClickHouse `version` column is not copied (Postgres has none)');
    for (const n of notes) { console.log(`  WARNING: ${n.title}`); for (const l of n.lines) console.log(`        ${l}`); }

    // 2. Pre-flight
    console.log('\n== Pre-flight checks ==');
    const fails = preflight(src, plan, convErrors);
    const counts = await targetCounts(pg);
    const nonEmpty = TABLES.filter(t => counts[t] > 0);
    if (nonEmpty.length && !opts.truncate) {
      fails.push({ title: 'Postgres target tables already contain rows (pass --truncate to replace them)',
        lines: nonEmpty.map(t => `${t}: ${counts[t]} rows`) });
    } else if (nonEmpty.length) {
      console.log(`  --truncate: existing rows will be DELETED in: ${nonEmpty.map(t => `${t} (${counts[t]})`).join(', ')}`);
    }
    if (counts.doc_counters > 0) console.log(`  note: doc_counters already has ${counts.doc_counters} row(s)${opts.truncate ? ' (will be truncated)' : ' (merged with GREATEST)'}`);
    if (fails.length) {
      console.error(`\nPRE-FLIGHT FAILED — ${fails.length} check(s). Nothing was written.`);
      for (const f of fails) { console.error(`\n  ✗ ${f.title}`); for (const l of f.lines) console.error(`      ${l}`); }
      return EXIT_PREFLIGHT;
    }
    console.log('  all checks passed');

    const counters = computeCounters(src);
    console.log('\n== doc_counters to seed ==');
    printTable(['doc_type', 'year', 'last_no'], counters.map(c => [c.doc_type, c.year, c.last_no]));

    const deferredTotal = TABLES.reduce((n, t) => n + plan[t].deferred.length, 0);
    if (deferredTotal) {
      console.log(`\n== Rows with NULL legacy id (Postgres identity will assign; ids appear in frontend URLs) ==`);
      for (const t of TABLES) {
        if (!plan[t].deferred.length) continue;
        const col = plan[t].deferred[0].deferCol;
        let next = plan[t].explicit.reduce((m, e) => (e.row[col] != null && BigInt(e.row[col]) > m ? BigInt(e.row[col]) : m), 0n);
        for (const d of plan[t].deferred) console.log(`  ${t}  ${d.row[PK[t]]}  ${d.deferCol} = ${++next} (expected; final value printed after load)`);
      }
    }

    if (opts.dryRun) {
      console.log(`\nDRY RUN complete — nothing written. ${TABLES.reduce((n, t) => n + src[t].rows.length, 0)} rows would be inserted. (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
      return 0;
    }

    // 3. Write
    console.log('\n== Writing to Postgres (single transaction) ==');
    let result;
    try { result = await write(pg, plan, counters); }
    catch (e) {
      if (e.refusal) { console.error(`\nREFUSED: ${e.message}. Nothing was written. Use --truncate to replace existing data.`); return EXIT_PREFLIGHT; }
      console.error(`\nERROR during load — transaction ROLLED BACK, nothing was written.\n  ${e.message}${e.detail && e.table !== 'users' ? `\n  detail: ${e.detail}` : ''}${e.table ? `\n  table: ${e.table}` : ''}`);
      return EXIT_ERROR;
    }
    console.log('  COMMIT ok');
    if (result.assigned.length) {
      console.log('\n== Legacy ids ASSIGNED by Postgres (were NULL in ClickHouse) ==');
      printTable(['table', 'id', 'column', 'new_value'], result.assigned.map(a => [a.table, a.id, a.col, a.legacy]));
    }
    console.log('\n== Identity sequences (next insert gets value+1) ==');
    printTable(['table', 'column', 'value'], result.seqs.map(s => [s.table, s.col, s.value]));

    // 4. Verify
    const ok = await verify(pg, meta);
    const total = TABLES.reduce((n, t) => n + plan[t].explicit.length + plan[t].deferred.length, 0);
    console.log(`\nSUMMARY: ${total} rows migrated into ${TABLES.length} tables, ${counters.length} doc_counters, ${result.assigned.length} legacy id(s) assigned. ` +
      `Verification ${ok ? 'PASSED' : 'FAILED'}. (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    return ok ? 0 : EXIT_VERIFY;
  } finally {
    await pg.end().catch(() => {});
  }
}

main().then(code => process.exit(code)).catch(e => {
  console.error(`\nFATAL: ${e.message}\nNothing was written unless "COMMIT ok" was printed above.`);
  process.exit(EXIT_ERROR);
});
