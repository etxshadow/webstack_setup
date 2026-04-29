#!/usr/bin/env bash
# =============================================================================
#  Webstack Bootstrap-Skript v2
#  Härtet einen frischen Ubuntu-24.04-Server und installiert:
#  - UFW Firewall, Fail2Ban, Unattended-Upgrades
#  - Optional: Neuer Sudo-User + SSH-Port-Wechsel
#  - Docker + Docker Compose
#  - Nginx + Certbot (Let's Encrypt)
#
#  Verwendung (auf frischem Server, als root):
#      bash setup-server.sh
# =============================================================================

set -euo pipefail

# ----- Helfer -------------------------------------------------------------
RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
info()  { printf "%s[*]%s %s\n" "$BLU" "$RST" "$1"; }
ok()    { printf "%s[+]%s %s\n" "$GRN" "$RST" "$1"; }
warn()  { printf "%s[!]%s %s\n" "$YLW" "$RST" "$1"; }
fail()  { printf "%s[x]%s %s\n" "$RED" "$RST" "$1" >&2; exit 1; }
ask()   { local p="$1" d="${2:-}" v; read -rp "$(printf "%s[?]%s %s%s: " "$YLW" "$RST" "$p" "${d:+ [$d]}")" v; echo "${v:-$d}"; }
ask_pw() {
    local p="$1" v1 v2
    while true; do
        read -rsp "$(printf "%s[?]%s %s: " "$YLW" "$RST" "$p")" v1; echo
        read -rsp "$(printf "%s[?]%s %s (Wiederholung): " "$YLW" "$RST" "$p")" v2; echo
        [[ "$v1" == "$v2" && -n "$v1" ]] && { echo "$v1"; return; }
        warn "Passwörter stimmen nicht überein oder leer. Erneut."
    done
}

[[ $EUID -eq 0 ]] || fail "Bitte als root ausführen (oder mit sudo)."

# ----- Abfragen -----------------------------------------------------------
echo "=========================================================="
echo "  Webstack-Setup – Bootstrap-Skript v2"
echo "=========================================================="
echo
DOMAIN=$(ask "Domain (z.B. meineseite.de)")
[[ -n "$DOMAIN" ]] || fail "Domain ist Pflicht."
EMAIL=$(ask "E-Mail für Let's Encrypt")
[[ -n "$EMAIL" ]] || fail "E-Mail ist Pflicht."
APP_PORT=$(ask "Interner Port der App (Next.js)" "3000")
INCLUDE_WWW=$(ask "Auch www.$DOMAIN absichern? (y/n)" "y")

echo
info "Optionale Härtung:"
CREATE_USER=$(ask "Neuen Sudo-User anlegen? (y/n)" "n")

NEW_USER=""
USER_PASS=""
PUBKEY=""
if [[ "$CREATE_USER" == "y" ]]; then
    NEW_USER=$(ask "Name des neuen Sudo-Users" "deploy")
    USER_PASS=$(ask_pw "Passwort für $NEW_USER (für sudo)")
    while [[ -z "$PUBKEY" ]]; do
        echo
        warn "Füge jetzt deinen SSH-Public-Key ein (eine Zeile, ssh-ed25519/ssh-rsa)."
        warn "Nur dieser Key kann sich nachher als $NEW_USER einloggen."
        read -rp "> " PUBKEY
        [[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-) ]] || { warn "Sieht nicht nach einem Public-Key aus. Nochmal."; PUBKEY=""; }
    done
fi

CHANGE_SSH_PORT=$(ask "SSH-Port ändern? (y/n)" "n")
SSH_PORT="22"
if [[ "$CHANGE_SSH_PORT" == "y" ]]; then
    SSH_PORT=$(ask "Neuer SSH-Port" "2222")
fi

echo
info "Zusammenfassung:"
echo "  Domain:          $DOMAIN $([[ $INCLUDE_WWW == y ]] && echo "+ www.$DOMAIN")"
echo "  E-Mail:          $EMAIL"
echo "  App-Port:        $APP_PORT"
echo "  Neuer User:      ${NEW_USER:-(keiner – root bleibt aktiv)}"
echo "  SSH-Port:        $SSH_PORT $([[ $CHANGE_SSH_PORT == n ]] && echo "(unverändert)")"
echo
CONFIRM=$(ask "Mit Setup fortfahren? (y/n)" "y")
[[ "$CONFIRM" == "y" ]] || fail "Abgebrochen."

# ----- 1. System aktualisieren -------------------------------------------
info "System-Pakete aktualisieren..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git ufw fail2ban unattended-upgrades \
    apt-listchanges ca-certificates gnupg lsb-release software-properties-common
ok "System aktuell."

# ----- 2. Sudo-User anlegen (optional) -----------------------------------
if [[ "$CREATE_USER" == "y" ]]; then
    if id "$NEW_USER" &>/dev/null; then
        warn "User $NEW_USER existiert bereits – wird übersprungen."
    else
        info "Lege User $NEW_USER an..."
        adduser --disabled-password --gecos "" "$NEW_USER"
        echo "$NEW_USER:$USER_PASS" | chpasswd
        usermod -aG sudo "$NEW_USER"
        ok "User $NEW_USER erstellt, Passwort gesetzt, in Sudo-Gruppe."
    fi

    info "SSH-Key für $NEW_USER hinterlegen..."
    mkdir -p "/home/$NEW_USER/.ssh"
    echo "$PUBKEY" > "/home/$NEW_USER/.ssh/authorized_keys"
    chmod 700 "/home/$NEW_USER/.ssh"
    chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"
    chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
    ok "SSH-Key hinterlegt."
fi

# ----- 3. SSH absichern --------------------------------------------------
info "SSH härten..."
SSHD=/etc/ssh/sshd_config.d/99-hardening.conf
{
    echo "Port $SSH_PORT"
    echo "PermitRootLogin prohibit-password"   # Key-Login bleibt erlaubt
    echo "PasswordAuthentication no"
    echo "PubkeyAuthentication yes"
    echo "KbdInteractiveAuthentication no"
    echo "ChallengeResponseAuthentication no"
    echo "UsePAM yes"
    echo "X11Forwarding no"
    echo "MaxAuthTries 3"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
    if [[ "$CREATE_USER" == "y" ]]; then
        echo "AllowUsers $NEW_USER root"
    fi
} > "$SSHD"

sshd -t || fail "Fehler in SSH-Config!"
systemctl restart ssh || systemctl restart sshd
ok "SSH abgesichert (Port $SSH_PORT, nur Key-Auth)."

# ----- 4. Firewall -------------------------------------------------------
info "UFW-Firewall einrichten..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
ufw allow 80/tcp  comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ok "Firewall aktiv: nur $SSH_PORT, 80, 443 offen."

# ----- 5. Fail2Ban -------------------------------------------------------
info "Fail2Ban konfigurieren..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $SSH_PORT
maxretry = 3
bantime  = 24h

[nginx-http-auth]
enabled = true

[nginx-bad-request]
enabled = true
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban
ok "Fail2Ban läuft."

# ----- 6. Unattended-Upgrades -------------------------------------------
info "Automatische Sicherheits-Updates aktivieren..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/51unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
ok "Unattended-Upgrades aktiviert."

# ----- 7. Kernel-Hardening ----------------------------------------------
info "Kernel-Parameter härten..."
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
EOF
sysctl --system >/dev/null
ok "Kernel gehärtet."

# ----- 8. Docker installieren --------------------------------------------
info "Docker installieren..."
if ! command -v docker &>/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
fi
if [[ "$CREATE_USER" == "y" ]]; then
    usermod -aG docker "$NEW_USER"
    ok "Docker installiert (User $NEW_USER kann es ohne sudo nutzen)."
else
    ok "Docker installiert."
fi

# ----- 9. Nginx + Certbot -----------------------------------------------
info "Nginx und Certbot installieren..."
apt-get install -y -qq nginx
apt-get install -y -qq certbot python3-certbot-nginx
systemctl enable --now nginx
ok "Nginx + Certbot installiert."

# ----- 10. Nginx-Konfiguration -------------------------------------------
info "Nginx-Site für $DOMAIN anlegen..."
SERVER_NAMES="$DOMAIN"
[[ "$INCLUDE_WWW" == "y" ]] && SERVER_NAMES="$DOMAIN www.$DOMAIN"

cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAMES;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 60s;
    }
}
EOF
ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN"
rm -f /etc/nginx/sites-enabled/default
nginx -t || fail "Nginx-Config fehlerhaft!"
systemctl reload nginx
ok "Nginx konfiguriert."

# ----- 11. Let's Encrypt -------------------------------------------------
info "TLS-Zertifikat von Let's Encrypt holen..."
CERTBOT_DOMAINS="-d $DOMAIN"
[[ "$INCLUDE_WWW" == "y" ]] && CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d www.$DOMAIN"

if certbot --nginx --non-interactive --agree-tos --redirect \
       --email "$EMAIL" $CERTBOT_DOMAINS; then
    ok "TLS aktiv – HTTPS funktioniert."
else
    warn "Certbot fehlgeschlagen. Häufigste Ursache: DNS zeigt noch nicht auf diesen Server."
    warn "Sobald DNS passt, ausführen:  certbot --nginx $CERTBOT_DOMAINS"
fi

systemctl enable --now certbot.timer
ok "Auto-Renewal aktiv."

# ----- 12. Security-Header -----------------------------------------------
info "Security-Header in Nginx ergänzen..."
cat > /etc/nginx/conf.d/security-headers.conf <<'EOF'
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
server_tokens off;
EOF
nginx -t && systemctl reload nginx
ok "Security-Header aktiv."

# ----- 13. App-Verzeichnis anlegen ---------------------------------------
if [[ "$CREATE_USER" == "y" ]]; then
    APP_DIR="/home/$NEW_USER/app"
else
    APP_DIR="/root/app"
fi
info "App-Verzeichnis $APP_DIR anlegen..."
mkdir -p "$APP_DIR"
[[ "$CREATE_USER" == "y" ]] && chown -R "$NEW_USER:$NEW_USER" "$APP_DIR"
ok "Bereit für deine App."

# ----- Zusammenfassung ---------------------------------------------------
echo
echo "=========================================================="
ok "Setup abgeschlossen!"
echo "=========================================================="
echo
echo "Nächste Schritte:"
if [[ "$CREATE_USER" == "y" ]]; then
    echo "  1. Login testen:   ssh -p $SSH_PORT $NEW_USER@<server-ip>"
    echo "     (Sudo-Passwort: das eben gesetzte)"
else
    echo "  1. Login bleibt:   ssh -p $SSH_PORT root@<server-ip>"
fi
echo "  2. App deployen nach $APP_DIR"
echo "  3. https://$DOMAIN im Browser öffnen"
echo
if [[ "$CREATE_USER" == "y" ]]; then
    warn "WICHTIG: Aktuelle SSH-Session offen lassen, bis du dich mit dem"
    warn "neuen User+Port erfolgreich neu eingeloggt hast – sonst Lockout!"
fi
echo
