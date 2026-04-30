#!/usr/bin/env bash
# ============================================================
# Script de déploiement UPS Monitor sur VM Debian/Ubuntu
# Usage : sudo bash deploy.sh
# ============================================================
set -euo pipefail

APP_DIR="/opt/ups-monitor"
APP_USER="upsmonitor"
SERVICE="ups-monitor"
PYTHON="python3"

echo "=== UPS Monitor — Déploiement ==="

# 1. Dépendances système
echo "[1/6] Installation des dépendances système..."
apt-get update -q
apt-get install -y -q python3 python3-venv python3-pip openssh-client sshpass

# 2. Utilisateur dédié
echo "[2/6] Création de l'utilisateur système..."
id "$APP_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"

# 3. Copie des fichiers
echo "[3/6] Déploiement des fichiers dans $APP_DIR..."
mkdir -p "$APP_DIR"
rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='venv' --exclude='.env' --exclude='*.db' \
  "$(dirname "$0")/" "$APP_DIR/"

# 4. Environnement virtuel Python
echo "[4/6] Création de l'environnement Python..."
if [ ! -d "$APP_DIR/venv" ]; then
  "$PYTHON" -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

# 5. Fichier .env
if [ ! -f "$APP_DIR/.env" ]; then
  echo "[5/6] Création du fichier .env depuis le template..."
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
  echo ""
  echo "  ⚠️  Editez $APP_DIR/.env avec vos paramètres !"
  echo "  Minimum requis :"
  echo "    UPS_HOST       = IP de l'onduleur"
  echo "    SNMP_USER      = Nom d'utilisateur SNMPv3"
  echo "    SNMP_AUTH_KEY  = Clé d'authentification"
  echo "    SNMP_PRIV_KEY  = Clé de chiffrement"
  echo "    SECRET_KEY     = Clé secrète JWT (random)"
  echo "    ADMIN_PASSWORD = Mot de passe interface web"
  echo ""
else
  echo "[5/6] Fichier .env existant conservé."
fi

# 6. Service systemd
echo "[6/6] Installation et activation du service systemd..."
cp "$APP_DIR/ups-monitor.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable "$SERVICE"

# Permissions
chown -R "$APP_USER:$APP_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env" 2>/dev/null || true

echo ""
echo "=== Déploiement terminé ! ==="
echo ""
echo "Prochaines étapes :"
echo "  1. Editez /opt/ups-monitor/.env avec vos paramètres"
echo "  2. sudo systemctl start $SERVICE"
echo "  3. sudo systemctl status $SERVICE"
echo "  4. Accédez à http://$(hostname -I | awk '{print $1}'):8080"
echo ""
