> **OUTDATED (before the 2026-10-01 Postgres cutover):** this document describes the SQLite / ClickHouse-era setup and its commands no longer apply. Current setup: `CLAUDE.md` and `RUNBOOK_POSTGRES_CUTOVER.md`.

# Operations & Monitoring Checklist
## PT Merge Mining Industri — e-Procurement System

**Server:** Hostinger KVM 4 · `76.13.19.246`  
**Stack:** Node.js + Express + SQLite · Docker · Nginx  
**Last updated:** 2026-05-05

---

## 1. Daily Checks (5 minutes)

- [ ] App is reachable at `http://76.13.19.246` (or domain when SSL is set up)
- [ ] Login works with `admin1` account
- [ ] Check container is running: `docker compose ps`
- [ ] Check no errors in logs: `docker compose logs --tail=50`

---

## 2. Weekly Checks (15 minutes)

- [ ] Review disk usage — should stay below 80%
  ```bash
  df -h
  ```
- [ ] Check database file size is growing normally
  ```bash
  ls -lh /opt/purchasing_data/data/procurement.db
  ```
- [ ] Verify backup files exist and are recent (see Section 5)
- [ ] Check for failed login attempts in logs
  ```bash
  docker compose logs | grep "Invalid password"
  ```
- [ ] Review any stuck PRs (pending > 7 days with no approval)

---

## 3. Monthly Checks (30 minutes)

- [ ] Update server packages
  ```bash
  dnf update -y
  ```
- [ ] Update Docker images
  ```bash
  cd /opt/purchasing_data
  docker compose pull
  docker compose up -d --build
  ```
- [ ] Review user accounts — remove anyone who has left the company
- [ ] Test backup restore (restore to a test file and verify it opens)
- [ ] Check SSL certificate expiry (if domain is configured)
  ```bash
  certbot renew --dry-run
  ```
- [ ] Review GL export logs for completeness

---

## 4. Uptime Monitoring (Set up once)

Use a free external monitor so you get alerted if the site goes down.

**Recommended: UptimeRobot (free)**
1. Go to uptimerobot.com → create free account
2. Add monitor → HTTP(s) → URL: `http://76.13.19.246`
3. Check interval: 5 minutes
4. Alert to: your email or WhatsApp
5. You'll get notified within 5 minutes of any downtime

---

## 5. Backup Procedure

### Automated daily backup (set up once on server)

SSH into server and run:

```bash
mkdir -p /opt/backups

cat > /opt/backup-procurement.sh << 'EOF'
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR=/opt/backups
DB_SOURCE=/opt/purchasing_data/data/procurement.db

# Copy DB with timestamp
cp "$DB_SOURCE" "$BACKUP_DIR/procurement_$TIMESTAMP.db"

# Keep only last 30 days of backups
find "$BACKUP_DIR" -name "procurement_*.db" -mtime +30 -delete

echo "Backup completed: procurement_$TIMESTAMP.db"
EOF

chmod +x /opt/backup-procurement.sh

# Schedule daily at 2am
echo "0 2 * * * root /opt/backup-procurement.sh >> /var/log/procurement-backup.log 2>&1" > /etc/cron.d/procurement-backup
```

### Manual backup (run anytime before major changes)
```bash
/opt/backup-procurement.sh
```

### Restore from backup
```bash
# Stop the app first
cd /opt/purchasing_data && docker compose down

# Replace the database
cp /opt/backups/procurement_YYYYMMDD_HHMMSS.db /opt/purchasing_data/data/procurement.db

# Restart
docker compose up -d
```

### Off-server backup (recommended)
Once a week, copy latest backup to your local Mac:
```bash
scp root@76.13.19.246:/opt/backups/$(ssh root@76.13.19.246 'ls -t /opt/backups/ | head -1') ~/Desktop/
```

---

## 6. Deploying Updates

When code changes are made on localhost and pushed to GitHub:

```bash
# On the server
cd /opt/purchasing_data
git pull
docker compose up -d --build
```

Downtime during redeploy: ~30 seconds.

---

## 7. SSL Setup (when domain is ready)

```bash
# Install Certbot (already done if nginx installed)
dnf install -y certbot python3-certbot-nginx

# Get certificate (replace with your domain)
certbot --nginx -d yourdomain.com

# Auto-renew is set up automatically by Certbot
# Verify with:
certbot renew --dry-run
```

After SSL is set up, update Nginx config to redirect HTTP → HTTPS:
```bash
# Edit the config
nano /etc/nginx/sites-available/procurement.conf
# Uncomment the redirect line, then:
nginx -t && systemctl reload nginx
```

---

## 8. Emergency Contacts & Access

| Resource | Details |
|---|---|
| Server IP | `76.13.19.246` |
| Hostinger panel | `https://hpanel.hostinger.com` |
| Cockpit dashboard | `https://76.13.19.246:9090` |
| GitHub repo | `https://github.com/gabrielrahardja1-star/purchasing_data` |
| App port | `3000` (internal), `80` via Nginx |
| DB location (server) | `/opt/purchasing_data/data/procurement.db` |
| Backups location | `/opt/backups/` |
| Logs | `docker compose logs -f` (run from `/opt/purchasing_data`) |

---

## 9. Incident Response

### App is down
```bash
ssh root@76.13.19.246
cd /opt/purchasing_data
docker compose ps          # check container status
docker compose logs --tail=100  # check for errors
docker compose up -d       # restart if stopped
```

### Database corrupted
```bash
cd /opt/purchasing_data
docker compose down
cp /opt/backups/procurement_LATEST.db data/procurement.db
docker compose up -d
```

### Disk full
```bash
df -h                      # check what's full
docker system prune -f     # clean unused Docker images
find /opt/backups -mtime +7 -delete  # remove old backups
```

### Can't SSH into server
- Log in via Hostinger panel → VPS → Console
- URL: `https://hpanel.hostinger.com`

---

## 10. Known Limitations (v1)

- No password reset UI — must update directly in DB
- No email notifications on PR status change
- GL account codes hardcoded (5000 / 2100)
- No PO amendment — POs are immutable once created
- Approver name in MD view is free-text (not tied to login)
- Single server — no redundancy or failover
