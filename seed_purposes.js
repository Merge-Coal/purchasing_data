'use strict';

/**
 * seed_purposes.js — Seed the `purposes` reference table in ClickHouse.
 * Idempotent: re-running just bumps version/updated_at on ReplacingMergeTree.
 *
 * Usage:
 *   CLICKHOUSE_PASSWORD=... node seed_purposes.js
 *   CLICKHOUSE_HOST=76.13.19.246 CLICKHOUSE_PASSWORD=... node seed_purposes.js
 */

const ch = require('./clickhouse');

const LABELS = [
  'Coal Wash 洗煤厂',
  'Dormitory 7 & 8 宿舍',
  'Front Office 办公室',
  'Changing Room 更衣室',
  'Gas Drainage 抽瓦斯',
  'Workshop 维修车间',
  'Underground 井下',
  'Trafo Room 变电所',
  'Water Treatment Plant 净化水厂',
  'Winch Station 绞车房',
  'Others 其他',
];

async function main() {
  const now = new Date().toISOString().replace('T', ' ').replace('Z', '');
  const rows = LABELS.map((label, i) => ({
    purpose_id: label.replace(/[^\w]+/g, '_').toLowerCase().replace(/^_+|_+$/g, ''),
    company_id: ch.COMPANY_ID,
    label,
    sort_order: i,
    status: 'active',
    is_deleted: 0,
    created_at: now,
    updated_at: now,
  }));
  await ch.insert('purposes', rows);
  console.log(`Seeded ${rows.length} purposes.`);
}

main().catch(e => { console.error(e); process.exit(1); });
