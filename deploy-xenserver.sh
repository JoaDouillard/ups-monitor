#!/usr/bin/env bash
# ============================================================
# Déploiement UPS Monitor sur XenServer / XCP-ng (dom0 CentOS 7)
# Usage : bash deploy-xenserver.sh
# ============================================================
set -euo pipefail

APP_DIR="/opt/ups-monitor"
APP_USER="upsmonitor"
SERVICE="ups-monitor"

echo "=== UPS Monitor — Déploiement XenServer ==="
echo ""

# 1. Git (pour les futurs pulls)
echo "[1/7] Installation de git..."
yum install -y -q git

# 2. Python 3.8 via IUS (dépôt tiers fiable pour CentOS 7)
echo "[2/7] Ajout du dépôt IUS et installation de Python 3.8..."
if ! python3.8 --version &>/dev/null; then
    yum install -y -q https://repo.ius.io/ius-release-el7.rpm epel-release
    yum install -y -q python38 python38-pip python38-devel
fi
echo "  Python : $(python3.8 --version)"

# 3. openssh-clients + sshpass (pour le shutdown XenServer local)
echo "[3/7] Installation des outils SSH..."
yum install -y -q openssh-clients sshpass

# 4. Utilisateur système dédié
echo "[4/7] Création de l'utilisateur système '$APP_USER'..."
id "$APP_USER" &>/dev/null || useradd --system --no-create-home --shell /sbin/nologin "$APP_USER"

# 5. Dossier app + virtualenv Python
echo "[5/7] Création de l'environnement Python dans $APP_DIR..."
mkdir -p "$APP_DIR"

# Copie les fichiers depuis le répertoire courant si pas encore fait
if [ ! -f "$APP_DIR/requirements.txt" ]; then
    echo "  Copie des fichiers de l'application..."
    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
      --exclude='venv' --exclude='.env' --exclude='*.db' \
      "$(dirname "$(readlink -f "$0")")/." "$APP_DIR/"
fi

# Virtualenv avec Python 3.8
if [ ! -d "$APP_DIR/venv" ]; then
    python3.8 -m venv "$APP_DIR/venv"
fi

echo "  Installation des dépendances Python..."
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

# 6. Fichier .env
echo "[6/7] Configuration..."
if [ ! -f "$APP_DIR/.env" ]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    echo ""
    echo "  ⚠️  IMPORTANT : Editez $APP_DIR/.env avant de démarrer !"
    echo "  nano /opt/ups-monitor/.env"
    echo ""
fi

# 7. Service systemd
echo "[7/7] Installation du service systemd..."

# Adapter le service pour utiliser notre venv Python 3.8
cat > /etc/systemd/system/ups-monitor.service << 'EOF'
[Unit]
Description=UPS Monitor — Eaton 5PX 3000i RT2U G2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=upsmonitor
Group=upsmonitor
WorkingDirectory=/opt/ups-monitor
EnvironmentFile=/opt/ups-monitor/.env
ExecStart=/opt/ups-monitor/venv/bin/uvicorn app.main:app \
    --host 0.0.0.0 \
    --port 8080 \
    --workers 1 \
    --log-level info
Restart=on-failure
RestartSec=10s
StartLimitInterval=60s
StartLimitBurst=3
NoNewPrivileges=true
PrivateTmp=true
ReadWritePaths=/opt/ups-monitor
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

# Permissions
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env" 2>/dev/null || true

systemctl daemon-reload
systemctl enable "$SERVICE"

echo ""
echo "============================================="
echo " Déploiement terminé !"
echo "============================================="
echo ""
echo " Prochaines étapes :"
echo "   1. nano /opt/ups-monitor/.env"
echo "      → UPS_HOST, SNMP_USER, SNMP_AUTH_KEY,"
echo "        SNMP_PRIV_KEY, SECRET_KEY, ADMIN_PASSWORD"
echo ""
echo "   2. systemctl start ups-monitor"
echo "   3. systemctl status ups-monitor"
echo "   4. journalctl -u ups-monitor -f"
echo ""
echo "   Interface web : http://$(hostname -I | awk '{print $1}'):8080"
echo ""
