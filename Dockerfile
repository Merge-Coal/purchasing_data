FROM node:22-alpine

# Install build tools needed for better-sqlite3 native module
RUN apk add --no-cache python3 make g++

WORKDIR /app

# Install dependencies first (layer cache)
COPY package*.json ./
RUN npm install --omit=dev

# Copy application source and one-off admin scripts (run via docker exec)
COPY server.js clickhouse.js create_user.js repair_duplicate_item_ids.js ./
COPY public/ ./public/
COPY db/schema.sql ./db/schema.sql

# Create directories that must exist at runtime
RUN mkdir -p exports db

# The SQLite database files are mounted as a volume — not baked into the image
# so data persists across container restarts and rebuilds

EXPOSE 3000

CMD ["node", "server.js"]
