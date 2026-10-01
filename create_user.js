'use strict';

/**
 * One-time script to add a user to the Postgres users table.
 * Run where the app's PG* env vars (PGHOST, PGDATABASE, PGUSER, PGPASSWORD) are set:
 *   NEW_USER_PASSWORD=... node create_user.js
 */

const bcrypt = require('bcryptjs');
const db     = require('./db');

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
  // Check for duplicate (the partial unique index users_live_username_uq
  // also enforces this, so a concurrent insert cannot slip through).
  const existing = await db.query(
    `SELECT username FROM users WHERE company_id = $1 AND username = $2 AND is_deleted = 0 LIMIT 1`,
    [db.COMPANY_ID, NEW_USER.username]
  );
  if (existing.length > 0) {
    console.error(`User "${NEW_USER.username}" already exists. Aborting.`);
    await db.close();
    process.exit(1);
  }

  const password_hash = bcrypt.hashSync(NEW_USER.password, 10);

  let row;
  try {
    // legacy_user_id comes from the identity sequence.
    row = await db.one(
      `INSERT INTO users (company_id, username, password_hash, role, full_name, email,
         department_id, status, is_deleted)
       VALUES ($1, $2, $3, $4, $5, '', '', 'active', 0)
       RETURNING legacy_user_id`,
      [db.COMPANY_ID, NEW_USER.username, password_hash, NEW_USER.role, NEW_USER.full_name]
    );
  } catch (e) {
    if (e.code === '23505' && e.constraint === 'users_live_username_uq') {
      console.error(`User "${NEW_USER.username}" already exists. Aborting.`);
      await db.close();
      process.exit(1);
    }
    throw e;
  }

  console.log(`✓ Created user: ${NEW_USER.username} (role: ${NEW_USER.role}, legacy_id: ${row.legacy_user_id})`);
  await db.close();
})().catch(err => {
  console.error('Failed:', err.message);
  process.exit(1);
});
