FROM node:22-alpine

# No native modules remain (better-sqlite3 / connect-sqlite3 were removed with the
# SQLite session store), so no apk build toolchain is needed.

WORKDIR /app

# Install dependencies first (layer cache)
COPY package*.json ./
RUN npm install --omit=dev

# Copy application source and one-off admin scripts (run via docker exec).
# db.js is the Postgres access layer used by the app; clickhouse.js stays for
# the warehouse sync and the legacy ClickHouse admin scripts.
COPY server.js db.js clickhouse.js create_user.js repair_duplicate_item_ids.js migrate_ch_to_pg.js ./
COPY scripts/ ./scripts/
COPY public/ ./public/
COPY db/postgres_schema.sql ./db/

# Create directories that must exist at runtime
RUN mkdir -p db

# All data lives in Postgres (PG* env vars); the container keeps no state on disk.

EXPOSE 3000

CMD ["node", "server.js"]
