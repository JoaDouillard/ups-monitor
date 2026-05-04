# UPS Monitor — Eaton 5PX 3000i RT2U G2

Application de monitoring temps réel d'onduleur via SNMPv3, avec dashboard web, historique, alertes et arrêt automatique des VMs XenServer.

---

## Ce que ça fait

- **Polling SNMP** toutes les N secondes (configurable) sur l'onduleur Eaton via SNMPv3 (auth SHA + chiffrement AES)
- **Dashboard web** temps réel avec authentification (login + JWT) accessible en local
- **Historique** graphique des mesures (batterie %, charge, tensions) sur 30 jours
- **Alertes** : log + email optionnel sur passage batterie, batterie faible, défaut, etc.
- **Shutdown automatique** : arrêt propre des VMs XenServer via SSH quand la batterie atteint le seuil critique
- **Service systemd** : démarre automatiquement avec le serveur, redémarre en cas de crash

---

## Matériel testé

| Composant | Modèle |
|---|---|
| Onduleur | Eaton 5PX 3000i RT2U G2 |
| Carte réseau | Eaton Network-M3 (firmware 2.1.2) |
| Hyperviseur | XenServer 8.1 / XCP-ng |

---

## Prérequis

| | XenServer / XCP-ng | Ubuntu / Debian |
|---|---|---|
| OS | dom0 CentOS 7 | Ubuntu 20.04+ / Debian 11+ |
| Accès | root | sudo ou root |
| Python | installé auto via dépôt IUS | installé auto via apt |
| SSH pour shutdown VMs | `openssh-clients` + `sshpass` (yum) | `openssh-client` + `sshpass` (apt) |

Prérequis communs :
- Accès root/sudo
- Connexion réseau vers l'onduleur
- SNMPv3 configuré sur la carte Eaton Network-M3
- Git installé

---

## Installation

> **Le script `check_install.sh` détecte automatiquement la plateforme (XenServer ou Ubuntu) et adapte toutes les commandes en conséquence. Un seul script pour les deux.**

### 1. Cloner le dépôt

```bash
git clone https://github.com/JoaDouillard/ups-monitor.git /opt/ups-monitor
cd /opt/ups-monitor
```

### 2. Installer toutes les dépendances

```bash
sudo bash check_install.sh
```

Ce script fait **tout automatiquement** selon la plateforme détectée :

| Étape | XenServer (CentOS 7 / yum) | Ubuntu/Debian (apt) |
|---|---|---|
| Python | `python3.8` via dépôt IUS | `python3` (déjà disponible) |
| venv | inclus avec python3.8 | `python3.X-full` |
| SSH shutdown | `openssh-clients` + `sshpass` | `openssh-client` + `sshpass` |
| Service | `/etc/systemd/system/ups-monitor.service` | idem |

### 3. Configurer l'application

```bash
# Générer une SECRET_KEY
python3 -c "import secrets; print(secrets.token_hex(32))"

# Editer la configuration
nano /opt/ups-monitor/.env
```

Variables **obligatoires** :

| Variable | Description | Exemple |
|---|---|---|
| `UPS_HOST` | Adresse IP de l'onduleur | `192.168.1.100` |
| `SNMP_USER` | Nom d'utilisateur SNMPv3 | `upsnms` |
| `SNMP_AUTH_KEY` | Clé d'authentification SHA | `MonMotDePasseAuth` |
| `SNMP_PRIV_KEY` | Clé de chiffrement AES | `MonMotDePassePriv` |
| `SECRET_KEY` | Clé secrète JWT (générée ci-dessus) | `a3f8c2...` |
| `ADMIN_PASSWORD` | Mot de passe de l'interface web | `UnBonMotDePasse` |

Variables **optionnelles** :

| Variable | Description | Défaut |
|---|---|---|
| `POLL_INTERVAL` | Intervalle de polling en secondes | `30` |
| `ADMIN_USERNAME` | Nom d'utilisateur web | `admin` |
| `SMTP_HOST` | Serveur email pour alertes | *(désactivé)* |
| `XENSERVER_HOST` | IP XenServer pour shutdown auto | *(désactivé)* |
| `XENSERVER_PASSWORD` | Mot de passe root XenServer | *(vide)* |
| `SHUTDOWN_DELAY_SECONDS` | Délai avant arrêt VMs | `60` |
| `HISTORY_RETENTION_DAYS` | Durée de rétention de l'historique | `30` |

> **Note XenServer dom0** : si `XENSERVER_HOST=127.0.0.1` (l'onduleur arrête la machine locale),
> configurez SSH sans mot de passe sur la machine elle-même :
> ```bash
> ssh-keygen -t rsa -N ''
> cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys
> ```

### 4. Démarrer

```bash
sudo bash check_install.sh   # relancer pour vérifier la config .env et démarrer le service
systemctl start ups-monitor
systemctl status ups-monitor
```

Accéder à l'interface : **`http://IP_DU_SERVEUR:8080`**

---

## Gestion du service

```bash
# Démarrer
systemctl start ups-monitor

# Arrêter
systemctl stop ups-monitor

# Redémarrer (après mise à jour de la config par ex.)
systemctl restart ups-monitor

# Voir le statut
systemctl status ups-monitor

# Activer au démarrage du serveur
systemctl enable ups-monitor

# Désactiver au démarrage
systemctl disable ups-monitor

# Voir les logs en direct
journalctl -u ups-monitor -f

# Voir les 100 dernières lignes de logs
journalctl -u ups-monitor -n 100
```

---

## Mise à jour de l'application

```bash
cd /opt/ups-monitor
git pull
systemctl restart ups-monitor
```

---

## Configuration SNMPv3 sur la carte Eaton Network-M3

1. Connecte-toi à l'interface web de la carte (http://IP_CARTE)
2. Aller dans **Configuration → SNMP → SNMPv3**
3. Créer un utilisateur avec :
   - **Auth protocol** : SHA
   - **Privacy protocol** : AES
   - **Auth password** : ta valeur pour `SNMP_AUTH_KEY`
   - **Privacy password** : ta valeur pour `SNMP_PRIV_KEY`
4. Renseigne le même nom d'utilisateur dans `SNMP_USER`

---

## Architecture technique

```
[Onduleur Eaton] ──SNMPv3──► [snmp_poller.py]
                                     │
                             [action_manager.py]  ← évalue les seuils
                            /         │         \
                    [alert.py]   [db.py]    [shutdown.py]
                    (email/log) (SQLite)  (SSH → xe vm-shutdown)
                                     │
                             [FastAPI main.py]
                            /                 \
                     [API REST]          [WebSocket /ws/live]
                         │                       │
                 [index.html + app.js] ◄──────────┘
                  (dashboard + charts)
```

### Structure des fichiers

```
ups-monitor/
├── app/
│   ├── main.py                  ← Point d'entrée FastAPI + boucle polling
│   ├── config.py                ← Lecture du .env (tous les paramètres)
│   ├── poller/
│   │   ├── oids.py              ← Définition des OIDs SNMP Eaton (XUPS-MIB)
│   │   └── snmp_poller.py       ← Interrogation SNMPv3 async
│   ├── database/
│   │   ├── models.py            ← Schéma SQLite (mesures, alertes, actions)
│   │   └── db.py                ← Requêtes async (save, query, purge)
│   ├── actions/
│   │   ├── action_manager.py    ← Règles de seuils + cooldown
│   │   ├── alert.py             ← Alertes log + email SMTP
│   │   └── shutdown.py          ← Arrêt VMs XenServer via SSH
│   ├── api/
│   │   ├── routes_auth.py       ← Login / JWT / logout
│   │   └── routes_data.py       ← API status, historique, alertes, WebSocket
│   └── web/
│       ├── index.html           ← Dashboard (4 onglets)
│       ├── style.css            ← Thème sombre
│       └── app.js               ← Logique frontend + graphiques Chart.js
├── MIB/                         ← Fichiers MIB Eaton (référence)
├── result.xml                   ← Export SNMP réel de l'onduleur (référence)
├── requirements.txt             ← Dépendances Python
├── .env.example                 ← Template de configuration
├── check_install.sh             ← Vérification + installation des dépendances
├── deploy-xenserver.sh          ← Déploiement complet XenServer/CentOS 7
└── ups-monitor.service          ← Service systemd
```

---

## Règles d'alerte par défaut

| Règle | Condition | Action | Cooldown |
|---|---|---|---|
| Passage sur batterie | `output_source == batterie` | Alerte CRITIQUE | 10 min |
| Retour sur secteur | Retour depuis batterie | Alerte WARNING | 5 min |
| Batterie faible | `< 30%` sur batterie | Alerte CRITIQUE | 5 min |
| Batterie critique | `< 15%` sur batterie | **Arrêt VMs** | 60 min |
| Autonomie critique | `< 5 min` sur batterie | **Arrêt VMs** | 60 min |
| Défaut batterie | `bat_failure = oui` | Alerte CRITIQUE | 60 min |
| Batterie vieillie | `bat_aged = oui` | Alerte WARNING | 24h |
| Sortie non protégée | `output_status ≠ protégé` | Alerte CRITIQUE | 15 min |
| UPS injoignable | Pas de réponse SNMP | Alerte CRITIQUE | 5 min |

---

## Dépendances Python (`requirements.txt`)

| Paquet | Rôle |
|---|---|
| `fastapi` | Framework API web async |
| `uvicorn` | Serveur ASGI (exécute FastAPI) |
| `pysnmp` | Client SNMP v3 en Python |
| `sqlalchemy` | ORM base de données |
| `aiosqlite` | Driver SQLite asynchrone |
| `python-jose` | Génération et vérification JWT |
| `passlib` | Hachage des mots de passe (bcrypt) |
| `python-dotenv` | Lecture du fichier `.env` |
| `pydantic-settings` | Validation de la configuration |
| `python-multipart` | Support formulaires HTML (login) |
| `aiofiles` | Lecture fichiers statiques async |

---

## Dépannage rapide

**Le service ne démarre pas**
```bash
journalctl -u ups-monitor -n 50
# Chercher ERROR ou Traceback
```

**SNMP ne répond pas**
```bash
# Tester manuellement (installer snmpwalk)
yum install net-snmp-utils
snmpwalk -v3 -u SNMP_USER -l authPriv \
  -a SHA -A SNMP_AUTH_KEY \
  -x AES -X SNMP_PRIV_KEY \
  IP_ONDULEUR .1.3.6.1.4.1.534.1.1.2.0
```

**Réinitialiser la base de données**
```bash
systemctl stop ups-monitor
rm /opt/ups-monitor/ups_monitor.db
systemctl start ups-monitor
```

**Relancer la vérification des dépendances**
```bash
bash /opt/ups-monitor/check_install.sh
```
