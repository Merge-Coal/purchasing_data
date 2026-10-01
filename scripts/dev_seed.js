'use strict';

/**
 * scripts/dev_seed.js — seed a LOCAL DEV Postgres database with just enough
 * data to click through the whole PR → approval → PO → GL export workflow.
 *
 *   createdb procurement_dev
 *   psql -v ON_ERROR_STOP=1 -d procurement_dev -f db/postgres_schema.sql
 *   PGDATABASE=procurement_dev node scripts/dev_seed.js
 *
 * Connection comes from the standard PG* env vars. Idempotent: re-running
 * inserts nothing new and only moves doc_counters forward, never back.
 * Default password for every seeded user is "merge2026" — dev only.
 */

const bcrypt = require('bcryptjs');
const db     = require('../db');

const CID = db.COMPANY_ID;
const DEV_PASSWORD = 'merge2026';

const USERS = [
  { username: 'requester1',  role: 'requester',  full_name: 'Requester One' },
  { username: 'purchasing1', role: 'purchasing', full_name: 'Purchasing One' },
  { username: 'md1',         role: 'md',         full_name: 'Managing Director' },
  { username: 'admin1',      role: 'admin',      full_name: 'Admin One' },
];

const ITEMS = [
  // item_id,   name_en,                   name_cn,     category,        spec,                 uom,     department
  ['ITEM-0001', 'Hydraulic Oil 46',        '液压油46',   'Lubricants',    'ISO VG 46, 20L pail', 'Pail',  'Mechanical'],
  ['ITEM-0002', 'Grease EP2',              '润滑脂EP2',  'Lubricants',    '15kg drum',           'Drum',  'Mechanical'],
  ['ITEM-0003', 'Bearing 6205',            '轴承6205',   'Spare Parts',   '25x52x15mm',          'Pcs',   'Mechanical'],
  ['ITEM-0004', 'V-Belt B-52',             '三角带B-52', 'Spare Parts',   '',                    'Pcs',   'Mechanical'],
  ['ITEM-0005', 'Cable NYY 4x16mm',        '电缆4x16',   'Electrical',    '0.6/1kV',             'M',     'Electrical'],
  ['ITEM-0006', 'MCB 3P 32A',              '断路器32A',  'Electrical',    'Schneider iC60N',     'Pcs',   'Electrical'],
  ['ITEM-0007', 'LED Lamp 18W',            'LED灯18W',   'Electrical',    'E27 6500K',           'Pcs',   'Electrical'],
  ['ITEM-0008', 'Rice 25kg',               '大米25公斤', 'Food',          'Premium',             'Bag',   'Kitchen'],
  ['ITEM-0009', 'Cooking Oil 18L',         '食用油18升', 'Food',          '',                    'Pcs',   'Kitchen'],
  ['ITEM-0010', 'Drinking Water Gallon',   '桶装水',     'Food',          '19L',                 'Pcs',   'Kitchen'],
];

const PURPOSES = [
  ['workshop',  'Workshop 维修车间', 0],
  ['underground', 'Underground 井下', 1],
  ['others',    'Others 其他',       2],
];

const TEMPLATE_ID = '00000000-0000-4000-8000-00000000a001';
const TEMPLATE_ITEMS = [
  // template_item_id,                         item_id,     department,   uom,   default_qty, sort_order
  ['00000000-0000-4000-8000-00000000b001', 'ITEM-0001', 'Mechanical', 'Pail', 4,   0],
  ['00000000-0000-4000-8000-00000000b002', 'ITEM-0002', 'Mechanical', 'Drum', 1.5, 1],
  ['00000000-0000-4000-8000-00000000b003', 'ITEM-0008', 'Kitchen',    'Bag',  10,  0],
];

const VENDORS = [
  ['V-0001', 'PT Sumber Teknik Abadi', 'Spare Parts', 'Budi Santoso', '021-5551234', 'budi@sumberteknik.example', 'Jakarta'],
  ['V-0002', 'CV Pangan Sejahtera',    'Food',        'Siti Rahma',   '0541-778899', 'siti@pangan.example',      'Samarinda'],
];

async function main() {
  // The seeded logins all share a published password. The production image
  // contains this file, so refuse to run there (compose sets NODE_ENV=production)
  // or against the production database name.
  if (process.env.NODE_ENV === 'production' || process.env.PGDATABASE === 'procurement') {
    console.error('Refusing to seed: this script creates users with a known password and is for local dev databases only.');
    process.exit(1);
  }
  await db.ping();
  const hash = bcrypt.hashSync(DEV_PASSWORD, 10);

  await db.tx(async (c) => {
    for (const u of USERS) {
      // NOT EXISTS (rather than ON CONFLICT alone) so re-runs do not burn
      // legacy_user_id identity values.
      await c.query(
        `INSERT INTO users (company_id, username, password_hash, role, full_name)
         SELECT $1, $2, $3, $4, $5
         WHERE NOT EXISTS (SELECT 1 FROM users WHERE company_id = $1 AND username = $2 AND is_deleted = 0)
         ON CONFLICT (company_id, username) WHERE is_deleted = 0 DO NOTHING`,
        [CID, u.username, hash, u.role, u.full_name]
      );
    }

    for (const [item_id, name_en, name_cn, category, spec, uom, dept] of ITEMS) {
      await c.query(
        `INSERT INTO items (item_id, company_id, name_en, name_cn, category_name, spec, uom,
           department_id, item_type, status, search_text)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'expense', 'active', $9)
         ON CONFLICT (item_id) DO NOTHING`,
        [item_id, CID, name_en, name_cn, category, spec, uom, dept,
         `${name_en} ${name_cn} ${category}`.toLowerCase()]
      );
    }

    for (const [purpose_id, label, sort_order] of PURPOSES) {
      await c.query(
        `INSERT INTO purposes (purpose_id, company_id, label, sort_order, status)
         VALUES ($1, $2, $3, $4, 'active') ON CONFLICT (purpose_id) DO NOTHING`,
        [purpose_id, CID, label, sort_order]
      );
    }

    await c.query(
      `INSERT INTO pr_templates (template_id, company_id, template_name, display_name, sort_order)
       VALUES ($1, $2, 'MONTHLY', 'Monthly Consumables', 1) ON CONFLICT (template_id) DO NOTHING`,
      [TEMPLATE_ID, CID]
    );
    const itemById = new Map(ITEMS.map(i => [i[0], i]));
    for (const [tiid, item_id, dept, uom, qty, sort_order] of TEMPLATE_ITEMS) {
      const it = itemById.get(item_id);
      await c.query(
        `INSERT INTO pr_template_items (template_item_id, company_id, template_id, item_id,
           name_en, name_cn, spec, department, uom, default_qty, sort_order)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
         ON CONFLICT (template_item_id) DO NOTHING`,
        [tiid, CID, TEMPLATE_ID, item_id, it[1], it[2], it[4], dept, uom, qty, sort_order]
      );
    }

    for (const [vendor_id, name, category, contact, phone, email, city] of VENDORS) {
      await c.query(
        `INSERT INTO vendors (vendor_id, company_id, vendor_name, category, status,
           contact_person, phone, email, city, search_text)
         VALUES ($1, $2, $3, $4, 'active', $5, $6, $7, $8, $9)
         ON CONFLICT (vendor_id) DO NOTHING`,
        [vendor_id, CID, name, category, contact, phone, email, city,
         `${name} ${city}`.toLowerCase()]
      );
    }

    // Counters = highest number already used (including soft-deleted rows,
    // whose ids still occupy the primary key). Only ever moved forward.
    const year = new Date().getFullYear();
    const counters = [
      ['ITEM', 0,    `SELECT max(substring(item_id from '^ITEM-(\\d+)$')::int) AS n FROM items`, []],
      ['V',    0,    `SELECT max(substring(vendor_id from '^V-(\\d+)$')::int) AS n FROM vendors`, []],
      ['PR',   year, `SELECT max(substring(pr_number from '^PR-\\d{4}-(\\d+)$')::int) AS n
                      FROM purchase_requests WHERE pr_number LIKE $1`, [`PR-${year}-%`]],
      ['PO',   year, `SELECT max(substring(po_number from '^PO-\\d{4}-(\\d+)$')::int) AS n
                      FROM purchase_orders WHERE po_number LIKE $1`, [`PO-${year}-%`]],
    ];
    for (const [docType, y, sql, params] of counters) {
      const n = (await db.one(sql, params, c)).n || 0;
      await c.query(
        `INSERT INTO doc_counters (doc_type, year, last_no) VALUES ($1, $2, $3)
         ON CONFLICT (doc_type, year) DO UPDATE
           SET last_no = GREATEST(doc_counters.last_no, EXCLUDED.last_no)`,
        [docType, y, n]
      );
    }
  });

  const summary = await db.query(
    `SELECT (SELECT count(*) FROM users WHERE is_deleted = 0)             AS users,
            (SELECT count(*) FROM items WHERE is_deleted = 0)             AS items,
            (SELECT count(*) FROM purposes WHERE is_deleted = 0)          AS purposes,
            (SELECT count(*) FROM pr_templates WHERE is_deleted = 0)      AS templates,
            (SELECT count(*) FROM pr_template_items WHERE is_deleted = 0) AS template_items,
            (SELECT count(*) FROM vendors WHERE is_deleted = 0)           AS vendors`
  );
  const counters = await db.query(`SELECT doc_type, year, last_no FROM doc_counters ORDER BY doc_type, year`);
  console.log('Seeded:', summary[0]);
  console.log('doc_counters:', counters.map(r => `${r.doc_type}/${r.year}=${r.last_no}`).join(', '));
  await db.close();
}

main().catch(async (e) => {
  console.error('Seed failed:', e.message);
  try { await db.close(); } catch { /* ignore */ }
  process.exit(1);
});
