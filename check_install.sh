#!/usr/bin/env bash
# ============================================================
#  UPS Monitor — Vérification et installation des dépendances
#  Usage : bash check_install.sh
#  Compatible : XenServer / XCP-ng (CentOS 7), Debian/Ubuntu
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

# ─────────────────────────────────────────────
# 1. Détection OS + gestionnaire de paquets
# ─────────────────────────────────────────────
echo -e "${BOLD}[1/6] Système d'exploitation${RESET}"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-unknown}"
    OS_ID="${ID:-unknown}"
else
    OS_NAME="Inconnu"
    OS_ID="unknown"
fi

if command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
else
    PKG_MGR="unknown"
fi

ok "OS détecté : $OS_NAME"
ok "Gestionnaire de paquets : $PKG_MGR"
echo ""

# ─────────────────────────────────────────────
# 2. Python 3.8+
# ─────────────────────────────────────────────
echo -e "${BOLD}[2/6] Python $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR+${RESET}"

PYTHON_BIN=""
for candidate in python3.11 python3.10 python3.9 python3.8 python3; do
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
    warn "Installation automatique de Python 3.8..."
    if [ "$PKG_MGR" = "yum" ]; then
        info "Ajout du dépôt IUS (Python 3.8 pour CentOS 7)..."
        yum install -y -q epel-release 2>/dev/null || true
        if ! yum install -y -q https://repo.ius.io/ius-release-el7.rpm 2>/dev/null; then
            warn "Dépôt IUS indisponible — essai avec epel..."
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
# 3. Module venv (avec paquet système si besoin)
# ─────────────────────────────────────────────
echo -e "${BOLD}[3/6] Module venv (environnement virtuel)${RESET}"

if [ "$PKG_MGR" = "apt" ]; then
    # Sur Ubuntu/Debian, python3.X-venv seul ne suffit pas toujours :
    # ensurepip peut être absent. python3.X-full ou python3-full est fiable.
    PY_VERSION=$("$PYTHON_BIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    FULL_PKG="python${PY_VERSION}-full"
    VENV_PKG="python${PY_VERSION}-venv"

    # Essaie python3.X-full en priorité (inclut venv + ensurepip)
    if dpkg -l "$FULL_PKG" &>/dev/null 2>&1; then
        ok "Paquet $FULL_PKG déjà installé"
    else
        info "Installation de $FULL_PKG (venv + ensurepip complet)..."
        apt-get update -q
        if apt-get install -y -q "$FULL_PKG" 2>/dev/null; then
            ok "Paquet $FULL_PKG installé"
        else
            # Fallback : python3.X-venv + python3-pip
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
    ok "Module venv disponible"
fi
echo ""

# ─────────────────────────────────────────────
# 4. Environnement virtuel Python
# ─────────────────────────────────────────────
echo -e "${BOLD}[4/6] Environnement virtuel${RESET}"

PIP="$VENV_DIR/bin/pip"
PYTHON_VENV="$VENV_DIR/bin/python"

# Détecte un venv cassé (répertoire présent mais pip absent)
if [ -d "$VENV_DIR" ] && [ ! -f "$PIP" ]; then
    warn "Venv existant mais cassé (pip absent) — reconstruction..."
    rm -rf "$VENV_DIR"
fi

if [ ! -d "$VENV_DIR" ]; then
    info "Création du virtualenv dans $VENV_DIR..."

    # Tentative 1 : création normale (avec pip intégré via ensurepip)
    if "$PYTHON_BIN" -m venv "$VENV_DIR" 2>/dev/null && [ -f "$PIP" ]; then
        ok "Virtualenv créé"

    # Tentative 2 : sans pip intégré, bootstrap manuel via get-pip.py
    else
        warn "ensurepip indisponible — bootstrap pip manuel..."
        rm -rf "$VENV_DIR"
        "$PYTHON_BIN" -m venv --without-pip "$VENV_DIR"

        if command -v curl &>/dev/null; then
            curl -sSL https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
        elif command -v wget &>/dev/null; then
            wget -qO /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
        else
            fail "curl et wget sont introuvables. Impossible de bootstrapper pip."
            fail "Installez curl : apt install curl  puis relancez ce script."
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

# ── Vérification SSL et configuration pip ──────────────────────────────────
# Test SSL réel : on essaie de joindre PyPI avec Python (même moteur que pip).
# Si ça échoue → on écrit un pip.conf avec trusted-host dans le venv.
PIP_FLAGS=""

info "Test de la connectivité SSL vers PyPI..."
SSL_OK=true
SSL_TEST=$("$PYTHON_VENV" -c \
    "import urllib.request, ssl; urllib.request.urlopen('https://pypi.org/simple/', timeout=10)" \
    2>&1) || SSL_OK=false

if $SSL_OK; then
    ok "SSL PyPI accessible — certificats OK"
else
    # Problème SSL (proxy inspection, CA manquant, bundle corrompu…)
    warn "SSL PyPI inaccessible — écriture d'un pip.conf avec trusted-host"
    PIP_FLAGS="--trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org"

    # Emplacement standard du pip.conf dans un venv
    PIP_CONF_DIR="$VENV_DIR/etc/pip"
    mkdir -p "$PIP_CONF_DIR"
    cat > "$PIP_CONF_DIR/pip.conf" << 'PIPCONF'
[global]
trusted-host =
    pypi.org
    pypi.python.org
    files.pythonhosted.org
PIPCONF
    ok "pip.conf écrit dans $PIP_CONF_DIR/pip.conf"

    # Variables d'environnement pour la session courante
    export PIP_TRUSTED_HOST="pypi.org pypi.python.org files.pythonhosted.org"
fi

# Mise à jour pip (silencieuse si déjà à jour)
info "Mise à jour de pip..."
# shellcheck disable=SC2086
"$PIP" install --quiet --upgrade pip $PIP_FLAGS 2>/dev/null || true
ok "pip $($PIP --version | awk '{print $2}')"
echo ""

# ─────────────────────────────────────────────
# 5. Vérification des paquets requirements.txt
# ─────────────────────────────────────────────
echo -e "${BOLD}[5/6] Paquets Python (requirements.txt)${RESET}"

if [ ! -f "$REQ_FILE" ]; then
    fail "requirements.txt introuvable dans $APP_DIR"
    exit 1
fi

# Liste les paquets installés dans le venv
INSTALLED=$("$PIP" list --format=freeze 2>/dev/null | tr '[:upper:]' '[:lower:]')

MISSING=()

while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "${line// }" ]] && continue

    # Extrait le nom du paquet (avant >=, <=, ==, ~=, >, <)
    pkg_name=$(echo "$line" | sed 's/[><=!~].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    if echo "$INSTALLED" | grep -qi "^${pkg_name}"; then
        installed_ver=$(echo "$INSTALLED" | grep -i "^${pkg_name}" | head -1 | cut -d= -f3)
        ok "$pkg_name ($installed_ver)"
    else
        fail "$pkg_name → NON INSTALLÉ"
        MISSING+=("$line")
    fi
done < "$REQ_FILE"

echo ""

# Installation des manquants
if [ ${#MISSING[@]} -gt 0 ]; then
    warn "${#MISSING[@]} paquet(s) manquant(s) — installation en cours..."
    echo ""
    # shellcheck disable=SC2086
    "$PIP" install $PIP_FLAGS "${MISSING[@]}"
    echo ""

    # Vérification post-install
    for pkg in "${MISSING[@]}"; do
        pkg_name=$(echo "$pkg" | sed 's/[><=!~].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
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
# 6. Fichier .env
# ─────────────────────────────────────────────
echo -e "${BOLD}[6/6] Configuration (.env)${RESET}"

if [ -f "$APP_DIR/.env" ]; then
    ok ".env trouvé : $APP_DIR/.env"

    # Vérifie les variables critiques
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
else
    warn ".env manquant — création depuis le template..."
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    warn "Editez $APP_DIR/.env avant de démarrer l'application !"
    ERRORS=$((ERRORS + 1))
fi
echo ""

# ─────────────────────────────────────────────
# Résumé final
# ─────────────────────────────────────────────
echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ✔  Tout est en ordre — prêt à démarrer !${RESET}"
    echo ""
    echo -e "  Démarrer :  ${CYAN}systemctl start ups-monitor${RESET}"
    echo -e "  Statut   :  ${CYAN}systemctl status ups-monitor${RESET}"
    echo -e "  Logs     :  ${CYAN}journalctl -u ups-monitor -f${RESET}"
    echo -e "  Web      :  ${CYAN}http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP_SERVEUR'):8080${RESET}"
else
    echo -e "${YELLOW}${BOLD}  ⚠  $ERRORS problème(s) à corriger avant le démarrage${RESET}"
    echo ""
    echo -e "  Relancez ce script après correction : ${CYAN}bash check_install.sh${RESET}"
fi
echo -e "${BOLD}══════════════════════════════════════════════${RESET}"
echo ""
