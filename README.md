# Webstack-Template

Schnelles, sicheres Deployment einer Next.js + Postgres + Nginx-Webseite
auf einem frischen Linux-VPS (Ubuntu 24.04 LTS empfohlen).

## Was wird aufgesetzt?

- **Server-Härtung**: SSH key-only, Custom-Port, kein Root-Login
- **UFW** Firewall (nur 22-alt, 80, 443 offen)
- **Fail2Ban** mit SSH- und Nginx-Jails
- **Unattended-Upgrades** für automatische Sicherheits-Patches
- **Kernel-Hardening** via sysctl
- **Docker** + Docker Compose
- **Nginx** als Reverse Proxy (auf dem Host)
- **Let's Encrypt** TLS via Certbot mit Auto-Renewal
- **Security-Header** (HSTS, X-Frame-Options usw.)
- **Next.js**-App + **PostgreSQL 16** in Docker mit isoliertem Backend-Netz

```
[Internet] → [Nginx :443 (Host, TLS)] → [Next.js :3000 (Container)] → [Postgres (Container, internal)]
```

---

## Erstmaliges Server-Setup (einmalig pro Server)

### 1. VPS bestellen und DNS einrichten

- VPS bei Hetzner / Netcup / Hosting-Anbieter (Ubuntu 24.04).
- Bei deinem DNS-Anbieter (z. B. Hetzner DNS) einen **A-Record** anlegen,
  der `deine-domain.de` (und ggf. `www`) auf die Server-IP zeigt.
- 5–10 Minuten warten, bis DNS propagiert ist
  (prüfen mit `dig deine-domain.de` oder https://dnschecker.org).

### 2. Erstmals als root einloggen und Skript ausführen

```bash
ssh root@<server-ip>

# Skript runterladen (entweder per scp hochladen oder von GitHub klonen)
wget https://raw.githubusercontent.com/<dein-user>/<dein-repo>/main/scripts/setup-server.sh
# ODER per scp vom lokalen Rechner:
# scp scripts/setup-server.sh root@<server-ip>:/root/

bash setup-server.sh
```

Das Skript fragt nach:

- Domain, E-Mail (für Let's Encrypt)
- Name des neuen Sudo-Users (Default `deploy`)
- Neuer SSH-Port (Default `2222`)
- App-Port (Default `3000`)
- Dein SSH-Public-Key (siehe unten)

Anschließend macht es alles automatisch.

### 3. SSH-Key vorbereiten (lokal)

Auf deinem Rechner, falls du noch keinen hast:

```bash
ssh-keygen -t ed25519 -C "you@example.com"
cat ~/.ssh/id_ed25519.pub   # Diesen Output ins Skript einfügen
```

### 4. Neue SSH-Verbindung testen (WICHTIG: alte offen lassen!)

In einem **zweiten Terminal**:

```bash
ssh -p 2222 deploy@<server-ip>
```

Erst wenn das funktioniert, das alte Root-Terminal schließen.

---

## App deployen

### 5. App-Code auf den Server bringen

Auf dem Server, eingeloggt als `deploy`:

```bash
cd ~/app

# Variante A: GitHub klonen
git clone https://github.com/<user>/<repo>.git .

# Variante B: Code per scp hochschieben (vom lokalen Rechner)
# scp -P 2222 -r ./mein-projekt/* deploy@<server-ip>:~/app/
```

Stelle sicher, dass im App-Verzeichnis vorhanden sind:

- `Dockerfile` (siehe `app/Dockerfile` aus diesem Template)
- `docker-compose.yml` (siehe `app/docker-compose.yml`)
- `.env` (aus `.env.example` kopieren!)

### 6. Next.js für Standalone-Build konfigurieren

In `next.config.js` deiner App:

```js
module.exports = {
  output: 'standalone',
};
```

### 7. Environment-Datei erstellen

```bash
cp .env.example .env
nano .env

# Starkes DB-Passwort generieren:
openssl rand -base64 32
```

### 8. Container starten

```bash
docker compose up -d --build
docker compose logs -f app   # Logs prüfen
```

Das Image wird gebaut, App und DB starten, Nginx leitet Traffic von
Port 443 (TLS) auf den App-Container.

### 9. Im Browser öffnen

`https://deine-domain.de`  fertig.

---

## Updates deployen

```bash
cd ~/app
git pull
docker compose up -d --build
```

Oder mit GitHub Actions automatisiert (siehe Beispiel in `.github/workflows/deploy.yml`).

---

## Häufige Probleme

**Certbot schlägt fehl mit "DNS problem"**
DNS zeigt noch nicht auf den Server. Warten + erneut ausführen:
`sudo certbot --nginx -d deine-domain.de -d www.deine-domain.de`

**App startet, aber 502 Bad Gateway**
- Läuft der Container? `docker compose ps`
- Hört er auf 3000? `docker compose logs app`
- Stimmt der Port in der Nginx-Config?
  `/etc/nginx/sites-available/deine-domain.de`

**Datenbank-Verbindung scheitert**
- Stimmen die Werte in `.env`?
- Warten, bis Postgres healthy ist: `docker compose ps`

**Nach Reboot kommt nichts hoch**
Compose hat `restart: unless-stopped`  sollte automatisch starten.
Prüfen mit `docker compose ps`. Notfalls `docker compose up -d`.

---

## Backups

Tägliches Postgres-Backup (`crontab -e` als deploy-User):

```cron
0 3 * * * cd /home/deploy/app && docker compose exec -T db pg_dump -U appuser appdb | gzip > /home/deploy/backups/db-$(date +\%F).sql.gz
0 4 * * * find /home/deploy/backups -name "db-*.sql.gz" -mtime +14 -delete
```

Off-site z. B. via `restic` zu Hetzner Storage Box / Backblaze B2.

---

## Security-Check nach dem Setup

```bash
sudo ufw status verbose          # Firewall-Regeln
sudo fail2ban-client status      # Aktive Jails
sudo systemctl status nginx      # Nginx läuft
sudo certbot certificates        # Zertifikat sichtbar
sudo ss -tlnp                    # Welche Ports lauschen?
```

Nginx-Config testen: https://www.ssllabs.com/ssltest/
Header testen: https://securityheaders.com
