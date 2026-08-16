# seedbox-sync

Synchronisation media unidirectionnelle depuis une seedbox distante via SFTP (lftp), avec recherche recursive par SSH. Remplace Syncthing pour ce cas d'usage precis : gros fichiers binaires immuables, pas besoin de sync bidirectionnelle ni de delta-transfer.

## Sommaire

- [Vue d'ensemble](#vue-densemble)
- [Fonctionnalites](#fonctionnalites)
- [Prerequis](#prerequis)
- [Installation](#installation)
- [Utilisation](#utilisation)
- [Adapter les mappings](#adapter-les-mappings)
- [Fonctionnement interne](#fonctionnement-interne)
- [Depannage](#depannage)
- [Securite](#securite)

## Vue d'ensemble

Le script tourne en cron (toutes les 30 min par defaut) et mirrore un ensemble de dossiers distants vers du stockage local, un par un, en ne retransferant que ce qui a change (taille/date de modification). Une interface en ligne de commande (`control.sh`, aliasee `sbs`) permet de piloter le tout sans toucher au cron : lancer un sync immediat, cibler un titre precis, mettre en pause, arreter un run en cours, tester la connexion, chercher un fichier sans le telecharger.

Deux fichiers principaux :

| Fichier | Role |
|---|---|
| `control.sh` | Interface utilisateur - toutes les commandes passent par la (aliasee `sbs`) |
| `scripts/sync.sh` | Logique de transfert - appele par cron ou par `control.sh start` |

## Fonctionnalites

- Sync incrementale (taille + date de modification, pas de retransfert inutile)
- Ecriture atomique - un fichier en cours de transfert n'apparait jamais sous son nom final avant completion (evite les fichiers partiels visibles/lisibles)
- Recherche recursive via SSH (`find -iname`), sans limite de profondeur
- Priorisation ciblee : synchroniser une categorie entiere ou un titre precis en premier, puis reprendre le sync complet normal
- Verrouillage anti-concurrence (empeche deux executions simultanees)
- Logs a niveaux (DEBUG/INFO/WARN/ERROR), couleur en terminal interactif, texte brut dans le fichier de log
- Pause/resume/stop pilotables sans toucher au cron
- Rotation automatique des logs (logrotate)

## Prerequis

- `bash` 4+ (tableaux associatifs)
- `lftp`
- `ssh` (client) - pour la recherche recursive
- `sshpass` - optionnel, uniquement si pas de cle SSH configuree
- Acces `root` (ou sudo) pour la configuration systeme (`/etc`, cron, logrotate)

## Installation

### 1. Deployer les scripts

```bash
mkdir -p /opt/scripts/seedbox-sync/scripts
# copier control.sh et scripts/sync.sh dans ces emplacements
chmod +x /opt/scripts/seedbox-sync/control.sh /opt/scripts/seedbox-sync/scripts/sync.sh
```

### 2. Configuration

La configuration vit **hors du repo**, dans `/etc/seedbox-sync.env`, avec des permissions restrictives :

```bash
cat > /etc/seedbox-sync.env << 'EOF'
REMOTE_USER=ton_user
REMOTE_HOST=ton_host.example.com
REMOTE_PASS='mot_de_passe_entre_quotes_simples'

# Optionnel - recherche via SSH (voir section Fonctionnement interne)
#SSH_KEY=/root/.ssh/seedbox_ed25519
#SSH_PORT=22
EOF

chmod 600 /etc/seedbox-sync.env
chown root:root /etc/seedbox-sync.env
```

Le mot de passe doit etre entre quotes simples pour eviter toute interpretation par bash de caracteres speciaux qu'il pourrait contenir (`$`, `` ` ``, espaces, etc).

### 3. Cron

Une seule entree, sous `root` uniquement (evite les doublons si le script tourne sous plusieurs comptes en meme temps) :

```bash
sudo crontab -e -u root
```

Ajouter :

```
*/30 * * * * /opt/scripts/seedbox-sync/scripts/sync.sh >> /var/log/cron-sync.log 2>&1
```

### 4. Alias global

```bash
ln -sf /opt/scripts/seedbox-sync/control.sh /usr/local/bin/sbs
```

Rend la commande `sbs` disponible partout, pour tous les utilisateurs, sans avoir a retaper le chemin complet.

### 5. Rotation des logs

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

### 6. Recherche via SSH (optionnel mais recommande)

Voir [Fonctionnement interne](#recherche-recursive) pour le detail. En resume, generer une paire de cles dediee :

```bash
ssh-keygen -t ed25519 -f /root/.ssh/seedbox_ed25519 -N ""
ssh-copy-id -i /root/.ssh/seedbox_ed25519.pub -p 22 ton_user@ton_host.example.com
```

Puis decommenter `SSH_KEY=` et `SSH_PORT=` dans `/etc/seedbox-sync.env`.

Sans cle configuree, le script bascule automatiquement sur `sshpass` (a installer : `apt install -y sshpass`) en reutilisant `REMOTE_PASS`. Fonctionnel mais moins propre (mot de passe visible dans la liste des process pendant l'appel).

## Utilisation

Toutes les commandes passent par `sbs` (une fois l'alias cree) ou directement `/opt/scripts/seedbox-sync/control.sh`.

### `sbs test`

Verifie la connexion et l'authentification SFTP sans poser de lock ni telecharger quoi que ce soit.

```
$ sbs test
Test de connexion vers ton_host.example.com...
OK - connexion et auth valides
```

### `sbs find <nom>`

Recherche recursive (SSH) sur toute l'arborescence distante, sans rien telecharger. Insensible a la casse, match partiel.

```
$ sbs find "dragon"
Recherche recursive de 'dragon'...
  media/TV Shows/House of the Dragon
```

### `sbs start [filtre]`

Lance un sync immediatement, en arriere-plan, sans attendre le prochain declenchement cron.

- Sans argument : sync complet, ordre normal.
- Argument = nom d'une categorie (mapping) : cette categorie est traitee en premier, puis le reste suit normalement.
- Argument = titre precis (ne correspond a aucune categorie) : recherche recursive, sync uniquement ce qui matche, puis reprend le cycle complet normal.

```
$ sbs start "House of the Dragon"
Lancement manuel (priorite: House of the Dragon)...
Lance en arriere-plan, PID 48213
Suivi: tail -f /var/log/ass-sync.log
```

### `sbs pause` / `sbs resume`

`pause` empeche les **prochains** declenchements cron de faire quoi que ce soit (ils sortent immediatement). Un run deja en cours au moment du `pause` continue jusqu'a sa fin normale - ce n'est pas un arret immediat.

```
$ sbs pause
Sync PAUSE (bloque les prochains lancements, n'arrete pas un run en cours)
$ sbs resume
Sync RESUME
```

### `sbs stop`

Arrete un run en cours (SIGTERM, puis SIGKILL apres 2 secondes si necessaire), tue le process `lftp` associe, nettoie le verrou.

```
$ sbs stop
Arret de sync.sh (PID 48213)...
Process lftp actif tue
Lock et PID nettoyes
```

### `sbs status`

```
$ sbs status
Sync ACTIF (pause non appliquee)
Aucun run en cours
```

## Adapter les mappings

Les correspondances dossier-distant → dossier-local sont definies dans la variable `MAPPINGS`, dupliquee a l'identique dans `scripts/sync.sh` et dans la section `find` de `control.sh` :

```bash
declare -A MAPPINGS=(
    ['chemin/distant/CategorieA']='nom-dossier-local-a'
    ['chemin/distant/CategorieB']='sous/chemin/local-b'
)
```

- **Cle** : chemin relatif sur la seedbox, racine = repertoire home du compte SFTP.
- **Valeur** : chemin relatif sous `LOCAL_BASE` (`/mnt/dl` par defaut, surchargeable via la variable d'environnement `LOCAL_BASE`).
- Autant d'entrees que necessaire ; chaque entree declenche un mirror recursif complet.

Pour ajouter, renommer ou retirer une categorie : modifier le bloc `MAPPINGS` dans **les deux fichiers**. Une desynchronisation entre les deux ferait que `find`/`test` et le sync reel ne verraient pas les memes dossiers.

## Fonctionnement interne

### Sync incrementale

`mirror --only-newer --continue` compare taille et date de modification entre distant et local a chaque execution - pas de checksum, pas d'etat sauvegarde entre les runs. Un fichier identique (meme taille, date locale >= date distante) est ignore ; sinon il est retransfere integralement.

### Ecriture atomique

`xfer:use-temp-file` force lftp a ecrire vers un nom cache (`.*.lftp-tmp`) pendant le transfert, puis a renommer vers le nom final une fois complet. Un fichier en cours de telechargement n'apparait donc jamais sous son nom reel dans le dossier final - evite qu'un lecteur (ou un utilisateur qui fait le menage) tombe sur un fichier tronque en pensant que c'est un dechet.

### Recherche recursive

`find`/mode-titre de `start` utilisent `ssh <host> "find media -iname '*motif*'"` cote distant - recursif, sans limite de profondeur, contrairement a une liste `lftp cls` classique qui ne voit que le premier niveau d'un dossier. Deux methodes d'authentification, bascule automatique dans cet ordre :

1. **Cle SSH** (recommande) - utilisee si `SSH_KEY` est definie dans `.env` et que le fichier existe.
2. **sshpass** (fallback) - utilisee si `sshpass` est installe et qu'aucune cle n'est configuree.

Le transfert lui-meme (le mirror reel) reste toujours en lftp/SFTP avec `REMOTE_PASS` - la cle SSH ne sert qu'a la recherche, jamais au transfert.

### Verrouillage

Un lock atomique (`mkdir /tmp/ass.lock.d` - atomique car `mkdir` echoue si le dossier existe deja, contrairement a un simple `test -f` + `touch` qui laisserait une fenetre de race condition) empeche deux executions simultanees. TTL d'1 heure : un lock plus vieux que ca est considere perime et force-nettoye (protection contre un lock orphelin apres un crash). Le PID du run actif est trace dans `/tmp/ass-sync.pid`, ce qui permet a `sbs stop` de cibler le bon process.

## Depannage

| Symptome | Cause probable | Solution |
|---|---|---|
| `Permission denied` sur `/etc/seedbox-sync.env` | Le script tourne sous un utilisateur qui n'a pas les droits de lecture (fichier en `600 root:root`) | Verifier sous quel user le cron s'execute (`crontab -l -u <user>`), aligner sur `root` |
| `Login incorrect` | Mot de passe errone dans `.env`, ou caracteres speciaux mal echappes | Reverifier le mot de passe entre quotes simples, tester en manuel avec `lftp -u user,'pass' sftp://host -e "ls; bye"` |
| `Connection refused` / timeout prolonge | Softban temporaire cote seedbox (trop de tentatives d'auth invalides), ou serveur en maintenance | Attendre, verifier le panel du provider, eviter de relancer en boucle |
| Aucun resultat sur `find` alors que le fichier existe | `SSH_KEY`/`sshpass` non configures, fallback silencieux | Verifier `command -v sshpass` ou l'existence de la cle, tester `ssh -i cle user@host true` en manuel |
| Log silencieux plusieurs minutes | Normal sur une grosse categorie - transfert en cours sans qu'un fichier individuel ait fini | Verifier avec `ps aux \| grep lftp` et surveiller la taille du dossier local |
| Erreur de syntaxe apres une modification | Toujours valider avant de deployer | `bash -n scripts/sync.sh && bash -n control.sh` |

## Securite

- Toujours entourer le mot de passe de quotes simples dans `.env` pour neutraliser les caracteres speciaux du shell.
- `xfer:use-temp-file` actif par defaut - voir [Ecriture atomique](#ecriture-atomique).
- Preferez une cle SSH dediee (pas la meme que celle utilisee ailleurs) plutot que `sshpass`, qui expose le mot de passe dans la liste des process pendant l'execution.
