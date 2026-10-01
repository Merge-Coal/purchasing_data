'use strict';

const path    = require('path');
const express = require('express');
const Fuse    = require('fuse.js');
const bcrypt  = require('bcryptjs');
const session = require('express-session');
const PgSession = require('connect-pg-simple')(session);
const db      = require('./db');

const PORT    = 3000;

// ── Additional-charge GL account codes (hardcoded — stored on each PO charge) ──
const CHARGE_ACCOUNTS = {
  freight:   { code: '5100', label: 'Freight / Shipping' },
  packing:   { code: '5110', label: 'Packing' },
  insurance: { code: '5120', label: 'Insurance' },
  handling:  { code: '5130', label: 'Handling' },
  other:     { code: '5190', label: 'Other Charges' },
};

// ── Fuse.js ───────────────────────────────────────────────────────────────────
let fuse;
async function rebuildFuse() {
  const items = await db.query('SELECT * FROM items WHERE is_deleted = 0 ORDER BY item_id COLLATE "C"');
  fuse = new Fuse(items, {
    threshold: 0.4,
    includeScore: true,
    keys: [
      { name: 'name_en', weight: 3 },
      { name: 'name_cn', weight: 3 },
      { name: 'spec',    weight: 2 },
      { name: 'item_id', weight: 1 },
    ],
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function today() { return new Date().toISOString().slice(0, 10); }

// Thrown inside a db.tx() callback: rolls the transaction back and answers
// with the given status and JSON body.
class HttpError extends Error {
  constructor(status, body) { super(body && body.error ? body.error : String(status)); this.status = status; this.body = body; }
}
function sendError(res, e) {
  if (e instanceof HttpError) return res.status(e.status).json(e.body);
  return res.status(500).json({ error: e.message });
}

// Canonical text form of a legacy (bigint) id as sent by the client: 5, "5"
// and "05" all name the same row, as they did with ClickHouse's Int64 params.
function legacyKey(v) {
  try { return BigInt(String(v).trim()).toString(); } catch { return String(v); }
}

// Document numbers come from doc_counters, allocated inside the transaction
// that inserts the document, so concurrent requests never share a number.
async function nextPrNumber(client) {
  const year = new Date().getFullYear();
  const n = await db.nextDocNo(client, 'PR', year);
  return `PR-${year}-${String(n).padStart(3, '0')}`;
}
async function nextPoNumber(client) {
  const year = new Date().getFullYear();
  const n = await db.nextDocNo(client, 'PO', year);
  return `PO-${year}-${String(n).padStart(3, '0')}`;
}
async function nextItemId(client) {
  const n = await db.nextDocNo(client, 'ITEM', 0);
  return `ITEM-${String(n).padStart(4, '0')}`;
}
async function nextVendorId(client) {
  const n = await db.nextDocNo(client, 'V', 0);
  return `V-${String(n).padStart(4, '0')}`;
}

// purchase_orders as ClickHouse returned it for SELECT * (minus `version`):
// primary_pr_id was a String column holding '' when the PO has no PR.
const PO_COLS = `po.po_id, po.legacy_po_id, po.company_id, po.po_number,
  COALESCE(po.primary_pr_id::text, '') AS primary_pr_id,
  po.vendor_id, po.vendor_name, po.po_date, po.expected_delivery_date, po.currency,
  po.exchange_rate, po.payment_term_id, po.status, po.subtotal_amount, po.discount_amount,
  po.tax_amount, po.withholding_amount, po.total_amount, po.notes, po.search_text,
  po.created_by_user_id, po.is_deleted, po.created_at, po.updated_at, po.charges_amount`;

// ── Express ───────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(session({
  store: new PgSession({ pool: db.pool, tableName: 'session', createTableIfMissing: false }),
  secret: (() => { if (!process.env.SESSION_SECRET) throw new Error('SESSION_SECRET env var is required'); return process.env.SESSION_SECRET; })(),
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 8 * 60 * 60 * 1000, sameSite: 'lax', httpOnly: true }
}));
app.use(express.static(path.join(__dirname, 'public')));

// ── Auth middleware ───────────────────────────────────────────────────────────
function requireAuth(req, res, next) {
  if (!req.session.user) return res.status(401).json({ error: 'Authentication required' });
  next();
}
function requireRole(...roles) {
  return (req, res, next) => {
    if (!req.session.user) return res.status(401).json({ error: 'Authentication required' });
    if (!roles.includes(req.session.user.role)) return res.status(403).json({ error: 'Access denied' });
    next();
  };
}

// ── Auth ──────────────────────────────────────────────────────────────────────
app.post('/api/auth/login', async (req, res) => {
  try {
    const { username, password } = req.body;
    if (!username || !password) return res.status(400).json({ error: 'username and password required' });
    const rows = await db.query(
      `SELECT * FROM users WHERE username = $1 AND is_deleted = 0 LIMIT 1`,
      [username]
    );
    const user = rows[0];
    if (!user || !bcrypt.compareSync(password, user.password_hash))
      return res.status(401).json({ error: 'Invalid username or password' });
    req.session.user = {
      id: user.legacy_user_id,
      username: user.username,
      role: user.role,
      full_name: user.full_name,
    };
    res.json({ success: true, user: req.session.user });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/auth/logout', (req, res) => {
  req.session.destroy(() => res.json({ success: true }));
});

app.get('/api/auth/me', (req, res) => {
  if (!req.session.user) return res.status(401).json({ error: 'Not logged in' });
  res.json({ user: req.session.user });
});

// ── Items ─────────────────────────────────────────────────────────────────────
app.get('/api/items', requireAuth, async (req, res) => {
  try {
    const rows = await db.query('SELECT *, department_id AS department FROM items WHERE is_deleted = 0 ORDER BY item_id COLLATE "C"');
    res.json(rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/items/search', requireAuth, (req, res) => {
  const q = (req.query.q || '').trim();
  if (!q || !fuse) return res.json([]);
  res.json(fuse.search(q).slice(0, 5).map(r => r.item));
});

app.post('/api/items/match', requireAuth, (req, res) => {
  try {
    const names = req.body.names;
    if (!Array.isArray(names)) return res.status(400).json({ error: 'names must be array' });
    if (!fuse) return res.json([]);
    const results = names.map(name => {
      const base = String(name).trim();
      // Also try with CJK stripped and CJK-only — picks best score for mixed-language names
      const enOnly = base.replace(/[\u3000-\u9FFF\uF900-\uFAFF\u4E00-\u9FFF]/g, '').trim();
      const cnOnly = base.replace(/[^\u4E00-\u9FFF\u3400-\u4DBF]/g, '').trim();
      const queries = [...new Set([base, enOnly, cnOnly].filter(Boolean))];
      const best = new Map(); // item_id → {item, score}
      for (const q of queries) {
        for (const h of fuse.search(q, { limit: 4 })) {
          const id = h.item.item_id;
          if (!best.has(id) || best.get(id).score > (h.score ?? 1)) {
            best.set(id, { item: h.item, score: h.score ?? 1 });
          }
        }
      }
      const matches = [...best.values()].sort((a, b) => a.score - b.score).slice(0, 4);
      return { query: name, matches };
    });
    res.json(results);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/items/departments', requireAuth, async (req, res) => {
  try {
    const rows = await db.query(
      `SELECT department_id FROM items WHERE is_deleted = 0 AND department_id != ''
       GROUP BY department_id ORDER BY department_id COLLATE "C"`
    );
    res.json(rows.map(r => r.department_id));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/items', requireRole('admin'), async (req, res) => {
  try {
    const { name_en, name_cn, category, uom, department, item_type, spec } = req.body;
    if (!name_en) return res.status(400).json({ error: 'name_en required' });
    const item_id = await db.tx(async (c) => {
      const item_id = await nextItemId(c);
      await c.query(
        `INSERT INTO items (item_id, company_id, base_item_id, item_code, name_en, name_cn, category_id,
           category_name, spec, uom, department_id, item_type, default_gl_account_id,
           min_order_qty, lead_time_days, status, search_text, is_deleted)
         VALUES ($1, $2, '', '', $3, $4, '', $5, $6, $7, $8, $9, '', 0, 0, 'active', $10, 0)`,
        [item_id, db.COMPANY_ID, name_en || '', name_cn || '',
         category || '', spec || '', uom || 'pcs',
         department || '', item_type || 'expense',
         `${name_en} ${name_cn || ''} ${category || ''}`.toLowerCase()]
      );
      return item_id;
    });
    await rebuildFuse();
    res.json({ item_id });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.put('/api/items/:id', requireRole('admin'), async (req, res) => {
  try {
    const { name_en, name_cn, category, spec, uom, item_type } = req.body;
    await db.tx(async (c) => {
      const cur = await db.one(
        `SELECT * FROM items WHERE item_id = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!cur) throw new HttpError(404, { error: 'Item not found' });
      if (!name_en) throw new HttpError(400, { error: 'name_en required' });
      await c.query(
        `UPDATE items SET name_en = $2, name_cn = $3, category_name = $4, spec = $5,
           uom = $6, item_type = $7, search_text = $8
         WHERE item_id = $1`,
        [cur.item_id, name_en || '', name_cn || '', category || '', spec || '',
         uom || cur.uom, item_type || cur.item_type,
         `${name_en} ${name_cn || ''} ${category || ''}`.toLowerCase()]
      );
    });
    await rebuildFuse();
    res.json({ ok: true });
  } catch (e) { sendError(res, e); }
});

app.delete('/api/items/:id', requireRole('admin'), async (req, res) => {
  try {
    const rows = await db.query(
      `UPDATE items SET is_deleted = 1 WHERE item_id = $1 AND is_deleted = 0 RETURNING item_id`,
      [req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'Item not found' });
    await rebuildFuse();
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── UOM & Vendors ─────────────────────────────────────────────────────────────
app.get('/api/uom', requireAuth, async (_req, res) => {
  try {
    const rows = await db.query(
      `SELECT uom FROM items WHERE is_deleted = 0 AND uom != '' GROUP BY uom ORDER BY uom COLLATE "C"`
    );
    res.json(rows.map(r => r.uom));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/purposes', requireAuth, async (_req, res) => {
  try {
    const rows = await db.query(
      `SELECT purpose_id, label FROM purposes WHERE is_deleted = 0 AND status = 'active' ORDER BY sort_order`
    );
    res.json(rows.map(r => r.label));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/vendors/search', requireAuth, async (req, res) => {
  try {
    const q = (req.query.q || '').trim();
    if (!q) return res.json([]);
    const rows = await db.query(
      `SELECT vendor_id, vendor_name AS name, category, contact_person AS contact, phone, email, city
       FROM vendors
       WHERE is_deleted = 0 AND (
         strpos(lower(vendor_name), lower($1)) > 0 OR
         strpos(lower(vendor_id), lower($1)) > 0
       )
       ORDER BY vendor_name COLLATE "C" LIMIT 10`,
      [q]
    );
    res.json(rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/vendors', requireRole('purchasing', 'admin'), async (req, res) => {
  try {
    const { vendor_name, category, contact_person, phone, mobile, email, address, city, npwp } = req.body;
    if (!vendor_name) return res.status(400).json({ error: 'vendor_name required' });
    const vendor_id = await db.tx(async (c) => {
      const vendor_id = await nextVendorId(c);
      await c.query(
        `INSERT INTO vendors (vendor_id, company_id, vendor_code, vendor_name, category, status,
           contact_person, phone, mobile, email, address, city, country, npwp, payment_term_id,
           default_currency, tax_profile, risk_rating, blocked_reason, search_text, is_deleted)
         VALUES ($1, $2, '', $3, $4, 'active', $5, $6, $7, $8, $9, $10, 'ID', $11, '', 'IDR', '', '', '', $12, 0)`,
        [vendor_id, db.COMPANY_ID, vendor_name, category || 'General',
         contact_person || '', phone || '', mobile || '', email || '', address || '', city || '',
         npwp || '', `${vendor_name} ${city || ''}`.toLowerCase()]
      );
      return vendor_id;
    });
    res.json({ vendor_id });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Purchase Requests ─────────────────────────────────────────────────────────
app.post('/api/pr', requireRole('requester', 'purchasing', 'admin'), async (req, res) => {
  try {
    const { requested_by, department: deptBody, notes, items } = req.body;
    const requester_id = req.session.user ? String(req.session.user.id) : '';
    if (!requested_by || !items?.length)
      return res.status(400).json({ error: 'requested_by and items required' });

    const department = deptBody || (items[0] && items[0].department) || '';

    // Header, every line and the PR number commit together or not at all.
    const { legacy_pr_id, pr_number } = await db.tx(async (c) => {
      const pr_number = await nextPrNumber(c);
      const hdr = await db.one(
        `INSERT INTO purchase_requests (company_id, pr_number, requester_user_id, requested_by_name,
           department_id, cost_center_id, pr_date, needed_by_date, priority, status,
           total_estimated_amount, currency, notes, search_text, is_deleted)
         VALUES ($1, $2, $3, $4, $5, '', $6, NULL, 'normal', 'pending', 0, 'IDR', $7, $8, 0)
         RETURNING pr_id, legacy_pr_id`,
        [db.COMPANY_ID, pr_number, requester_id, requested_by, department, today(),
         notes || '', `${pr_number} ${requested_by}`.toLowerCase()],
        c
      );
      for (let i = 0; i < items.length; i++) {
        const it = items[i];
        await c.query(
          `INSERT INTO purchase_request_items (company_id, pr_id, line_no, item_id, item_description,
             requested_qty, approved_qty, uom, estimated_unit_price, estimated_total_price,
             department_id, cost_center_id, gl_account_id, status, notes, is_deleted)
           VALUES ($1, $2, $3, $4, '', $5, 0, $6, $7, $8, $9, '', '', 'pending', $10, 0)`,
          [db.COMPANY_ID, hdr.pr_id, i + 1, it.item_id || '',
           parseFloat(it.qty) || 0, it.uom || 'pcs',
           parseFloat(it.est_unit_price) || 0,
           (parseFloat(it.est_unit_price) || 0) * (parseFloat(it.qty) || 0),
           department || it.department || '', it.notes || '']
        );
      }
      return { legacy_pr_id: hdr.legacy_pr_id, pr_number };
    });
    // ClickHouse-era code answered with a JS number here, not the Int64 string.
    res.json({ pr_id: Number(legacy_pr_id), pr_number });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/pr', requireAuth, async (req, res) => {
  try {
    const requester_id = req.query.requester_id;
    const search = (req.query.search || '').trim();
    let sql = `
      SELECT
        pr.legacy_pr_id AS pr_id,
        pr.pr_id AS uuid,
        pr.pr_number, pr.requested_by_name AS requested_by,
        pr.department_id AS department, pr.pr_date AS date_requested,
        pr.status AS status, pr.notes AS notes, pr.requester_user_id AS requester_id,
        count(pri.pr_item_id) AS item_count,
        count(*) FILTER (WHERE pri.status = 'approved') AS approved_count,
        count(*) FILTER (WHERE pri.status = 'approved' AND COALESCE(poi_agg.total_ordered, 0) >= pri.approved_qty) AS fulfilled_count
      FROM purchase_requests AS pr
      LEFT JOIN purchase_request_items AS pri
        ON pri.pr_id = pr.pr_id AND pri.is_deleted = 0
      LEFT JOIN (
        SELECT pr_item_id, sum(ordered_qty) AS total_ordered
        FROM purchase_order_items WHERE is_deleted = 0
        GROUP BY pr_item_id
      ) AS poi_agg ON poi_agg.pr_item_id = pri.pr_item_id
      WHERE pr.is_deleted = 0`;
    const params = [];
    if (requester_id) {
      params.push(String(requester_id));
      sql += ` AND pr.requester_user_id = $${params.length}`;
    }
    if (search) {
      params.push(search);
      sql += ` AND (strpos(lower(pr.pr_number), lower($${params.length})) > 0 OR strpos(lower(pr.requested_by_name), lower($${params.length})) > 0)`;
    }
    sql += ` GROUP BY pr.legacy_pr_id, pr.pr_id, pr.pr_number, pr.requested_by_name,
             pr.department_id, pr.pr_date, pr.status, pr.notes, pr.requester_user_id
             ORDER BY pr.legacy_pr_id DESC`;

    const rows = await db.query(sql, params);
    res.json(rows.map(r => {
      const approved = parseInt(r.approved_count) || 0;
      const fulfilled = parseInt(r.fulfilled_count) || 0;
      const item_count = parseInt(r.item_count) || 0;
      let fulfillment_status = null;
      if (r.status === 'approved') {
        if (approved === 0)             fulfillment_status = 'unfulfilled';
        else if (fulfilled >= approved) fulfillment_status = 'fulfilled';
        else if (fulfilled > 0)         fulfillment_status = 'partial';
        else                            fulfillment_status = 'unfulfilled';
      }
      return { ...r, item_count, approved_count: approved, fulfilled_count: fulfilled,
               approval_summary: `${approved}/${item_count} approved`, fulfillment_status };
    }));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/pr/:id', requireAuth, async (req, res) => {
  try {
    const prs = await db.query(
      `SELECT * FROM purchase_requests WHERE legacy_pr_id = $1 AND is_deleted = 0 LIMIT 1`,
      [req.params.id]
    );
    if (!prs.length) return res.status(404).json({ error: 'Not found' });
    const pr = prs[0];

    const rawItems = await db.query(
      `SELECT
         pri.pr_item_id, pri.legacy_pr_item_id, pri.pr_id, pri.line_no,
         pri.item_id, pri.requested_qty, pri.approved_qty,
         pri.uom AS uom, pri.estimated_unit_price, pri.estimated_total_price,
         pri.department_id, pri.status AS status, pri.notes AS notes,
         i.name_en, i.name_cn, i.spec, i.category_name AS category,
         COALESCE(poi_agg.total_ordered, 0) AS qty_fulfilled
       FROM purchase_request_items pri
       JOIN items i ON i.item_id = pri.item_id AND i.is_deleted = 0
       LEFT JOIN (
         SELECT pr_item_id, sum(ordered_qty) AS total_ordered
         FROM purchase_order_items WHERE is_deleted = 0
         GROUP BY pr_item_id
       ) poi_agg ON poi_agg.pr_item_id = pri.pr_item_id
       WHERE pri.pr_id = $1 AND pri.is_deleted = 0
       ORDER BY pri.line_no, pri.legacy_pr_item_id`,
      [pr.pr_id]
    );

    const lineItems = rawItems.map(item => {
      const qtyFulfilled = parseFloat(item.qty_fulfilled) || 0;
      const qtyApproved  = parseFloat(item.approved_qty) || parseFloat(item.requested_qty) || 0;
      let fulfillment_status;
      if      (qtyFulfilled === 0)          fulfillment_status = 'unfulfilled';
      else if (qtyFulfilled >= qtyApproved) fulfillment_status = 'fulfilled';
      else                                  fulfillment_status = 'partial';
      return {
        ...item,
        pr_item_id:    item.legacy_pr_item_id,
        qty:           parseFloat(item.requested_qty) || 0,
        qty_requested: parseFloat(item.requested_qty) || 0,
        qty_approved:  parseFloat(item.approved_qty)  || 0,
        est_unit_price: item.estimated_unit_price,
        fulfillment_status,
      };
    });

    const history = await db.query(
      `SELECT *, actor_name AS approved_by, action_at AS timestamp FROM approval_actions
       WHERE document_id = $1 AND document_type = 'PR' ORDER BY action_at`,
      [pr.pr_id]
    );

    const estimated_total = lineItems.reduce((s, i) =>
      s + (parseFloat(i.estimated_unit_price) || 0) * (parseFloat(i.requested_qty) || 0), 0);

    res.json({
      ...pr,
      pr_id:         pr.legacy_pr_id,
      requested_by:  pr.requested_by_name,
      department:    pr.department_id,
      date_requested: pr.pr_date,
      requester_id:  pr.requester_user_id,
      line_items:    lineItems,
      history,
      estimated_total,
    });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/pr/:id/approve', requireRole('md', 'admin'), async (req, res) => {
  try {
    const { approved_by, action, notes } = req.body;
    if (!approved_by || !action) return res.status(400).json({ error: 'approved_by and action required' });
    if (!['approved', 'rejected'].includes(action)) return res.status(400).json({ error: 'action must be approved or rejected' });

    await db.tx(async (c) => {
      const pr = await db.one(
        `SELECT pr_id, status FROM purchase_requests WHERE legacy_pr_id = $1 AND is_deleted = 0 LIMIT 1 FOR NO KEY UPDATE`,
        [req.params.id], c
      );
      if (!pr) throw new HttpError(404, { error: 'Not found' });
      await c.query(`UPDATE purchase_requests SET status = $2 WHERE pr_id = $1`, [pr.pr_id, action]);
      await c.query(
        `INSERT INTO approval_actions (company_id, document_type, document_id, document_item_id,
           workflow_id, step_no, actor_user_id, actor_name, action, action_at, from_status, to_status,
           approved_qty, notes)
         VALUES ($1, 'PR', $2, '', '', 0, '', $3, $4, clock_timestamp(), $5, $4, NULL, $6)`,
        [db.COMPANY_ID, pr.pr_id, approved_by, action, pr.status, notes || '']
      );
    });
    res.json({ success: true, status: action });
  } catch (e) { sendError(res, e); }
});

app.post('/api/pr/:id/items/:itemId/approve', requireRole('md', 'admin'), async (req, res) => {
  try {
    const { action, qty_approved, notes } = req.body;
    const approved_by = req.session.user.full_name || req.session.user.username;
    if (!action) return res.status(400).json({ error: 'action required' });
    if (!['approved', 'rejected'].includes(action)) return res.status(400).json({ error: 'action must be approved or rejected' });

    const approvedQty = await db.tx(async (c) => {
      // FOR NO KEY UPDATE (not FOR UPDATE) on PR rows: a concurrent PO insert takes FOR KEY SHARE
      // on the PR row via its FK while holding PR-item locks; FOR UPDATE here deadlocks against it.
      // Lock the PR first: concurrent item approvals on the same PR serialise
      // here, so the last one always sees every other decision and flips the
      // PR status.
      const pr = await db.one(
        `SELECT pr_id FROM purchase_requests WHERE legacy_pr_id = $1 AND is_deleted = 0 LIMIT 1 FOR NO KEY UPDATE`,
        [req.params.id], c
      );
      if (!pr) throw new HttpError(404, { error: 'PR not found' });

      const prItem = await db.one(
        `SELECT * FROM purchase_request_items
         WHERE legacy_pr_item_id = $1 AND pr_id = $2 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.itemId, pr.pr_id], c
      );
      if (!prItem) throw new HttpError(404, { error: 'PR item not found' });

      const approvedQty = action === 'approved'
        ? (qty_approved ?? parseFloat(prItem.requested_qty))
        : 0;
      if (action === 'approved' && (isNaN(approvedQty) || approvedQty <= 0)) {
        throw new HttpError(400, { error: 'Approved quantity must be greater than 0 / 批准数量必须大于0' });
      }

      await c.query(
        `UPDATE purchase_request_items SET status = $2, approved_qty = $3 WHERE pr_item_id = $1`,
        [prItem.pr_item_id, action, approvedQty]
      );

      const itemRow = await db.one(
        `SELECT name_en FROM items WHERE item_id = $1 LIMIT 1`, [prItem.item_id], c
      );
      const itemName = itemRow?.name_en || prItem.item_id;

      await c.query(
        `INSERT INTO approval_actions (company_id, document_type, document_id, document_item_id,
           workflow_id, step_no, actor_user_id, actor_name, action, action_at, from_status, to_status,
           approved_qty, notes)
         VALUES ($1, 'PR', $2, $3, '', 0, '', $4, $5, clock_timestamp(), $6, $5, $7, $8)`,
        [db.COMPANY_ID, pr.pr_id, prItem.pr_item_id, approved_by, action, prItem.status,
         approvedQty, `Item: ${itemName}${notes ? ' — ' + notes : ''}`]
      );

      // Auto-update PR status
      const allItems = await db.query(
        `SELECT status FROM purchase_request_items WHERE pr_id = $1 AND is_deleted = 0`,
        [pr.pr_id], c
      );
      const anyPending  = allItems.some(i => !i.status || i.status === 'pending');
      const allRejected = allItems.every(i => i.status === 'rejected');
      if (!anyPending) {
        const newStatus = allRejected ? 'rejected' : 'approved';
        await c.query(`UPDATE purchase_requests SET status = $2 WHERE pr_id = $1`, [pr.pr_id, newStatus]);
      }
      return approvedQty;
    });

    res.json({ success: true, status: action, qty_approved: approvedQty });
  } catch (e) { sendError(res, e); }
});

// ── Approved items for PO creation ────────────────────────────────────────────
app.get('/api/pr-items/approved', requireRole('purchasing', 'admin'), async (req, res) => {
  try {
    const rows = await db.query(`
      SELECT
        pri.legacy_pr_item_id AS pr_item_id,
        pr.legacy_pr_id AS pr_id,
        pri.item_id,
        pri.approved_qty AS qty_approved,
        pri.requested_qty AS qty_requested,
        pri.uom AS uom,
        pri.estimated_unit_price,
        pri.estimated_unit_price AS est_unit_price,
        i.name_en, i.name_cn, i.spec, i.category_name AS category,
        pr.pr_number, pr.requested_by_name AS requested_by, pr.pr_date AS date_requested,
        COALESCE(pri.department_id, pr.department_id) AS department,
        COALESCE(poi_agg.total_ordered, 0) AS qty_fulfilled
      FROM purchase_request_items pri
      JOIN items i ON i.item_id = pri.item_id AND i.is_deleted = 0
      JOIN purchase_requests pr ON pr.pr_id = pri.pr_id AND pr.is_deleted = 0
      LEFT JOIN (
        SELECT pr_item_id, sum(ordered_qty) AS total_ordered
        FROM purchase_order_items WHERE is_deleted = 0
        GROUP BY pr_item_id
      ) poi_agg ON poi_agg.pr_item_id = pri.pr_item_id
      WHERE pri.status = 'approved' AND pri.is_deleted = 0
      ORDER BY pr.legacy_pr_id DESC, pri.legacy_pr_item_id
    `);
    const result = rows.filter(r => {
      const approved = parseFloat(r.qty_approved) || parseFloat(r.qty_requested) || 0;
      return parseFloat(r.qty_fulfilled) < approved;
    });
    res.json(result);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Purchase Orders ───────────────────────────────────────────────────────────
app.post('/api/po', requireRole('purchasing', 'admin'), async (req, res) => {
  try {
    const PPH_RATES = { pph23: 0.02, pph15: 0.012, pph22_solar: 0.003, pph22_impor: 0.025 };
    const { vendor_name, items, include_vat = false, discount_pct = 0, pph_type = null, charges = [] } = req.body;
    if (!vendor_name || !items?.length)
      return res.status(400).json({ error: 'vendor_name and items array required' });
    if (pph_type && !PPH_RATES[pph_type])
      return res.status(400).json({ error: `Unknown pph_type: ${pph_type}` });
    if (!Array.isArray(charges))
      return res.status(400).json({ error: 'charges must be an array' });
    for (const c of charges) {
      if (!CHARGE_ACCOUNTS[c.charge_type])
        return res.status(400).json({ error: `Unknown charge_type: ${c.charge_type}` });
      const amt = Number(c.amount);
      if (!Number.isFinite(amt) || amt < 0)
        return res.status(400).json({ error: 'Each charge needs a non-negative amount' });
    }

    // Validation reads, the PR-item row locks, the PO number, header, lines and
    // charges all happen in one transaction.
    const { legacy_po_id, po_number } = await db.tx(async (c) => {
      // Per-item checks in request order, so the first failing item produces
      // the same error message as before.
      const checkItems = async () => {
        for (const it of items) {
          if (!it.pr_item_id || it.unit_price == null || it.qty_ordered == null)
            throw new HttpError(400, { error: 'Each item needs pr_item_id, unit_price, qty_ordered' });
          const r = await db.query(
            `SELECT status FROM purchase_request_items WHERE legacy_pr_item_id = $1 AND is_deleted = 0 LIMIT 1`,
            [it.pr_item_id], c
          );
          if (!r.length) throw new HttpError(400, { error: `pr_item_id ${it.pr_item_id} not found` });
          if (r[0].status !== 'approved') throw new HttpError(400, { error: `Item ${it.pr_item_id} is not approved` });
        }
      };
      await checkItems();

      // Lock the referenced PR item rows (in id order, so two POs sharing
      // items cannot deadlock), then re-check under the lock: a concurrent
      // rejection/deletion that committed meanwhile is now visible.
      const ids = [...new Set(items.map(it => legacyKey(it.pr_item_id)))];
      const locked = await db.query(
        `SELECT * FROM purchase_request_items
         WHERE legacy_pr_item_id = ANY($1::bigint[]) AND is_deleted = 0
         ORDER BY legacy_pr_item_id FOR UPDATE`,
        [ids], c
      );
      await checkItems();
      const prItemByLegacy = new Map(locked.map(r => [String(r.legacy_pr_item_id), r]));

      const subtotal        = items.reduce((s, it) => s + it.unit_price * it.qty_ordered, 0);
      const discount_amount = subtotal * (Math.min(Math.max(parseFloat(discount_pct) || 0, 0), 100) / 100);
      const discounted      = subtotal - discount_amount;
      const charges_total   = charges.reduce((s, c) => s + Number(c.amount), 0);
      const vat_base        = discounted + charges_total;
      const vat_amount      = include_vat ? vat_base * 0.11 : 0;
      const pph_rate        = pph_type ? PPH_RATES[pph_type] : 0;
      const pph_amount      = discounted * pph_rate;
      const total_amount    = discounted + charges_total + vat_amount - pph_amount;

      const po_number = await nextPoNumber(c);
      const primary_pr_id = prItemByLegacy.get(legacyKey(items[0].pr_item_id))?.pr_id || null;

      const hdr = await db.one(
        `INSERT INTO purchase_orders (company_id, po_number, primary_pr_id, vendor_id, vendor_name,
           po_date, expected_delivery_date, currency, exchange_rate, payment_term_id, status,
           subtotal_amount, discount_amount, charges_amount, tax_amount, withholding_amount,
           total_amount, notes, search_text, created_by_user_id, is_deleted)
         VALUES ($1, $2, $3, '', $4, $5, NULL, 'IDR', 1, '', 'pending_approval',
           $6, $7, $8, $9, $10, $11, '', $12, $13, 0)
         RETURNING po_id, legacy_po_id`,
        [db.COMPANY_ID, po_number, primary_pr_id, vendor_name, today(),
         subtotal, discount_amount, charges_total, vat_amount, pph_amount, total_amount,
         `${po_number} ${vendor_name}`.toLowerCase(),
         req.session.user ? String(req.session.user.id) : ''],
        c
      );

      for (let i = 0; i < items.length; i++) {
        const it = items[i];
        const prItem = prItemByLegacy.get(legacyKey(it.pr_item_id));
        await c.query(
          `INSERT INTO purchase_order_items (company_id, po_id, line_no, pr_item_id, quotation_item_id,
             item_id, item_description, ordered_qty, received_qty, invoiced_qty, uom, unit_price,
             discount_amount, tax_amount, total_price, gl_account_id, cost_center_id, vendor_name,
             status, notes, purpose, is_deleted)
           VALUES ($1, $2, $3, $4, '', $5, '', $6, 0, 0, $7, $8, 0, 0, $9, '', '', $10, 'open', '', $11, 0)`,
          [db.COMPANY_ID, hdr.po_id, i + 1, prItem.pr_item_id, prItem.item_id,
           parseFloat(it.qty_ordered), prItem.uom, parseFloat(it.unit_price),
           parseFloat(it.unit_price) * parseFloat(it.qty_ordered),
           vendor_name, String(it.purpose || '')]
        );
      }

      for (let i = 0; i < charges.length; i++) {
        const chg = charges[i];
        await c.query(
          `INSERT INTO purchase_order_charges (company_id, po_id, line_no, charge_type, description,
             amount, gl_account_code, is_taxable, is_deleted)
           VALUES ($1, $2, $3, $4, $5, $6, $7, 1, 0)`,
          [db.COMPANY_ID, hdr.po_id, i + 1, chg.charge_type,
           (chg.description || '').toString().slice(0, 500), Number(chg.amount),
           CHARGE_ACCOUNTS[chg.charge_type].code]
        );
      }
      return { legacy_po_id: hdr.legacy_po_id, po_number };
    });

    // ClickHouse-era code answered with a JS number here, not the Int64 string.
    res.json({ po_id: Number(legacy_po_id), po_number });
  } catch (e) { sendError(res, e); }
});

// ── PO Approval routes ────────────────────────────────────────────────────────
app.post('/api/po/:id/approve', requireRole('md', 'admin'), async (req, res) => {
  try {
    await db.tx(async (c) => {
      const po = await db.one(
        `SELECT po_id, status FROM purchase_orders WHERE legacy_po_id = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!po) throw new HttpError(404, { error: 'PO not found' });
      if (po.status !== 'pending_approval')
        throw new HttpError(400, { error: `Cannot approve a PO with status: ${po.status}` });
      await c.query(`UPDATE purchase_orders SET status = 'approved' WHERE po_id = $1`, [po.po_id]);
      await c.query(
        `INSERT INTO approval_actions (company_id, document_type, document_id, document_item_id,
           workflow_id, step_no, actor_user_id, actor_name, action, action_at, from_status, to_status,
           approved_qty, notes)
         VALUES ($1, 'PO', $2, '', '', 0, '', $3, 'approved', clock_timestamp(), $4, 'approved', NULL, '')`,
        [db.COMPANY_ID, po.po_id, req.session.user?.full_name || req.session.user?.username || '', po.status]
      );
    });
    res.json({ success: true });
  } catch (e) { sendError(res, e); }
});

app.post('/api/po/:id/reject', requireRole('md', 'admin'), async (req, res) => {
  try {
    const { notes } = req.body;
    if (!notes?.trim()) return res.status(400).json({ error: 'Rejection note is required' });
    await db.tx(async (c) => {
      const po = await db.one(
        `SELECT po_id, status FROM purchase_orders WHERE legacy_po_id = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!po) throw new HttpError(404, { error: 'PO not found' });
      if (po.status !== 'pending_approval')
        throw new HttpError(400, { error: `Cannot reject a PO with status: ${po.status}` });
      await c.query(`UPDATE purchase_orders SET status = 'rejected', notes = $2 WHERE po_id = $1`, [po.po_id, notes.trim()]);
      await c.query(
        `INSERT INTO approval_actions (company_id, document_type, document_id, document_item_id,
           workflow_id, step_no, actor_user_id, actor_name, action, action_at, from_status, to_status,
           approved_qty, notes)
         VALUES ($1, 'PO', $2, '', '', 0, '', $3, 'rejected', clock_timestamp(), $4, 'rejected', NULL, $5)`,
        [db.COMPANY_ID, po.po_id, req.session.user?.full_name || req.session.user?.username || '', po.status, notes.trim()]
      );
    });
    res.json({ success: true });
  } catch (e) { sendError(res, e); }
});

app.post('/api/po/:id/resubmit', requireRole('purchasing', 'admin'), async (req, res) => {
  try {
    await db.tx(async (c) => {
      const po = await db.one(
        `SELECT po_id, status FROM purchase_orders WHERE legacy_po_id = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!po) throw new HttpError(404, { error: 'PO not found' });
      if (po.status !== 'rejected')
        throw new HttpError(400, { error: `Can only resubmit rejected POs` });
      await c.query(`UPDATE purchase_orders SET status = 'pending_approval', notes = '' WHERE po_id = $1`, [po.po_id]);
    });
    res.json({ success: true });
  } catch (e) { sendError(res, e); }
});

app.get('/api/po', requireAuth, async (req, res) => {
  try {
    const search = (req.query.search || '').trim();
    let sql = `
      SELECT
        po.legacy_po_id AS po_id, po.po_id AS uuid,
        po.po_number, po.vendor_name, po.po_date AS date_created,
        po.status AS status, po.total_amount AS total_amount, po.subtotal_amount AS subtotal_amount,
        po.tax_amount AS tax_amount, po.withholding_amount AS withholding_amount,
        array_agg(DISTINCT COALESCE(pr.pr_number, '')) AS pr_numbers_arr
      FROM purchase_orders po
      LEFT JOIN purchase_order_items poi ON poi.po_id = po.po_id AND poi.is_deleted = 0
      LEFT JOIN purchase_request_items pri ON pri.pr_item_id = poi.pr_item_id AND pri.is_deleted = 0
      LEFT JOIN purchase_requests pr ON pr.pr_id = pri.pr_id AND pr.is_deleted = 0
      WHERE po.is_deleted = 0`;
    const params = [];
    if (search) {
      params.push(search);
      sql += ` AND (strpos(lower(po.po_number), lower($1)) > 0 OR strpos(lower(po.vendor_name), lower($1)) > 0)`;
    }
    sql += ` GROUP BY po.legacy_po_id, po.po_id, po.po_number, po.vendor_name, po.po_date,
             po.status, po.total_amount, po.subtotal_amount, po.tax_amount, po.withholding_amount
             ORDER BY po.legacy_po_id DESC`;

    const rows = await db.query(sql, params);
    res.json(rows.map(r => ({
      ...r,
      pr_numbers: Array.isArray(r.pr_numbers_arr) ? r.pr_numbers_arr.filter(Boolean).join(',') : '',
    })));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/po/:id', requireAuth, async (req, res) => {
  try {
    const pos = await db.query(
      `SELECT ${PO_COLS} FROM purchase_orders po WHERE po.legacy_po_id = $1 AND po.is_deleted = 0 LIMIT 1`,
      [req.params.id]
    );
    if (!pos.length) return res.status(404).json({ error: 'Not found' });
    const po = pos[0];

    const lineItems = await db.query(
      `SELECT
         poi.po_item_id, poi.legacy_po_item_id, poi.po_id, poi.line_no,
         poi.item_id, COALESCE(poi.pr_item_id::text, '') AS pr_item_id, poi.ordered_qty, poi.received_qty,
         poi.uom AS uom, poi.unit_price, poi.total_price,
         poi.status AS status, poi.notes AS notes, poi.purpose AS purpose,
         i.name_en, i.name_cn, COALESCE(pr.pr_number, '') AS pr_number
       FROM purchase_order_items poi
       JOIN items i ON i.item_id = poi.item_id AND i.is_deleted = 0
       LEFT JOIN purchase_request_items pri ON pri.pr_item_id = poi.pr_item_id AND pri.is_deleted = 0
       LEFT JOIN purchase_requests pr ON pr.pr_id = pri.pr_id AND pr.is_deleted = 0
       WHERE poi.po_id = $1 AND poi.is_deleted = 0
       ORDER BY poi.line_no, poi.legacy_po_item_id`,
      [po.po_id]
    );

    const prNums = [...new Set(lineItems.map(l => l.pr_number).filter(Boolean))].join(',');

    const charges = await db.query(
      `SELECT line_no, charge_type, description, amount, gl_account_code, is_taxable
       FROM purchase_order_charges
       WHERE po_id = $1 AND is_deleted = 0
       ORDER BY line_no`,
      [po.po_id]
    );

    res.json({
      ...po,
      po_id:       po.legacy_po_id,
      date_created: po.po_date,
      include_vat: parseFloat(po.tax_amount) > 0 ? 1 : 0,
      pr_numbers:  prNums,
      charges,
      line_items:  lineItems.map(l => ({
        ...l, po_item_id: l.legacy_po_item_id, qty: l.ordered_qty,
      })),
    });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/po/:id/print', requireAuth, async (req, res) => {
  try {
    const pos = await db.query(
      `SELECT ${PO_COLS} FROM purchase_orders po WHERE po.legacy_po_id = $1 AND po.is_deleted = 0 LIMIT 1`,
      [req.params.id]
    );
    if (!pos.length) return res.status(404).send('Not found');
    const po = pos[0];

    const lineItems = await db.query(
      `SELECT
         poi.po_item_id, poi.legacy_po_item_id, poi.po_id, poi.line_no,
         poi.item_id, COALESCE(poi.pr_item_id::text, '') AS pr_item_id, poi.ordered_qty, poi.received_qty,
         poi.uom AS uom, poi.unit_price, poi.total_price,
         poi.status AS status, poi.notes AS notes, poi.purpose AS purpose,
         i.name_en, i.name_cn, i.spec, COALESCE(pr.pr_number, '') AS pr_number,
         COALESCE(pr.department_id, '') AS pr_department
       FROM purchase_order_items poi
       JOIN items i ON i.item_id = poi.item_id AND i.is_deleted = 0
       LEFT JOIN purchase_request_items pri ON pri.pr_item_id = poi.pr_item_id AND pri.is_deleted = 0
       LEFT JOIN purchase_requests pr ON pr.pr_id = pri.pr_id AND pr.is_deleted = 0
       WHERE poi.po_id = $1 AND poi.is_deleted = 0
       ORDER BY poi.line_no, poi.legacy_po_item_id`,
      [po.po_id]
    );

    const charges = await db.query(
      `SELECT line_no, charge_type, description, amount, is_taxable
       FROM purchase_order_charges
       WHERE po_id = $1 AND is_deleted = 0
       ORDER BY line_no`,
      [po.po_id]
    );

    const esc = s => String(s ?? '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

    const UOM_CN_PRINT = {
      Bag:'袋',Bar:'根',Barrel:'桶',Bottle:'瓶',Box:'箱',Bundle:'捆',Carton:'纸箱',
      Coil:'卷',Cylinder:'气瓶',Item:'件',Kg:'千克',Litre:'升',M:'米',Pack:'包',
      Pair:'副',Pcs:'个',pcs:'个',Rod:'棒',Roll:'卷',Set:'套',Sheet:'张',
      Ton:'吨',Tube:'支',Unit:'台',
    };
    const PPH_LABELS = {
      pph23: 'PPH 23 Jasa Badan (2%)', pph15: 'PPH 15 Jasa Tongkang (1,2%)',
      pph22_solar: 'PPH 22 Solar (0,3%)', pph22_impor: 'PPH 22 Impor (2,5%)',
    };
    const subtotal   = lineItems.reduce((s, i) => s + parseFloat(i.total_price), 0);
    const chargesTotal = charges.reduce((s, c) => s + Number(c.amount), 0);
    const discountAmount = parseFloat(po.discount_amount) || 0;
    const vatAmount  = parseFloat(po.tax_amount) || 0;
    const pphAmount  = parseFloat(po.withholding_amount) || 0;
    const pphLabel   = PPH_LABELS[po.pph_type] || 'PPH';
    const grandTotal = subtotal - discountAmount + chargesTotal + vatAmount - pphAmount;
    const fmt = n => 'Rp ' + Math.round(n).toLocaleString('id-ID');

    const BLUE = '#1565C0';

    const itemRows = lineItems.map(it => {
      const uomCN = UOM_CN_PRINT[it.uom];
      const uomDisplay = uomCN ? `${it.uom} / ${uomCN}` : it.uom;
      const specLine    = it.spec    ? `<br><span class="spec">${esc(it.spec)}</span>`       : '';
      const purposeLine = it.purpose ? `<br><span class="purpose">${esc(it.purpose)}</span>` : '';
      return `
      <tr>
        <td>${esc(it.item_id)}</td>
        <td>${esc(it.name_en)}${it.name_cn ? '<br><span class="cn">' + esc(it.name_cn) + '</span>' : ''}${specLine}${purposeLine}</td>
        <td class="num">${parseFloat(it.ordered_qty).toLocaleString('id-ID')} ${esc(uomDisplay)}</td>
        <td class="num">${fmt(it.unit_price)}</td>
        <td class="num">0</td>
        <td class="num">${fmt(it.total_price)}</td>
      </tr>`;
    }).join('');

    const html = `<!DOCTYPE html>
<html lang="id"><head><meta charset="UTF-8"><title>PO ${po.po_number}</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: Arial, sans-serif; font-size: 11pt; color: #111; background:#fff; padding:20mm 16mm; }
  .header { display:flex; justify-content:space-between; align-items:flex-start; margin-bottom:12px; }
  .company-name { font-size:22pt; font-weight:700; }
  .company-addr { font-size:8.5pt; color:#444; line-height:1.5; margin-top:4px; max-width:320px; }
  .logo-block { display:flex; align-items:center; gap:10px; }
  .logo-img { height:64px; width:auto; object-fit:contain; }
  .divider { border:none; border-top:2.5px solid ${BLUE}; margin:10px 0; }
  .two-col { display:flex; justify-content:space-between; gap:20px; margin-bottom:14px; }
  .to-box .label { font-size:9pt; color:#666; margin-bottom:4px; }
  .to-box .vendor { font-weight:600; font-size:11pt; margin-bottom:3px; }
  .po-box { border:1.5px solid ${BLUE}; padding:10px 14px; min-width:240px; }
  .po-box .title { font-size:18pt; font-weight:700; margin-bottom:8px; color:${BLUE}; }
  .po-meta { display:grid; grid-template-columns:auto 1fr; gap:3px 8px; font-size:9.5pt; }
  .po-meta .key { color:#555; } .po-meta .val { font-weight:600; }
  table.items { width:100%; border-collapse:collapse; margin-bottom:16px; font-size:9.5pt; }
  table.items thead tr { background:${BLUE}; color:#fff; }
  table.items th { padding:6px 8px; text-align:left; font-weight:600; }
  table.items th.num, table.items td.num { text-align:right; }
  table.items tbody tr:nth-child(even) { background:#EBF2FF; }
  table.items td { padding:5px 8px; border-bottom:1px solid #ddd; vertical-align:top; }
  .cn { font-size:8.5pt; color:#666; }
  .spec { font-size:8pt; color:#888; font-style:italic; }
  .purpose { font-size:8.5pt; color:#1565C0; font-style:italic; }
  .bottom { display:flex; gap:24px; justify-content:flex-end; }
  .notes-box { flex:1; font-size:9pt; color:#444; border-top:1px solid #ccc; padding-top:8px; }
  .notes-box .label { font-weight:700; font-size:9pt; color:#111; margin-bottom:4px; }
  .totals { min-width:280px; border-top:1px solid #ccc; padding-top:8px; }
  .total-row { display:flex; justify-content:space-between; font-size:9.5pt; padding:3px 0; }
  .total-row.grand { font-weight:700; font-size:11pt; background:${BLUE}; color:#fff; padding:6px 8px; margin-top:4px; }
  .sigs { display:flex; justify-content:flex-end; gap:60px; margin-top:40px; }
  .sig-block { text-align:center; min-width:140px; }
  .sig-block .sig-label { font-size:9pt; margin-bottom:36px; }
  .sig-block .sig-line { border-top:1.5px solid #111; padding-top:4px; font-size:9pt; font-weight:600; }
  .print-btn { position:fixed; bottom:20px; right:20px; padding:10px 20px; background:${BLUE}; color:#fff; border:none; border-radius:6px; font-size:11pt; cursor:pointer; z-index:999; }
  @media print { .print-btn { display:none; } body { padding:0; } @page { margin:14mm 12mm; size:A4 portrait; } }
</style></head><body>
<button class="print-btn" onclick="window.print()">⬇ Simpan / Print PDF</button>
<div class="header"><div class="logo-block">
  <img class="logo-img" src="data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wgARCAHbAg0DASIAAhEBAxEB/8QAGgABAAMBAQEAAAAAAAAAAAAAAAQFBgMBAv/EABgBAQEBAQEAAAAAAAAAAAAAAAADAgEE/9oADAMBAAIQAxAAAAK9AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPD1xOdnEdnEdg6AAAfHw52cR2cR2cuoDoAAAAAAAAAAAAAAAAAAACrnUtJhWQAFpMo7uNvRjYDz2D3kHmeiAOAe3dHLxu1EbAAAAAAAAAAAAAAAAAAACO5AjHogHeAALKt+udvnz9ef0AeUc2vrIKTAAAuu1RbwuGdAAAAAAAAAAAAAAAAAAKafU0kFZgD6PlN8zqGmD7sa2ylV8fdbzsLw9HnAAAAXFP3zq5ELgAAAAAAAAAAAAAAAACG5A5HpgDgCyg3c6eiVQAOdJKiWiG8AD7PgAAFtKpLuFgzsAAAAAAAAAAAAAAADykm11ZBSYA7Ozph5rg6A49qjWYwvAAD26g2ca0fO1qqYDWQFnWfedXrz2FwAAAAAAAAAAAAAAHz9V3cwvk9EAAFtBuJUCdQAI9P34XgGsgPfLDnZv2ee6luo2uVAvAAOrGfQ3kLfQxsAAAAAAAAAAAAAD4o5kK0Q3gASudn9zz3B0BFlUmscheIAH3dw50bBjYFPHuaa0A3kBPge87fufTz3B0AAAAAAAAAAAB56KDybC9HnDvAF3AtJVCdAB4Q6z7+LwDWQHTna51LELgAKm25dzSPfPRAAelhP59PP6A50AAAAAAAAAAAAD4o7+u3OALSe+dXbfpAQtPQpueg6gT4nc1SyVnWrIVqyEO649p0DOgBxc7IDXOcKbCrINZTod5jf0I2AAAAAAAAAAAAAAfP0KH5sa70ecO8AW9R2zq6ELgAAAAAAKadVVkFJgD7Jth575/QHOgAAAAAAAAAAAAAAeUd7C3isFogAWsuju4W9GdgAAAAPPYXeQeR6IA4HSzgXcqeiVQAAAAAAAAAAAAAAAAKTld8qyqVs7ypWwqbLp9Z1IE6AAAAAeUd1w1ipWymKlbCpWw8lkag6AAAAAAAAAAAOR1AAAcuoAAAAAAAAAAAQ4pbIE8AAAAAAEUlI0kAAAAAAAZ3RZ080WDmmwR5Ar4NCdttg94AHPoADw9eeh54fQAD4+j0Hxl5FOfPuntDBy9JmjWd6q1ADn0AB8H289GV1WVPvT5jTgAAAAAADO6LOlP1+dmYqX1gnGTpIZn95g94Q8v72K+Xc5w2UOvnmc956Q6/MzHHvlvYmbs6uzNJmpudPPrSUha3mE2Rj7Wm0JeAee8jqrZxEzCYVk2/wA8avvlLcr6dpCg56DOmpqbWqPvT5jTgAAAAAADO6LOlVt8Rtx8fYUd5Rmf3eE3hg7XjXnW3jemoqZUUzm6wu6IWP3WKNfJyc8h9Km2Pqv0GVLDlytS4lZ/QGN+r/KG79x9kX2a5Vh97OruzBazPemxofukFxHtzM7XBXZosJbU5qKq1qj70+Y04AAAAAAApLsZPWAAqLcY/YBxzuoGJlawRY9kMjrgQZ0UzPxeyjK2NbdF7TXIxjZikuwQJ4yUTcDH3VsAI+c1YxNjpR8fYUtJtRkfjYiur9CKC/AAAAAAAAAAAAAAAABRXowfm3+DM6z7AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAH//aAAwDAQACAAMAAAAh888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888847/8A9PPPM9//AHzzzzzzzzzzzzzzzzzzzzyxY4rXzzwQ44bzzzzzzzzzzzzzzzzzzzz/AOe++l88K+++TU8888888888888888888zW+/Ge04n+++uh888888888888888888qkeim888L++hW+CT88888888888888888qW+g3884v+CPy2OW08888888888888889n+6X888B+6R98W+IQ888888888888888R2+Cf88nC6yc88/2uJ988888888888888RW6t888u+6Sc88/X2rc88888888888888LeQw287OOOc88/wD6x888888888888888sB2Ox88888888pGeB08888888888888888dW+Cf8888884E+8P88888888888888888sAxxU888888bBxFf88888888888848880888888888884w8888884088888888A4oo888w0088488IY088884s888888888MswoMIkcIsAsMMY8884scAIA88888888888ooAUc8I8IYQUE8wEMwI4YA8888888888888scMcoAosMcsM88Ms88ssc88888888888888888Is888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888//2gAMAwEAAgADAAAAEPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPONssvPPPNOsv/PPPPPPPPPPPPPPPPPPPPKa891PPOes8yfPPPPPPPPPPPPPPPPPPPPY4wwzdPBAww7vfPPPPPPPPPPPPPPPPPPL6wwN78quQww02/PPPPPPPPPPPPPPPPPO2o31fPPFAw26w/wBvzzzzzzzzzzzzzzzzy2sNr7zy1AP96UvPrzzzzzzzzzzzzzzzyvgMffzzzUMf/wDqrD1+888888888888888GLD/988x/HP088LLTn/8APPPPPPPPPPPPLBqx1PPOOgx6XPPPoi1FvPPPPPPPPPPPPPH47ut/KP8A74bzznPQcHzzzzzzzzzzzzzzzz8vM/Tzzzzzzw3uP/bzzzzzzzzzzzzzzzzisP8A+8888889aDBM888888888888888888/MMz888888C+M528888888888884888088888888888w48888888088888888gw80444804w848gIQc48888w888888888sY0U0w4QU4IsgsA8o4wQk8kc888888888888UIEAUo4oQAQwQws88kU4888888888sc88M8cMcswk8s8s888sMcc8M888888888888888888gk888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888888//xAAqEQABAgUDBQACAgMAAAAAAAABAgMABBESMRATQRQgIUBRMGEVQ0JwgP/aAAgBAgEBPwD/AFfmNtXwxtq+GLF/D22qPkCLF/DG2r4YIIz60izVV547JxnbXUYOrbZWoJEJSlAAGNZ1m9FwyPVSkqUAIabS2kJHZMNbiKc8QRTwdJBm0Xnnsz4iZa2l049SQa/sOqlACpjq2vsdW19iZsK6oNaww0XFgQAALRjtm2dxFRkem22VqtHMIQEJAHGs89QWDnPZJM2IuOTqVBIqrXMTbO2v9H0pFmgvPONVqCE1PELWVqKjrLNbq6cRTWdeuVaOIlXdxHnOsyzuopzxGPQZaLiwkQEhIoONZ93/AAHZKNbaKnJ1mHQ2gmCSTUxKu7a/OD2TjO2u4YPoSLNiLzk6uuBCSowpRUok6yrO4vzgdk69eugwNZN69FDkavtBxFsEEGh/Ow4FoBGs89cqwYHZLNbSAOdZp3bR+z2S7u2uvEVr5GhNPJh9YWsqH55J61VpwdHCQCU+TBlXiakQtpSDRQpowpCV1XxHXNR1zUdc1Ey/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" alt="MergeCoal Logo" />
  <div><div class="company-name">PT Merge Mining Industri</div>
  <div class="company-addr">Gedung The Honey Lady, Lt. 15 Unit 1503, Pluit, Penjaringan, Jakarta Utara<br>Kota Administrasi Jakarta Utara DKI Jakarta 12190<br>Indonesia</div></div>
</div></div>
<hr class="divider">
<div class="two-col">
  <div>
    <div class="to-box"><div class="label">To / 供应商</div><div class="vendor">${esc(po.vendor_name)}</div></div>
  </div>
  <div class="po-box"><div class="title">Purchase Order</div>
  <div class="po-meta">
    <span class="key">Number</span><span class="val">: ${esc(po.po_number)}</span>
    <span class="key">Date</span><span class="val">: ${esc(po.po_date)}</span>
  </div></div>
</div>
<table class="items"><thead><tr>
  <th style="width:110px">Item Code</th><th>Item Name / 品名</th>
  <th class="num" style="width:120px">Qty / UOM</th>
  <th class="num" style="width:130px">@Price</th>
  <th class="num" style="width:80px">Discount</th>
  <th class="num" style="width:140px">Total</th>
</tr></thead><tbody>${itemRows}</tbody></table>
<div class="bottom">
  <div class="notes-box"><div class="label">Notes / 备注</div><div>${esc(po.notes) || '—'}</div></div>
  <div class="totals">
    <div class="total-row"><span>Sub Total</span><span>${fmt(subtotal)}</span></div>
    ${discountAmount > 0 ? `<div class="total-row"><span>Diskon</span><span>− ${fmt(discountAmount)}</span></div>` : ''}
    ${charges.map(c => `<div class="total-row"><span>${esc(c.description)}</span><span>+ ${fmt(c.amount)}</span></div>`).join('')}
    ${vatAmount > 0 ? `<div class="total-row"><span>PPN (11%)</span><span>${fmt(vatAmount)}</span></div>` : ''}
    ${pphAmount > 0 ? `<div class="total-row"><span>${pphLabel}</span><span>− ${fmt(pphAmount)}</span></div>` : ''}
    <div class="total-row grand"><span>Total</span><span>${fmt(grandTotal)}</span></div>
  </div>
</div>
<div class="sigs">
  <div class="sig-block"><div class="sig-label">Ordered By,</div><div class="sig-line">Purchasing</div></div>
  <div class="sig-block"><div class="sig-label">Approved By,</div><div class="sig-line">Direktur</div></div>
</div>
<p style="text-align:right;font-size:8.5pt;color:#999;margin-top:24px">Halaman 1 dari 1</p>
</body></html>`;

    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.send(html);
  } catch (e) { res.status(500).send(e.message); }
});

// ── Templates ─────────────────────────────────────────────────────────────────
app.get('/api/templates', requireAuth, async (_req, res) => {
  try {
    const rows = await db.query(`
      SELECT
        t.template_id, t.template_name, t.display_name, t.sort_order,
        count(*) FILTER (WHERE ti.is_deleted = 0) AS item_count
      FROM pr_templates t
      LEFT JOIN pr_template_items ti ON ti.template_id = t.template_id
      WHERE t.is_deleted = 0
      GROUP BY t.template_id, t.template_name, t.display_name, t.sort_order
      ORDER BY t.sort_order
    `);
    res.json(rows.map(r => ({ ...r, item_count: parseInt(r.item_count) })));
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/templates/:id/items', requireAuth, async (req, res) => {
  try {
    const rows = await db.query(
      `SELECT
         ti.template_item_id, ti.template_id, ti.item_id,
         ti.name_en, ti.name_cn, ti.spec, ti.department, ti.uom, ti.default_qty, ti.sort_order
       FROM pr_template_items ti
       WHERE ti.template_id = $1 AND ti.is_deleted = 0
       ORDER BY ti.department COLLATE "C", ti.sort_order`,
      [req.params.id]
    );
    // Group by department
    const grouped = {};
    for (const row of rows) {
      const dept = row.department || 'Other';
      if (!grouped[dept]) grouped[dept] = [];
      grouped[dept].push(row);
    }
    res.json({ departments: grouped });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Admin deletes ─────────────────────────────────────────────────────────────
app.delete('/api/pr/:id', requireRole('admin'), async (req, res) => {
  try {
    // Header and lines are soft-deleted together.
    await db.tx(async (c) => {
      const pr = await db.one(
        `SELECT pr_id FROM purchase_requests WHERE legacy_pr_id = $1 AND is_deleted = 0 LIMIT 1 FOR NO KEY UPDATE`,
        [req.params.id], c
      );
      if (!pr) throw new HttpError(404, { error: 'PR not found' });
      await c.query(
        `UPDATE purchase_request_items SET is_deleted = 1 WHERE pr_id = $1 AND is_deleted = 0`, [pr.pr_id]
      );
      await c.query(`UPDATE purchase_requests SET is_deleted = 1 WHERE pr_id = $1`, [pr.pr_id]);
    });
    res.json({ ok: true });
  } catch (e) { sendError(res, e); }
});

app.delete('/api/pr-items/:itemId', requireRole('admin'), async (req, res) => {
  try {
    const rows = await db.query(
      `UPDATE purchase_request_items SET is_deleted = 1
       WHERE legacy_pr_item_id = $1 AND is_deleted = 0 RETURNING pr_item_id`,
      [req.params.itemId]
    );
    if (!rows.length) return res.status(404).json({ error: 'Item not found' });
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/po/:id', requireRole('admin'), async (req, res) => {
  try {
    // Header and lines are soft-deleted together (charges were never
    // soft-deleted by this route; unchanged).
    await db.tx(async (c) => {
      const po = await db.one(
        `SELECT po_id FROM purchase_orders WHERE legacy_po_id = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!po) throw new HttpError(404, { error: 'PO not found' });
      await c.query(
        `UPDATE purchase_order_items SET is_deleted = 1 WHERE po_id = $1 AND is_deleted = 0`, [po.po_id]
      );
      await c.query(`UPDATE purchase_orders SET is_deleted = 1 WHERE po_id = $1`, [po.po_id]);
    });
    res.json({ ok: true });
  } catch (e) { sendError(res, e); }
});

app.get('/api/users', requireRole('admin'), async (_req, res) => {
  try {
    const users = await db.query(
      `SELECT legacy_user_id AS id, username, role, full_name FROM users WHERE is_deleted = 0 ORDER BY legacy_user_id`
    );
    res.json(users);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/users', requireRole('admin'), async (req, res) => {
  try {
    const { username, password, role, full_name } = req.body;
    if (!username || !password || !role) return res.status(400).json({ error: 'username, password and role are required' });
    if (!['requester','purchasing','md','admin'].includes(role)) return res.status(400).json({ error: 'Invalid role' });
    if (password.length < 6) return res.status(400).json({ error: 'Password must be at least 6 characters' });

    const password_hash = bcrypt.hashSync(password, 10);
    let row;
    try {
      // users_live_username_uq (company_id, username) WHERE is_deleted = 0
      // rejects a duplicate live username atomically.
      row = await db.one(
        `INSERT INTO users (company_id, username, password_hash, role, full_name, email,
           department_id, status, is_deleted)
         VALUES ($1, $2, $3, $4, $5, '', '', 'active', 0)
         RETURNING legacy_user_id`,
        [db.COMPANY_ID, username, password_hash, role, full_name || '']
      );
    } catch (e) {
      if (e.code === '23505' && e.constraint === 'users_live_username_uq')
        return res.status(409).json({ error: 'Username already taken' });
      throw e;
    }
    // ClickHouse-era code answered with a JS number here, not the Int64 string.
    res.json({ ok: true, id: Number(row.legacy_user_id), username, role });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/users/:id', requireRole('admin'), async (req, res) => {
  try {
    if (String(req.session.user.id) === String(req.params.id))
      return res.status(400).json({ error: 'Cannot delete your own account' });
    const rows = await db.query(
      `UPDATE users SET is_deleted = 1 WHERE legacy_user_id = $1 AND is_deleted = 0 RETURNING user_id`,
      [req.params.id]
    );
    if (!rows.length) return res.status(404).json({ error: 'User not found' });
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Item Requests ─────────────────────────────────────────────────────────────
// request_id is a uuid column; comparing it as text keeps a malformed id a
// plain 404 (as with ClickHouse's String column) instead of a cast error.
app.post('/api/item-requests', requireAuth, async (req, res) => {
  try {
    const { name_en, name_cn, category, spec, uom, notes, source_excel_name } = req.body;
    if (!name_en) return res.status(400).json({ error: 'name_en required' });
    const row = await db.one(
      `INSERT INTO item_requests (company_id, requested_by_user_id, requested_by_name, name_en, name_cn,
         category_name, spec, uom, notes, source_excel_name, status, admin_notes, is_deleted)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'pending', '', 0)
       RETURNING request_id`,
      [db.COMPANY_ID, String(req.session.user.id),
       req.session.user.full_name || req.session.user.username,
       name_en || '', name_cn || '', category || '', spec || '', uom || 'pcs',
       notes || '', source_excel_name || '']
    );
    res.json({ request_id: row.request_id });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/item-requests', requireRole('admin'), async (_req, res) => {
  try {
    const rows = await db.query(
      `SELECT * FROM item_requests WHERE is_deleted = 0 ORDER BY created_at DESC`
    );
    res.json(rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/item-requests/mine', requireAuth, async (req, res) => {
  try {
    const rows = await db.query(
      `SELECT * FROM item_requests WHERE is_deleted = 0 AND requested_by_user_id = $1 ORDER BY created_at DESC`,
      [String(req.session.user.id)]
    );
    res.json(rows);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/item-requests/:id/approve', requireRole('admin'), async (req, res) => {
  try {
    // The new item, its ITEM number and the request's approval commit together.
    const item_id = await db.tx(async (c) => {
      const r = await db.one(
        `SELECT * FROM item_requests WHERE request_id::text = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!r) throw new HttpError(404, { error: 'Request not found' });
      // Create the item
      const item_id = await nextItemId(c);
      await c.query(
        `INSERT INTO items (item_id, company_id, base_item_id, item_code, name_en, name_cn, category_id,
           category_name, spec, uom, department_id, item_type, default_gl_account_id,
           min_order_qty, lead_time_days, status, search_text, is_deleted)
         VALUES ($1, $2, '', '', $3, $4, '', $5, $6, $7, '', 'expense', '', 0, 0, 'active', $8, 0)`,
        [item_id, db.COMPANY_ID, r.name_en, r.name_cn, r.category_name, r.spec, r.uom,
         `${r.name_en} ${r.name_cn} ${r.category_name}`.toLowerCase()]
      );
      // Mark request approved
      await c.query(
        `UPDATE item_requests SET status = 'approved', approved_item_id = $2, admin_notes = $3
         WHERE request_id = $1`,
        [r.request_id, item_id, req.body.admin_notes || '']
      );
      return item_id;
    });
    await rebuildFuse();
    res.json({ ok: true, item_id });
  } catch (e) { sendError(res, e); }
});

app.post('/api/item-requests/:id/reject', requireRole('admin'), async (req, res) => {
  try {
    const rows = await db.query(
      `UPDATE item_requests SET status = 'rejected', admin_notes = $2
       WHERE request_id::text = $1 AND is_deleted = 0 RETURNING request_id`,
      [req.params.id, req.body.admin_notes || '']
    );
    if (!rows.length) return res.status(404).json({ error: 'Request not found' });
    res.json({ ok: true });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/item-requests/:id', requireAuth, async (req, res) => {
  try {
    await db.tx(async (c) => {
      const row = await db.one(
        `SELECT request_id, requested_by_user_id FROM item_requests
         WHERE request_id::text = $1 AND is_deleted = 0 LIMIT 1 FOR UPDATE`,
        [req.params.id], c
      );
      if (!row) throw new HttpError(404, { error: 'Request not found' });
      if (row.requested_by_user_id !== String(req.session.user.id) && req.session.user.role !== 'admin') {
        throw new HttpError(403, { error: 'Forbidden' });
      }
      await c.query(`UPDATE item_requests SET is_deleted = 1 WHERE request_id = $1`, [row.request_id]);
    });
    res.json({ ok: true });
  } catch (e) { sendError(res, e); }
});

// ── Start ─────────────────────────────────────────────────────────────────────
// Schema (tables, indexes, triggers) is owned by db/postgres_schema.sql; the
// app no longer creates or alters tables at startup.
async function start() {
  console.log('Connecting to Postgres...');
  try {
    await db.ping();
  } catch (e) {
    console.error(`Postgres unreachable — exiting (${e.message})`);
    process.exit(1);
  }
  console.log('Postgres OK');
  await rebuildFuse();
  console.log(`Fuse index built (${fuse ? 'ok' : 'empty'})`);
  app.listen(PORT, () => console.log(`Procurement app running → http://localhost:${PORT}`));
}
start().catch((e) => {
  console.error('Startup failed:', e.message);
  process.exit(1);
});
