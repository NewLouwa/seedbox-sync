# seedbox-sync

Remplacement de Syncthing pour synchroniser la seedbox distante (SFTP)
vers un stockage local, via `lftp`. Gestion par `control.sh`, transfert
par `scripts/sync.sh`, planifie en cron toutes les 30 min.

## Architecture

```
control.sh              Interface utilisateur (start/stop/pause/find/status)
scripts/sync.sh          Logique de transfert (appele par cron ou control.sh start)
PAUSED                    Flag file - presence = pause active (cree/supprime par control.sh)
```

Config externalisee dans `/etc/seedbox-sync.env` (chmod 600, root:root),
JAMAIS dans ce repo.

## Setup

### 1. Config

```bash
cat > /etc/seedbox-sync.env << 'EOF'
REMOTE_USER=ton_user
REMOTE_HOST=ton_host.example.com
REMOTE_PASS='mot_de_passe_entre_quotes_simples'
# Optionnel - recherche via SSH (voir section Recherche)
#SSH_KEY=/root/.ssh/seedbox_ed25519
#SSH_PORT=22
EOF
chmod 600 /etc/seedbox-sync.env
chown root:root /etc/seedbox-sync.env
```

### 2. Cron (root uniquement, pas de doublon sous un autre user)

```bash
sudo crontab -e -u root
# */30 * * * * /opt/scripts/seedbox-sync/scripts/sync.sh >> /var/log/cron-sync.log 2>&1
```

### 3. Alias global

```bash
ln -sf /opt/scripts/seedbox-sync/control.sh /usr/local/bin/sbs
chmod +x /opt/scripts/seedbox-sync/control.sh /opt/scripts/seedbox-sync/scripts/sync.sh
```

### 4. Logrotate

```bash
cat > /etc/logrotate.d/ass-sync << 'EOF'
/var/log/ass-sync.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
```

## Commandes

| Commande | Effet |
|---|---|
| `sbs test` | Verifie connexion + auth SFTP, aucun lock, aucun telechargement |
| `sbs find <nom>` | Recherche recursive (SSH) sans rien telecharger |
| `sbs start [filtre]` | Lance immediatement en arriere-plan. Filtre = categorie (reordonne) ou titre precis (sync cible puis reprend normal) |
| `sbs pause` | Bloque les prochains lancements cron (n'arrete pas un run en cours) |
| `sbs resume` | Retire le blocage |
| `sbs stop` | Tue le run en cours + le process lftp associe, nettoie le lock |
| `sbs status` | Etat pause + PID actif eventuel |

## Recherche (SSH)

`find` et le mode titre de `start` cherchent recursivement via `ssh` +
`find -iname` (pas de limite de profondeur, contrairement a l'ancien
systeme base sur `lftp cls` qui ne listait que le premier niveau).

Deux methodes d'auth, bascule automatique dans cet ordre :

1. **Cle SSH** (recommande) - si `SSH_KEY` est definie dans `.env` et le
   fichier existe :
   ```bash
   ssh-keygen -t ed25519 -f /root/.ssh/seedbox_ed25519 -N ""
   ssh-copy-id -i /root/.ssh/seedbox_ed25519.pub -p 22 ton_user@ton_host.example.com
   ```
2. **sshpass** (fallback) - si pas de cle configuree :
   ```bash
   apt install -y sshpass
   ```

Le transfert reste en lftp/SFTP avec mot de passe (`REMOTE_PASS`) dans
tous les cas - la cle SSH ne sert qu'a la recherche, pas au mirror.

## Verrouillage

`sync.sh` pose un lock atomique (`mkdir /tmp/ass.lock.d`) avec TTL 1h,
empeche les executions concurrentes (cron qui se chevauche, lancement
manuel pendant un run auto). PID trace dans `/tmp/ass-sync.pid` pour
permettre `sbs stop`.

## Notes securite

- `.env` jamais dans ce repo, jamais en clair dans un chat/paste.
- Mot de passe seedbox a changer si jamais expose (historique: deja
  fait une fois suite a un softban lie a des tentatives d'auth
  invalides pendant du debug).
- `xfer:use-temp-file` actif - les transferts en cours ecrivent vers un
  nom cache (`.*.lftp-tmp`), jamais visibles sous leur nom final avant
  completion.
