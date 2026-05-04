#!/usr/bin/env bash
# ============================================================
#  UPS Monitor — Vérification et installation des dépendances
#  Usage : sudo bash check_install.sh
#  Compatible : XenServer / XCP-ng (CentOS 7) et Ubuntu/Debian
# ============================================================

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$APP_DIR/venv"
REQ_FILE="$APP_DIR/requirements.txt"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=8

# Couleurs
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
fail() { echo -e "  ${RED}✘${RESET}  $*"; }
info() { echo -e "  ${CYAN}→${RESET}  $*"; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║     UPS Monitor — Vérification système       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""

ERRORS=0
PLATFORM="unknown"  # xenserver | ubuntu | debian | centos | unknown

# ─────────────────────────────────────────────
# 1. Détection OS + gestionnaire de paquets
# ─────────────────────────────────────────────
echo -e "${BOLD}[1/8] Système d'exploitation${RESET}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-unknown}"
    OS_ID="${ID:-unknown}"
else
    OS_NAME="Inconnu"
    OS_ID="unknown"
fi

# Détection précise de XenServer / XCP-ng
if [ -f /etc/xensource-inventory ] || grep -qi "xenserver\|xcp-ng" /etc/os-release 2>/dev/null; then
    PLATFORM="xenserver"
elif [[ "$OS_ID" == "ubuntu" ]]; then
    PLATFORM="ubuntu"
elif [[ "$OS_ID" == "debian" ]]; then
    PLATFORM="debian"
elif [[ "$OS_ID" == "centos" ]] || [[ "$OS_ID" == "rhel" ]]; then
    PLATFORM="centos"
fi

if command -v yum &>/dev/null && ! command -v apt-get &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
else
    PKG_MGR="unknown"
fi

ok "OS détecté : $OS_NAME"
ok "Gestionnaire de paquets : $PKG_MGR"

# Note spécifique à la plateforme
if [ "$PLATFORM" = "xenserver" ]; then
    echo -e "  ${CYAN}ℹ${RESET}  Plateforme : XenServer/XCP-ng (dom0 CentOS) — mode XenServer activé"
    echo -e "  ${CYAN}ℹ${RESET}  Le script utilisera yum + dépôt IUS pour Python 3.8"
elif [ "$PLATFORM" = "ubuntu" ] || [ "$PLATFORM" = "debian" ]; then
    echo -e "  ${CYAN}ℹ${RESET}  Plateforme : ${OS_NAME} — mode Linux standard"
    echo -e "  ${CYAN}ℹ${RESET}  Le script utilisera apt pour les dépendances système"
else
    warn "Plateforme non reconnue — le script va tenter de continuer"
fi

echo ""

# ─────────────────────────────────────────────
# 2. Python 3.8+
# ─────────────────────────────────────────────
echo -e "${BOLD}[2/8] Python $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR+${RESET}"

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
    if command -v "$candidate" &>/dev/null; then
        version=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "0.0")
        major=$(echo "$version" | cut -d. -f1)
        minor=$(echo "$version" | cut -d. -f2)
        if [ "$major" -ge "$MIN_PYTHON_MAJOR" ] && [ "$minor" -ge "$MIN_PYTHON_MINOR" ]; then
            PYTHON_BIN="$candidate"
            ok "Python trouvé : $candidate ($version)"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    fail "Python $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR+ introuvable !"
    echo ""
    warn "Installation automatique de Python..."
    if [ "$PKG_MGR" = "yum" ]; then
        info "XenServer/CentOS 7 : ajout du dépôt IUS pour Python 3.8..."
        yum install -y -q epel-release 2>/dev/null || true
        if ! yum install -y -q https://repo.ius.io/ius-release-el7.rpm 2>/dev/null; then
            warn "Dépôt IUS indisponible — essai direct..."
        fi
        yum install -y python38 python38-pip python38-devel
        PYTHON_BIN="python3.8"
    elif [ "$PKG_MGR" = "apt" ]; then
        apt-get update -q
        apt-get install -y -q python3 python3-pip python3-venv python3-dev ca-certificates
        update-ca-certificates
        PYTHON_BIN="python3"
    else
        fail "Impossible d'installer Python automatiquement."
        fail "Installez Python 3.8+ manuellement puis relancez ce script."
        exit 1
    fi
    ok "Python installé : $PYTHON_BIN ($($PYTHON_BIN --version 2>&1))"
fi
echo ""

# ─────────────────────────────────────────────
# 3. Module venv
# ─────────────────────────────────────────────
echo -e "${BOLD}[3/8] Module venv (environnement virtuel)${RESET}"

if [ "$PKG_MGR" = "apt" ]; then
    PY_VERSION=$("$PYTHON_BIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    FULL_PKG="python${PY_VERSION}-full"
    VENV_PKG="python${PY_VERSION}-venv"

    if dpkg -l "$FULL_PKG" &>/dev/null 2>&1; then
        ok "Paquet $FULL_PKG déjà installé"
    else
        info "Installation de $FULL_PKG (venv + ensurepip complet)..."
        apt-get update -q
        if apt-get install -y -q "$FULL_PKG" 2>/dev/null; then
            ok "Paquet $FULL_PKG installé"
        else
            info "$FULL_PKG indisponible, fallback sur $VENV_PKG + python3-pip..."
            apt-get install -y -q "$VENV_PKG" python3-pip python3-setuptools
            ok "Paquets $VENV_PKG + python3-pip installés"
        fi
    fi
elif [ "$PKG_MGR" = "yum" ]; then
    if ! "$PYTHON_BIN" -m venv --help &>/dev/null 2>&1; then
        warn "Module venv manquant — installation..."
        yum install -y python38-libs 2>/dev/null || true
    fi
    ok "Module venv disponible (inclus avec Python 3.8 sur CentOS)"
fi
echo ""

# ─────────────────────────────────────────────
# 4. Environnement virtuel Python
# ─────────────────────────────────────────────
echo -e "${BOLD}[4/8] Environnement virtuel${RESET}"

PIP="$VENV_DIR/bin/pip"
PYTHON_VENV="$VENV_DIR/bin/python"

# Détecte un venv cassé (répertoire présent mais pip absent)
if [ -d "$VENV_DIR" ] && [ ! -f "$PIP" ]; then
    warn "Venv existant mais cassé (pip absent) — reconstruction..."
    rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    info "Création du virtualenv dans $VENV_DIR..."

    # Tentative 1 : création normale
    if "$PYTHON_BIN" -m venv "$VENV_DIR" 2>/dev/null && [ -f "$PIP" ]; then
        ok "Virtualenv créé"
    else
        # Tentative 2 : bootstrap pip via get-pip.py
        warn "ensurepip indisponible — bootstrap pip manuel..."
        rm -rf "$VENV_DIR"
        "$PYTHON_BIN" -m venv --without-pip "$VENV_DIR"

        if command -v curl &>/dev/null; then
            curl -sSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        elif command -v wget &>/dev/null; then
            wget -qO /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
        else
            fail "curl et wget introuvables. Impossible de bootstrapper pip."
            if [ "$PKG_MGR" = "apt" ]; then
                fail "Installez curl : apt-get install curl  puis relancez."
            else
                fail "Installez curl : yum install curl  puis relancez."
            fi
            exit 1
        fi

        "$VENV_DIR/bin/python" /tmp/get-pip.py --quiet
        rm -f /tmp/get-pip.py

        if [ ! -f "$PIP" ]; then
            fail "Échec du bootstrap pip. Vérifiez votre connexion internet."
            exit 1
        fi
        ok "Virtualenv créé (pip bootstrappé manuellement)"
    fi
else
    ok "Virtualenv existant : $VENV_DIR"
fi

# ── Vérification SSL ──────────────────────────────────────────────────────────
PIP_FLAGS=""

info "Test de la connectivité SSL vers PyPI..."
SSL_OK=true
SSL_TEST=$("$PYTHON_VENV" -c \
    "import urllib.request; urllib.request.urlopen('https://pypi.org/simple/', timeout=10)" \
    2>&1) || SSL_OK=false

if $SSL_OK; then
    ok "SSL PyPI accessible — certificats OK"
else
    warn "SSL inaccessible — écriture d'un pip.conf avec trusted-host"
    PIP_FLAGS="--trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org"

    PIP_CONF_DIR="$VENV_DIR/etc/pip"
    mkdir -p "$PIP_CONF_DIR"
    cat > "$PIP_CONF_DIR/pip.conf" << 'PIPCONF'
[global]
trusted-host =
    pypi.org
    pypi.python.org
    files.pythonhosted.org
PIPCONF
    ok "pip.conf écrit : $PIP_CONF_DIR/pip.conf"
    export PIP_TRUSTED_HOST="pypi.org pypi.python.org files.pythonhosted.org"
fi

info "Mise à jour de pip..."
# shellcheck disable=SC2086
"$PIP" install --quiet --upgrade pip $PIP_FLAGS 2>/dev/null || true
ok "pip $($PIP --version | awk '{print $2}')"
echo ""

# ─────────────────────────────────────────────
# 5. Paquets Python (requirements.txt)
# ─────────────────────────────────────────────
echo -e "${BOLD}[5/8] Paquets Python (requirements.txt)${RESET}"

if [ ! -f "$REQ_FILE" ]; then
    fail "requirements.txt introuvable dans $APP_DIR"
    exit 1
fi

INSTALLED=$("$PIP" list --format=freeze 2>/dev/null | tr '[:upper:]' '[:lower:]')
MISSING=()

while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "${line// }" ]] && continue

    # Supprime les extras [standard] et les spécificateurs de version >=...
    pkg_name=$(echo "$line" | sed 's/[><=!~].*//' | sed 's/\[.*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    if echo "$INSTALLED" | grep -qi "^${pkg_name}"; then
        installed_ver=$(echo "$INSTALLED" | grep -i "^${pkg_name}" | head -1 | cut -d= -f3)
        ok "$pkg_name ($installed_ver)"
    else
        fail "$pkg_name → NON INSTALLÉ"
        MISSING+=("$line")
    fi
done < "$REQ_FILE"

echo ""

if [ ${#MISSING[@]} -gt 0 ]; then
    warn "${#MISSING[@]} paquet(s) manquant(s) — installation en cours..."
    echo ""
    # shellcheck disable=SC2086
    "$PIP" install $PIP_FLAGS "${MISSING[@]}"
    echo ""

    for pkg in "${MISSING[@]}"; do
        pkg_name=$(echo "$pkg" | sed 's/[><=!~].*//' | sed 's/\[.*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        if "$PIP" list --format=freeze 2>/dev/null | grep -qi "^${pkg_name}"; then
            ok "$pkg_name → installé avec succès"
        else
            fail "$pkg_name → échec de l'installation !"
            ERRORS=$((ERRORS + 1))
        fi
    done
else
    ok "Tous les paquets sont installés"
fi
echo ""

# ─────────────────────────────────────────────
# 6. Outils SSH (pour arrêt des VMs XenServer)
# ─────────────────────────────────────────────
echo -e "${BOLD}[6/8] Outils SSH (arrêt automatique des VMs)${RESET}"

SSH_MISSING=()
SSHPASS_MISSING=()

# Noms de paquets différents entre apt et yum
if [ "$PKG_MGR" = "apt" ]; then
    SSH_PKG="openssh-client"
    SSHPASS_PKG="sshpass"
elif [ "$PKG_MGR" = "yum" ]; then
    SSH_PKG="openssh-clients"   # note le 's' sur CentOS/XenServer
    SSHPASS_PKG="sshpass"       # disponible via EPEL (installé à l'étape 2)
else
    SSH_PKG="openssh-client"
    SSHPASS_PKG="sshpass"
fi

if command -v ssh &>/dev/null; then
    ok "ssh disponible ($(ssh -V 2>&1 | head -1))"
else
    warn "ssh introuvable — installation de $SSH_PKG..."
    if [ "$PKG_MGR" = "apt" ]; then
        apt-get install -y -q "$SSH_PKG"
    elif [ "$PKG_MGR" = "yum" ]; then
        yum install -y -q "$SSH_PKG"
    fi
    ok "ssh installé"
fi

if command -v sshpass &>/dev/null; then
    ok "sshpass disponible"
else
    info "sshpass non installé — installation de $SSHPASS_PKG..."
    INSTALL_OK=true
    if [ "$PKG_MGR" = "apt" ]; then
        apt-get install -y -q "$SSHPASS_PKG" 2>/dev/null || INSTALL_OK=false
    elif [ "$PKG_MGR" = "yum" ]; then
        # sshpass est dans EPEL (déjà activé à l'étape 2 si Python installé)
        yum install -y -q "$SSHPASS_PKG" 2>/dev/null || INSTALL_OK=false
    fi
    if $INSTALL_OK && command -v sshpass &>/dev/null; then
        ok "sshpass installé"
    else
        warn "sshpass non disponible — l'arrêt des VMs via mot de passe SSH ne fonctionnera pas"
        warn "Alternative : configurez une clé SSH sans mot de passe entre ce serveur et XenServer"
    fi
fi

if [ "$PLATFORM" = "xenserver" ]; then
    echo -e "  ${CYAN}ℹ${RESET}  Sur XenServer dom0 : XENSERVER_HOST peut être 127.0.0.1 (machine locale)"
    echo -e "  ${CYAN}ℹ${RESET}  Commande xe disponible localement — SSH vers soi-même nécessite une clé SSH"
    echo -e "  ${CYAN}ℹ${RESET}  Pour activer : ssh-keygen -t rsa && cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys"
else
    echo -e "  ${CYAN}ℹ${RESET}  Sur Ubuntu : XENSERVER_HOST = IP de votre serveur XenServer distant"
    echo -e "  ${CYAN}ℹ${RESET}  L'application se connectera en SSH pour arrêter les VMs"
fi
echo ""

# ─────────────────────────────────────────────
# 7. Fichier .env
# ─────────────────────────────────────────────
echo -e "${BOLD}[7/8] Configuration (.env)${RESET}"

if [ -f "$APP_DIR/.env" ]; then
    ok ".env trouvé : $APP_DIR/.env"

    check_var() {
        local var="$1"
        local val
        val=$(grep -E "^${var}=" "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
        if [ -z "$val" ] || [[ "$val" == *"CHANGEZ"* ]] || [[ "$val" == *"CHANGEME"* ]]; then
            warn "$var non configuré — à renseigner !"
            return 1
        fi
        ok "$var configuré"
    }

    check_var "UPS_HOST"       || ERRORS=$((ERRORS + 1))
    check_var "SNMP_USER"      || ERRORS=$((ERRORS + 1))
    check_var "SNMP_AUTH_KEY"  || ERRORS=$((ERRORS + 1))
    check_var "SNMP_PRIV_KEY"  || ERRORS=$((ERRORS + 1))
    check_var "SECRET_KEY"     || ERRORS=$((ERRORS + 1))
    check_var "ADMIN_PASSWORD" || ERRORS=$((ERRORS + 1))

    # Info sur les variables optionnelles XenServer
    XHOST=$(grep -E "^XENSERVER_HOST=" "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" | xargs)
    if [ -z "$XHOST" ]; then
        info "XENSERVER_HOST non configuré — arrêt automatique des VMs désactivé"
    else
        ok "XENSERVER_HOST configuré ($XHOST) — arrêt automatique des VMs activé"
    fi
else
    warn ".env manquant — création depuis le template..."
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    warn "Editez $APP_DIR/.env avant de démarrer l'application !"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ─────────────────────────────────────────────
# 8. Service systemd
# ─────────────────────────────────────────────
echo -e "${BOLD}[8/8] Service systemd${RESET}"

SYSTEMD_DEST="/etc/systemd/system/ups-monitor.service"

if ! command -v systemctl &>/dev/null; then
    warn "systemctl introuvable — service non installé"
    warn "Lancez manuellement : $VENV_DIR/bin/uvicorn app.main:app --host 0.0.0.0 --port 8080"
else
    cat > "$SYSTEMD_DEST" << EOF
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
    systemctl enable ups-monitor 2>/dev/null || true
    ok "Service installé : $SYSTEMD_DEST"
    ok "Service activé au démarrage"

    if [ "$PLATFORM" = "xenserver" ]; then
        echo -e "  ${CYAN}ℹ${RESET}  Sur XenServer : le service démarre automatiquement avec dom0"
    fi
fi
echo ""

# ─────────────────────────────────────────────
# Résumé final
# ─────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ✔  Tout est en ordre — prêt à démarrer !${RESET}"
    echo ""
    echo -e "  Plateforme  : ${CYAN}${OS_NAME}${RESET}"
    echo -e "  Démarrer    :  ${CYAN}systemctl start ups-monitor${RESET}"
    echo -e "  Statut      :  ${CYAN}systemctl status ups-monitor${RESET}"
    echo -e "  Logs        :  ${CYAN}journalctl -u ups-monitor -f${RESET}"
    echo -e "  Web         :  ${CYAN}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP_SERVEUR'):8080${RESET}"
else
    echo -e "${YELLOW}${BOLD}  ⚠  $ERRORS problème(s) à corriger avant le démarrage${RESET}"
    echo ""
    if grep -q "SECRET_KEY non configuré\|ADMIN_PASSWORD non configuré" <<< "$(grep -E "^(SECRET_KEY|ADMIN_PASSWORD)=" "$APP_DIR/.env" 2>/dev/null || echo '')"; then
        true
    fi
    echo -e "  Générer une SECRET_KEY :"
    echo -e "    ${CYAN}python3 -c \"import secrets; print(secrets.token_hex(32))\"${RESET}"
    echo ""
    echo -e "  Editer la configuration :"
    echo -e "    ${CYAN}nano $APP_DIR/.env${RESET}"
    echo ""
    echo -e "  Relancer ce script : ${CYAN}sudo bash check_install.sh${RESET}"
fi
echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
echo ""
