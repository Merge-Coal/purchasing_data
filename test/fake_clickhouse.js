#!/usr/bin/env node
'use strict';
/**
 * test/fake_clickhouse.js — a tiny stand-in for the ClickHouse HTTP interface,
 * just enough for migrate_ch_to_pg.js. Test use only.
 *
 *   FIXTURE_DIRS=test/fixtures/base:test/fixtures/extra  FAKE_CH_PORT=18123  \
 *   FAKE_CH_PASSWORD=secret  node test/fake_clickhouse.js
 *
 * Fixtures: one <table>.json per table, either a full definition
 *   { "engine": "ReplacingMergeTree(version)", "order_by": [...], "columns": {name: type, ...}, "rows": [...] }
 * or, in a later directory, an overlay { "append_rows": [...] } added to the earlier definition.
 * Rows are stored in ClickHouse's JSON output shape; omitted columns get type defaults.
 *
 * Emulates:
 *  - system.tables / system.columns / system.settings metadata queries
 *  - SELECT * FROM t [FINAL]: FINAL keeps the highest `version` per ORDER BY key
 *    (like ReplacingMergeTree), so an id whose date column changed stays duplicated.
 *  - output_format_json_quote_64bit_integers / output_format_json_quote_decimals
 *  - HTTP Basic auth against FAKE_CH_PASSWORD
 */
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.FAKE_CH_PORT || '18123', 10);
const PASSWORD = process.env.FAKE_CH_PASSWORD || 'secret';
const DIRS = (process.env.FIXTURE_DIRS || path.join(__dirname, 'fixtures', 'base')).split(':').filter(Boolean);
const NO_QUOTE_DECIMALS = process.env.FAKE_NO_QUOTE_DECIMALS === '1';

const tables = {};
for (const dir of DIRS) {
  for (const f of fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort()) {
    const name = f.replace(/\.json$/, '');
    const def = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    if (def.append_rows) {
      if (!tables[name]) throw new Error(`${dir}/${f}: append_rows without base definition`);
      tables[name].rows.push(...def.append_rows);
    } else {
      tables[name] = { ...def, rows: [...def.rows] };
    }
  }
}

const base = t => t.replace(/^(LowCardinality|Nullable)\((.*)\)$/, '$2').replace(/^(LowCardinality|Nullable)\((.*)\)$/, '$2');
function defaultFor(type) {
  if (/^Nullable\(/.test(type)) return null;
  const b = base(type);
  if (/^U?Int(64|128|256)$/.test(b)) return '0';
  if (/^U?Int\d+$/.test(b) || /^Float/.test(b)) return 0;
  if (/^Decimal/.test(b)) return '0';
  if (/^DateTime64/.test(b)) return '1970-01-01 07:00:00.000';
  if (/^DateTime/.test(b)) return '1970-01-01 07:00:00';
  if (/^Date/.test(b)) return '1970-01-01';
  if (/^UUID/.test(b)) return '00000000-0000-0000-0000-000000000000';
  if (/^FixedString\((\d+)\)/.test(b)) return '\u0000'.repeat(+/\((\d+)\)/.exec(b)[1]);
  return '';
}
function render(def, row, settings) {
  const out = {};
  for (const [col, type] of Object.entries(def.columns)) {
    let v = Object.prototype.hasOwnProperty.call(row, col) ? row[col] : defaultFor(type);
    const b = base(type);
    if (v !== null) {
      if (/^U?Int(64|128|256)$/.test(b)) v = settings.get('output_format_json_quote_64bit_integers') === '0' ? Number(v) : String(v);
      else if (/^Decimal/.test(b)) v = settings.get('output_format_json_quote_decimals') === '1' ? String(v) : Number(v);
    }
    out[col] = v;
  }
  return out;
}

function final(def) {
  const byKey = new Map();
  for (const r of def.rows) {
    const k = JSON.stringify(def.order_by.map(c => r[c]));
    const prev = byKey.get(k);
    if (!prev || BigInt(r.version ?? 0) >= BigInt(prev.version ?? 0)) byKey.set(k, r);
  }
  return [...byKey.values()];
}

const inList = (sql, col) => {
  const m = new RegExp(`${col}\\s+IN\\s*\\(([^)]*)\\)`, 'i').exec(sql);
  return m ? new Set([...m[1].matchAll(/'([^']*)'/g)].map(x => x[1])) : null;
};

function answer(sql, settings) {
  if (!/FORMAT JSONEachRow\s*$/i.test(sql)) throw new Error('fake: only FORMAT JSONEachRow supported');
  if (/FROM system\.tables/i.test(sql)) {
    const names = inList(sql, 'name');
    return Object.entries(tables).filter(([n]) => !names || names.has(n))
      .map(([n, d]) => ({ name: n, engine: d.engine.replace(/\(.*$/, ''), sorting_key: d.order_by.join(', ') }));
  }
  if (/FROM system\.columns/i.test(sql)) {
    const names = inList(sql, 'table');
    const out = [];
    for (const [n, d] of Object.entries(tables)) if (!names || names.has(n))
      for (const [c, t] of Object.entries(d.columns)) out.push({ table: n, name: c, type: t });
    return out;
  }
  if (/FROM system\.settings/i.test(sql)) return NO_QUOTE_DECIMALS ? [] : [{ name: 'output_format_json_quote_decimals' }];
  const m = /^\s*SELECT \* FROM (\w+)( FINAL)?\s*FORMAT/i.exec(sql);
  if (m) {
    const def = tables[m[1]];
    if (!def) { const e = new Error(`Code: 60. DB::Exception: Table procurement.${m[1]} does not exist. (UNKNOWN_TABLE)`); e.status = 404; throw e; }
    const rows = m[2] && /Replacing/.test(def.engine) ? final(def) : def.rows;
    return rows.map(r => render(def, r, settings));
  }
  throw new Error(`fake: unsupported query: ${sql.slice(0, 200)}`);
}

http.createServer((req, res) => {
  if (req.url === '/ping') { res.end('Ok.\n'); return; }
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const auth = Buffer.from(String(req.headers.authorization || '').replace(/^Basic /, ''), 'base64').toString();
    if (auth.split(':').slice(1).join(':') !== PASSWORD) { res.statusCode = 516; res.end('Code: 516. DB::Exception: Authentication failed'); return; }
    const url = new URL(req.url, 'http://x');
    const sql = Buffer.concat(chunks).toString('utf8');
    if (NO_QUOTE_DECIMALS && url.searchParams.has('output_format_json_quote_decimals')) {
      res.statusCode = 400; res.end('Code: 115. DB::Exception: Unknown setting output_format_json_quote_decimals'); return;
    }
    try {
      const rows = answer(sql, url.searchParams);
      if (process.env.FAKE_CH_LOG) console.error(`[fake-ch] ${sql.replace(/\s+/g, ' ').slice(0, 120)} -> ${rows.length} rows`);
      res.setHeader('Content-Type', 'application/x-ndjson; charset=UTF-8');
      res.end(rows.map(r => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
    } catch (e) {
      res.statusCode = e.status || 400; res.end(e.message);
    }
  });
}).listen(PORT, '127.0.0.1', () => console.error(`[fake-ch] listening on 127.0.0.1:${PORT} tables=${Object.keys(tables).sort().join(',')}`));
