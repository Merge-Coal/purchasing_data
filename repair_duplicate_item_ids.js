'use strict';

/**
 * repair_duplicate_item_ids.js — one-time data repair.
 *
 * Bug: POST /api/pr and POST /api/po called nextLegacyId() inside the item
 * loop but only inserted rows after the loop, so every line item in a
 * multi-item PR/PO got the SAME legacy_pr_item_id / legacy_po_item_id.
 * The approve route matches items by legacy id with LIMIT 1, so approvals
 * landed on an arbitrary line of the PR.
 *
 * This script reassigns fresh unique legacy ids to all but the first row of
 * each duplicate group. Cross-references are unaffected: purchase_order_items
 * and approval_actions reference items by UUID, not legacy id.
 *
 * Usage (on the server, same env as the app):
 *   CLICKHOUSE_PASSWORD=... node repair_duplicate_item_ids.js          # dry run
 *   CLICKHOUSE_PASSWORD=... node repair_duplicate_item_ids.js --apply  # write
 */

const ch = require('./clickhouse');

const APPLY = process.argv.includes('--apply');

async function repairTable(table, legacyField, parentField) {
  const rows = await ch.query(
    `SELECT * FROM ${table} FINAL WHERE is_deleted = 0 ORDER BY ${legacyField}, created_at`
  );
  const byLegacy = new Map();
  for (const r of rows) {
    const key = String(r[legacyField]);
    if (!byLegacy.has(key)) byLegacy.set(key, []);
    byLegacy.get(key).push(r);
  }

  let nextId = rows.reduce((m, r) => Math.max(m, parseInt(r[legacyField], 10) || 0), 0) + 1;
  const affectedParents = new Set();
  const updates = [];

  for (const [legacyId, group] of byLegacy) {
    if (group.length < 2) continue;
    console.log(`${table}: legacy id ${legacyId} shared by ${group.length} rows (${parentField}s: ${[...new Set(group.map(g => g[parentField]))].join(', ')})`);
    // keep the first row's id, reassign the rest
    for (const row of group.slice(1)) {
      updates.push({ ...row, [legacyField]: nextId++ });
      affectedParents.add(row[parentField]);
    }
    affectedParents.add(group[0][parentField]);
  }

  if (!updates.length) {
    console.log(`${table}: no duplicates found.`);
    return affectedParents;
  }

  console.log(`${table}: ${updates.length} rows need new legacy ids.`);
  if (APPLY) {
    const now = ch.nowTs();
    let ver = Number(ch.version());
    for (const u of updates) u.version = ver++; // unique versions so ReplacingMergeTree ordering is deterministic
    for (const u of updates) u.updated_at = now;
    await ch.insert(table, updates);
    console.log(`${table}: reassigned.`);
  } else {
    console.log(`${table}: DRY RUN — rerun with --apply to write.`);
  }
  return affectedParents;
}

(async () => {
  const prIds = await repairTable('purchase_request_items', 'legacy_pr_item_id', 'pr_id');
  const poIds = await repairTable('purchase_order_items', 'legacy_po_item_id', 'po_id');

  // PRs that had duplicate ids AND already have decided items: those decisions
  // may have been applied to the wrong line — flag them for MD re-review.
  if (prIds.size) {
    const list = [...prIds].map(id => `'${id}'`).join(',');
    const flagged = await ch.query(
      `SELECT DISTINCT pr.pr_number
       FROM purchase_request_items pri FINAL
       JOIN purchase_requests pr FINAL ON toString(pr.pr_id) = pri.pr_id
       WHERE pri.pr_id IN (${list}) AND pri.is_deleted = 0 AND pri.status != 'pending'`
    );
    if (flagged.length) {
      console.log('\n⚠ PRs with approvals that may have hit the wrong line item — re-review these:');
      flagged.forEach(f => console.log(`  ${f.pr_number}`));
    }
  }
  if (poIds.size) {
    console.log(`\n⚠ ${poIds.size} PO(s) had duplicate line-item ids (GL export/receiving lookups by item id were ambiguous).`);
  }
  console.log('\nDone.');
})().catch(e => { console.error('Repair failed:', e.message); process.exit(1); });
