'use strict';

/**
 * db.js — PostgreSQL access layer for the procurement app (OLTP).
 *
 * Connection settings come from the standard libpq env vars
 * (PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD).
 *
 * Result values are shaped to match what the app returned when ClickHouse
 * (HTTP JSONEachRow) was the live database, so the frontend sees identical
 * JSON:
 *   bigint (int8)        → string   ("42")          — pg default, kept
 *   numeric              → number   (12.5)          — ClickHouse Decimal was a JSON number
 *   date                 → string   ("YYYY-MM-DD")  — no JS Date / timezone shift
 *   timestamptz/timestamp→ string   ("YYYY-MM-DD HH:MM:SS.mmm", Asia/Bangkok wall time)
 *   smallint/integer     → number   — pg default
 *   uuid                 → string   — pg default
 *
 * Usage:
 *   const db = require('./db');
 *   const rows = await db.query('SELECT * FROM items WHERE item_id = $1', [id]);
 *   await db.tx(async (c) => { await c.query(...); ... });   // BEGIN … COMMIT / ROLLBACK
 */

const { Pool, types: pgTypes } = require('pg');

const COMPANY_ID = 'PTMMI';
const APP_TZ_OFFSET_MIN = 7 * 60; // Asia/Bangkok is a fixed UTC+07:00 (no DST)

// ── Type parsers (per-pool, not global) ──────────────────────────────────────
const OID = { INT8: 20, NUMERIC: 1700, DATE: 1082, TIMESTAMP: 1114, TIMESTAMPTZ: 1184 };

function parseNumeric(v) {
  return v === null ? null : parseFloat(v);
}

const pad = (n, w = 2) => String(n).padStart(w, '0');

/**
 * Postgres text timestamp → "YYYY-MM-DD HH:MM:SS.mmm" in Bangkok wall time.
 * The session TimeZone is Asia/Bangkok, so timestamptz normally arrives as
 * "2026-10-01 10:57:29.12+07"; any other offset is converted to +07 first.
 * Fractions are truncated/padded to exactly 3 digits (DateTime64(3)).
 */
function parseTimestamp(v) {
  if (v === null) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(?:([+-])(\d{2})(?::?(\d{2}))?(?::?(\d{2}))?)?$/.exec(v);
  if (!m) return v; // infinity, BC dates, … — pass through untouched
  const frac = ((m[7] || '') + '000').slice(0, 3);
  if (m[8]) {
    const offMin = (m[8] === '-' ? -1 : 1) * (parseInt(m[9], 10) * 60 + parseInt(m[10] || '0', 10));
    if (offMin !== APP_TZ_OFFSET_MIN || m[11]) {
      const utcMs = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6])
        - offMin * 60000 - (m[8] === '-' ? -1 : 1) * parseInt(m[11] || '0', 10) * 1000;
      const d = new Date(utcMs + APP_TZ_OFFSET_MIN * 60000);
      return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ` +
             `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}.${frac}`;
    }
  }
  return `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}.${frac}`;
}

const TYPE_OVERRIDES = {
  [OID.NUMERIC]:     parseNumeric,
  [OID.DATE]:        v => v,          // raw "YYYY-MM-DD"
  [OID.TIMESTAMP]:   parseTimestamp,
  [OID.TIMESTAMPTZ]: parseTimestamp,
};

const types = {
  getTypeParser(oid, format) {
    if ((format === undefined || format === 'text') && TYPE_OVERRIDES[oid]) return TYPE_OVERRIDES[oid];
    return pgTypes.getTypeParser(oid, format);
  },
};

// ── Pool ─────────────────────────────────────────────────────────────────────
const pool = new Pool({
  max: parseInt(process.env.PGPOOL_MAX || '5', 10),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
  // Every pooled connection runs in Bangkok time with ISO date output, so
  // timestamptz text is "YYYY-MM-DD HH:MM:SS[.ffffff]+07".
  options: '-c TimeZone=Asia/Bangkok -c DateStyle=ISO,MDY',
  application_name: process.env.PGAPPNAME || 'procurement-app',
  types,
});

// An idle client erroring (e.g. server restart) must not crash the process.
pool.on('error', (err) => console.error('Postgres pool error:', err.message));

// ── Public API ───────────────────────────────────────────────────────────────

/** Run a statement and return its rows. `runner` may be a tx client. */
async function query(sql, params = [], runner = pool) {
  const res = await runner.query(sql, params);
  return res.rows;
}

/** First row or null. */
async function one(sql, params = [], runner = pool) {
  const rows = await query(sql, params, runner);
  return rows[0] || null;
}

/**
 * Run fn(client) inside BEGIN … COMMIT. Any throw rolls back and is re-thrown.
 * The client is always released; a client whose ROLLBACK failed is destroyed.
 */
async function tx(fn) {
  const client = await pool.connect();
  let broken = null;
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (e) {
    try { await client.query('ROLLBACK'); } catch (rbErr) { broken = rbErr; }
    throw e;
  } finally {
    client.release(broken || undefined);
  }
}

/**
 * Allocate the next number for a document counter. Must be called with a
 * transaction client so the increment commits/rolls back with the document.
 * The row lock taken by ON CONFLICT DO UPDATE serialises concurrent callers.
 */
async function nextDocNo(client, docType, year = 0) {
  const r = await client.query(
    `INSERT INTO doc_counters (doc_type, year, last_no) VALUES ($1, $2, 1)
     ON CONFLICT (doc_type, year) DO UPDATE SET last_no = doc_counters.last_no + 1
     RETURNING last_no`,
    [docType, year]
  );
  return r.rows[0].last_no;
}

/** Throws if Postgres is unreachable / credentials are wrong. */
async function ping() {
  await pool.query('SELECT 1');
  return true;
}

function close() { return pool.end(); }

module.exports = {
  pool,
  query,
  one,
  tx,
  nextDocNo,
  ping,
  close,
  COMPANY_ID,
  // exported for tests
  _parseTimestamp: parseTimestamp,
};
