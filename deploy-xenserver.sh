#!/usr/bin/env bash
# ============================================================
# UPS Monitor — Déploiement complet (première installation)
# Supporte : XenServer / XCP-ng (CentOS 7)  ET  Ubuntu/Debian
# Usage : sudo bash deploy-xenserver.sh
# ============================================================
set -euo pipefail

APP_DIR="/opt/ups-monitor"
SERVICE="ups-monitor"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     UPS Monitor — Déploiement complet        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ─── Détection plateforme ────────────────────────────────────────────────────
OS_ID="unknown"
OS_NAME="Inconnu"
[ -f /etc/os-release ] && . /etc/os-release && OS_ID="${ID:-unknown}" && OS_NAME="${NAME:-Inconnu}"

if command -v yum &>/dev/null && ! command -v apt-get &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
else
    echo "ERREUR : aucun gestionnaire de paquets (apt/yum) trouvé."
    exit 1
fi

# Détecte XenServer / XCP-ng
IS_XENSERVER=false
[ -f /etc/xensource-inventory ] && IS_XENSERVER=true
grep -qi "xenserver\|xcp-ng" /etc/os-release 2>/dev/null && IS_XENSERVER=true

echo "  OS          : $OS_NAME"
echo "  Paquets     : $PKG_MGR"
if $IS_XENSERVER; then
    echo "  Plateforme  : XenServer / XCP-ng (dom0)"
else
    echo "  Plateforme  : Linux standard (Ubuntu/Debian/CentOS)"
fi
echo ""

# ─── 1. Git ──────────────────────────────────────────────────────────────────
echo "[1/6] Installation de git..."
if command -v git &>/dev/null; then
    echo "  ✔  git déjà installé ($(git --version))"
else
    if [ "$PKG_MGR" = "yum" ]; then
        yum install -y -q git
    else
        apt-get update -q && apt-get install -y -q git
    fi
    echo "  ✔  git installé"
fi

# ─── 2. Python 3.8+ ──────────────────────────────────────────────────────────
echo "[2/6] Python 3.8+..."

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
    if command -v "$candidate" &>/dev/null; then
        version=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        major=$(echo "$version" | cut -d. -f1)
        minor=$(echo "$version" | cut -d. -f2)
        if [ "$major" -ge 3 ] && [ "$minor" -ge 8 ]; then
            PYTHON_BIN="$candidate"
            echo "  ✔  Python trouvé : $candidate ($version)"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    if [ "$PKG_MGR" = "yum" ]; then
        echo "  →  XenServer/CentOS 7 : ajout du dépôt IUS pour Python 3.8..."
        yum install -y -q epel-release 2>/dev/null || true
        yum install -y -q https://repo.ius.io/ius-release-el7.rpm 2>/dev/null || true
        yum install -y python38 python38-pip python38-devel
        PYTHON_BIN="python3.8"
    else
        echo "  →  Ubuntu/Debian : installation de python3..."
        apt-get update -q
        apt-get install -y -q python3 python3-pip python3-venv python3-dev ca-certificates
        update-ca-certificates
        PYTHON_BIN="python3"
    fi
    echo "  ✔  Python installé : $PYTHON_BIN"
fi

# ─── 3. Outils SSH (pour le shutdown des VMs XenServer) ──────────────────────
echo "[3/6] Outils SSH..."

if [ "$PKG_MGR" = "yum" ]; then
    # CentOS/XenServer : paquet s'appelle openssh-clients (avec 's')
    yum install -y -q openssh-clients sshpass 2>/dev/null || \
        yum install -y -q openssh-clients && echo "  ⚠  sshpass non disponible (EPEL requis)"
    echo "  ✔  openssh-clients + sshpass (CentOS/XenServer)"
else
    # Ubuntu/Debian : paquet s'appelle openssh-client (sans 's')
    apt-get install -y -q openssh-client sshpass
    echo "  ✔  openssh-client + sshpass (Ubuntu/Debian)"
fi

if $IS_XENSERVER; then
    echo "  ℹ  XenServer dom0 : la commande 'xe' est disponible localement."
    echo "     Si XENSERVER_HOST=127.0.0.1, configurez une clé SSH sans mot de passe :"
    echo "     ssh-keygen -t rsa -N '' && cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
fi

# ─── 4. Dossier app + clonage si besoin ──────────────────────────────────────
echo "[4/6] Application dans $APP_DIR..."
mkdir -p "$APP_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SCRIPT_DIR" != "$APP_DIR" ]; then
    echo "  →  Copie des fichiers vers $APP_DIR..."
    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
      --exclude='venv' --exclude='.env' --exclude='*.db' \
      "$SCRIPT_DIR/." "$APP_DIR/"
    echo "  ✔  Fichiers copiés"
else
    echo "  ✔  Déjà dans $APP_DIR"
fi

# ─── 5. Virtualenv Python ────────────────────────────────────────────────────
echo "[5/6] Environnement Python..."

# Sur Ubuntu, s'assurer que python3.X-full est installé
if [ "$PKG_MGR" = "apt" ]; then
    PY_VERSION=$("$PYTHON_BIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    FULL_PKG="python${PY_VERSION}-full"
    if ! dpkg -l "$FULL_PKG" &>/dev/null 2>&1; then
        apt-get install -y -q "$FULL_PKG" 2>/dev/null || \
            apt-get install -y -q "python${PY_VERSION}-venv" python3-pip
    fi
fi

if [ ! -d "$APP_DIR/venv" ]; then
    "$PYTHON_BIN" -m venv "$APP_DIR/venv"
    echo "  ✔  Virtualenv créé"
fi

"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
echo "  ✔  Dépendances Python installées"

# ─── 6. Fichier .env + service systemd ───────────────────────────────────────
echo "[6/6] Configuration finale..."

if [ ! -f "$APP_DIR/.env" ]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    echo ""
    echo "  ⚠  IMPORTANT : Editez $APP_DIR/.env avant de démarrer !"
    echo ""
fi

# Service systemd
cat > /etc/systemd/system/ups-monitor.service << EOF
[Unit]
Description=UPS Monitor — Eaton 5PX 3000i RT2U G2
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8080 --workers 1 --log-level info
Restart=on-failure
RestartSec=10s
StartLimitInterval=60s
StartLimitBurst=3
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"
echo "  ✔  Service systemd installé et activé"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║           Déploiement terminé !              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Étapes suivantes :"
echo ""
echo "  1. Générer une SECRET_KEY :"
echo "     python3 -c \"import secrets; print(secrets.token_hex(32))\""
echo ""
echo "  2. Configurer l'application :"
echo "     nano $APP_DIR/.env"
echo "     Variables à renseigner :"
echo "       UPS_HOST        → IP de l'onduleur"
echo "       SNMP_USER       → utilisateur SNMPv3"
echo "       SNMP_AUTH_KEY   → clé d'authentification SHA"
echo "       SNMP_PRIV_KEY   → clé de chiffrement AES"
echo "       SECRET_KEY      → clé JWT (générée ci-dessus)"
echo "       ADMIN_PASSWORD  → mot de passe interface web"
echo ""
if $IS_XENSERVER; then
    echo "  3. (Optionnel) Pour l'arrêt automatique des VMs :"
    echo "     XENSERVER_HOST=127.0.0.1  (ce serveur XenServer)"
    echo "     Configurer la clé SSH : ssh-keygen -t rsa -N '' && \\"
    echo "       cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
else
    echo "  3. (Optionnel) Pour l'arrêt automatique des VMs XenServer :"
    echo "     XENSERVER_HOST=IP_XENSERVER"
    echo "     XENSERVER_PASSWORD=mot_de_passe_root"
fi
echo ""
echo "  4. Démarrer le service :"
echo "     systemctl start ups-monitor"
echo "     systemctl status ups-monitor"
echo ""
echo "  5. Interface web :"
echo "     http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP_SERVEUR'):8080"
echo ""
