'use strict';

/**
 * One-time script to add a user to the ClickHouse users table.
 * Run on the server where CLICKHOUSE_PASSWORD (and other env vars) are set:
 *   node create_user.js
 */

const bcrypt = require('bcryptjs');
const ch     = require('./clickhouse');

// Never hard-code the password here: this repo is public, and a literal left
// in a one-time script outlives the one time it was run.
const NEW_USER = {
  username:  process.env.NEW_USER_NAME     || 'purchasing2',
  password:  process.env.NEW_USER_PASSWORD,
  role:      process.env.NEW_USER_ROLE     || 'purchasing',
  full_name: process.env.NEW_USER_FULLNAME || 'Purchasing 2',
};

if (!NEW_USER.password) {
  console.error('Set NEW_USER_PASSWORD, e.g. NEW_USER_PASSWORD=... node create_user.js');
  process.exit(1);
}

(async () => {
  // Check for duplicate
  const existing = await ch.query(
    `SELECT username FROM users FINAL WHERE company_id = {cid:String} AND username = {u:String} AND is_deleted = 0 LIMIT 1`,
    { cid: ch.COMPANY_ID, u: NEW_USER.username }
  );
  if (existing.length > 0) {
    console.error(`User "${NEW_USER.username}" already exists. Aborting.`);
    process.exit(1);
  }

  const password_hash = bcrypt.hashSync(NEW_USER.password, 10);
  const now           = ch.nowTs();
  const ver           = Number(ch.version());

  // Find next legacy_user_id
  const maxId = await ch.query(`SELECT max(legacy_user_id) AS m FROM users FINAL WHERE is_deleted = 0`);
  const legacy_user_id = (Number(maxId[0]?.m) || 0) + 1;

  await ch.insert('users', [{
    user_id:       ch.newUUID(),
    legacy_user_id,
    company_id:    ch.COMPANY_ID,
    username:      NEW_USER.username,
    password_hash,
    role:          NEW_USER.role,
    full_name:     NEW_USER.full_name,
    email:         '',
    department_id: '',
    status:        'active',
    version:       ver,
    is_deleted:    0,
    created_at:    now,
    updated_at:    now,
  }]);

  console.log(`✓ Created user: ${NEW_USER.username} (role: ${NEW_USER.role}, legacy_id: ${legacy_user_id})`);
})().catch(err => {
  console.error('Failed:', err.message);
  process.exit(1);
});
