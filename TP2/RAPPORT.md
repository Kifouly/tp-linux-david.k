# TP2 — Comptes, permissions avancées, ACL et sudoers

**Auteur :** David.K · **Module :** Administration d'un Linux Server (BTC2) · **Jour 2/5** (suite du TP1)
**Environnement :** `srv-core2` (Rocky Linux 9, hostname `srv-core`, `/` en XFS sur `/dev/mapper/rl-root`)

Les sorties citées ici se trouvent dans `captures/`. Elles ont été produites le 3 novembre 2026 par `scripts/tp2.sh` (étapes `m1` à `m4`, `bonus`, `collecte`). Les captures d'écran sont dans `captures/ecrans/`. Les fichiers de configuration déployés sont dans `configs/`. Le rendu illustré de 5 pages est `RENDU.pdf`.

Les comptes de TP ont tous le mot de passe initial imposé par l'énoncé. L'empreinte du mot de passe root, affichée pendant la démonstration d'évasion (4.3), a été **masquée** dans la capture texte et dans la capture d'écran avant publication.

---

## Mission 1 — Politique d'authentification et comptes

### 1.1 Politique, posée avant de créer les comptes

| Élément | Valeur | Fichier |
|---|---|---|
| Durée de vie du mot de passe | `PASS_MAX_DAYS 90`, `PASS_MIN_DAYS 1`, `PASS_WARN_AGE 14` | `/etc/login.defs` (`configs/login.defs.diff`) |
| umask de base | `UMASK 027` (appliqué à la connexion par `pam_umask`) | `/etc/login.defs` |
| Qualité | `minlen=12`, `minclass=3`, `maxrepeat=3`, `dictcheck=1`, `usercheck=1`, `enforce_for_root` | `/etc/security/pwquality.conf.d/50-helios.conf` |
| Verrouillage | `deny=5`, `fail_interval=900`, `unlock_time=600`, `audit` | `/etc/security/faillock.conf` + `authselect enable-feature with-faillock` |

La politique est posée **avant** les `useradd`, parce que `login.defs` n'est lu qu'à la création d'un compte. Les comptes créés avant gardent `99999` jours. J'ai quand même appliqué `chage -M 90 -m 1 -W 14 -I 7` à chaque compte pour être sûr du résultat.

`authselect` est la seule méthode supportée sur Rocky 9 pour activer `pam_faillock`. Modifier `/etc/pam.d/system-auth` à la main serait écrasé au prochain `authselect apply-changes`.

### 1.2 Groupes et comptes

| Compte | UID | Groupe primaire | Secondaires | Rôle |
|---|---|---|---|---|
| julien | 5100 | transport (5000) | helios-ops (5002) | chef d'équipe transport, administrateur du groupe `transport` (`gpasswd -A`) |
| nadia | 5101 | transport | — | exploitante (ajoutée au groupe par julien lui-même) |
| tarek | 5102 | telemetry (5001) | transport | analyste télémétrie |
| audit-ext | 5103 | telemetry | — | auditeur externe, compte expirant le **24/11/2026** (`useradd -e`, +21 jours) |

`/etc/gshadow` contient `transport:!:julien:tarek`. Le troisième champ (`julien`) désigne l'administrateur du groupe. julien peut donc gérer les membres de `transport` sans être root : `gpasswd -a nadia transport` réussit sous son identité.

Le squelette `/etc/skel/.bashrc` reçoit le socle commun : `EDITOR`, `HISTSIZE` et `HISTTIMEFORMAT`. Il ne contient **pas** de `umask` : `~/.bashrc` est lu après `/etc/profile.d/`, et un `umask` à cet endroit écraserait le réglage par groupe de la mission 2.

### 1.3 Vérifications

- **Mot de passe faible :** `pwscore` puis `passwd` (sous julien) refusent `helios` avec le message « Le mot de passe comporte moins de 12 caractères ». La date de dernier changement reste inchangée. J'avais reculé cette date d'un jour (`chage -d`) pour que `PASS_MIN_DAYS 1` ne bloque pas le test lui-même.
- **faillock :** j'ai fait 6 tentatives fausses de `su - nadia` depuis tarek. `faillock --user nadia` liste 5 échecs valides (`V`). Le **bon** mot de passe est alors refusé (`rc=1`). Après `faillock --user nadia --reset`, la connexion réussit (`rc=0`).
- **Expiration :** `chage -l audit-ext` affiche `Account expires : nov. 24, 2026`.

---

## Mission 2 — Bits spéciaux et umask

### 2.1 setgid sur répertoire

`/srv/helios/projets/transport` est en `2770 julien:transport`, et le témoin `temoin` en `0770`. tarek (groupe primaire `telemetry`) crée un fichier dans chacun des deux :

| Répertoire | Groupe du fichier créé par tarek |
|---|---|
| `transport` (setgid `s`) | **transport** (hérité du répertoire) |
| `temoin` (sans setgid) | telemetry (groupe primaire de tarek) |

Les sous-répertoires héritent aussi du bit `s` (`semaine-41` créé à la mission 3 : `drwxrws---`).

### 2.2 Sticky bit

Sur `/srv/helios/depot` (`1777`), tarek ne peut pas supprimer le fichier de nadia : `rm` répond « Opération non permise » (`rc=1`). Sans le sticky bit (`0777`), la même commande réussit (`rc=0`). Avec un répertoire en écriture pour tous, n'importe qui peut donc effacer les fichiers des autres. J'ai remis le mode `1777` à la fin du test.

### 2.3 umask — prévu et observé

Les permissions demandées par `touch` (0666) et `mkdir` (0777) sont filtrées par le umask : `mode = demandé & ~umask`.

| umask | Fichier prévu | Fichier observé | Répertoire prévu | Répertoire observé |
|---|---|---|---|---|
| 027 (login.defs) | 640 `rw-r-----` | `-rw-r-----` ✔ | 750 `rwxr-x---` | `drwxr-x---` ✔ |
| 002 | 664 `rw-rw-r--` | `-rw-rw-r--` ✔ | 775 `rwxrwxr-x` | `drwxrwxr-x` ✔ |
| 077 | 600 `rw-------` | `-rw-------` ✔ | 700 | (non testé) |

**umask par groupe** (`/etc/profile.d/helios-umask.sh`) :

```sh
if id -nG | tr ' ' '\n' | grep -qx transport ; then umask 002 ; else umask 027 ; fi
```

Après déploiement, nadia (groupe `transport`) obtient `0002` à la connexion et ses fichiers sont `rw-rw-r--`. audit-ext obtient `0027`. Le umask 002 permet aux membres de `transport` de modifier ensemble les fichiers partagés, mais il donne aussi `r` aux « autres » (voir l'audit, constat 1).

### 2.4 setuid

**Un script ne profite pas du setuid.** `/usr/local/bin/faux-setuid.sh` (`4755 root`) lancé par nadia affiche `uid=5101(nadia)`. Sous Linux, le noyau ignore les bits setuid/setgid sur un fichier exécuté via un interpréteur `#!`. Sans cette règle, il y aurait une course entre l'ouverture du script par le noyau et sa relecture par l'interpréteur. Le fichier de test a été supprimé ensuite.

**Inventaire** (`find / -xdev \( -perm -4000 -o -perm -2000 \) -type f`, voir `captures/m2-setuid.txt`) : 26 binaires setuid root et 5 setgid. Trois justifications :

| Binaire | Bit | Pourquoi il en a besoin |
|---|---|---|
| `/usr/bin/passwd` | setuid root | un utilisateur doit pouvoir changer **son** mot de passe, donc écrire dans `/etc/shadow` (`0000 root`). Le programme limite lui-même l'action au compte appelant. |
| `/usr/bin/sudo` | setuid root (`---s--x--x`) | il doit pouvoir devenir root (ou `helios`) après authentification et lecture des règles `sudoers`. Sans le bit, il ne pourrait pas changer d'UID. |
| `/usr/libexec/openssh/ssh-keysign` | setgid `ssh_keys` | l'authentification *host-based* signe avec les clés privées d'hôte, lisibles uniquement par le groupe `ssh_keys`. Le setgid suffit, sans passer root (moindre privilège). |

On peut citer aussi `su` (changer d'identité) et `unix_chkpwd` (vérifier un mot de passe pour un processus non-root, ex. économiseur d'écran).

### 2.5 `helios-lastlog` (setgid telemetry)

`/var/log/helios/app.log` est en `0640 root:telemetry`. julien n'est pas dans `telemetry`, donc `tail` est refusé (`rc=1`). Le binaire `helios-lastlog`, compilé depuis `configs/helios-lastlog.c` et installé en `2755 root:telemetry`, lui affiche les 10 dernières lignes (`rc=0`). Ce binaire est sûr :

- `execle()` avec un chemin **absolu** (`/usr/bin/tail`) et un environnement **fixé** (`PATH`, `IFS`), donc pas de détournement par `PATH` ou `LD_PRELOAD` ;
- arguments codés en dur : l'utilisateur ne peut pas choisir le fichier lu ;
- **setgid** plutôt que setuid root : il ne gagne que le droit de lire ce que le groupe `telemetry` lit déjà.

---

## Mission 3 — ACL POSIX

Le système de fichiers `/` est en XFS, qui gère les ACL nativement (aucune option de montage nécessaire).

### 3.1 ACL nominative

La commande `setfacl -R -m u:audit-ext:rX /srv/helios/projets/transport` donne :

- `r-x` sur le répertoire (le `X` majuscule ajoute `x` seulement aux répertoires et aux fichiers déjà exécutables) ;
- `r--` sur les fichiers existants.

audit-ext peut lister et lire. `touch interdit` est refusé (`rc=1`). `ls -l` affiche le `+` à côté des droits.

### 3.2 ACL par défaut

**Avant :** nadia crée `nouvelle.csv`, qui n'a **aucune ACL** (pas de `+`). Constat : audit-ext peut quand même la lire (`rc=0`). Le umask 002 de nadia donne `r` aux « autres », et l'ACL du répertoire lui donne la traversée (`x`). Sans ce umask, il aurait été bloqué.

**ACL par défaut posées :** `d:u:audit-ext:r`, `d:g:transport:rwx`, `d:o::---`.

**Après :**

- `tournee-j2.csv` hérite de `user:audit-ext:r--` et de `group:transport:rwx #effective:rw-`. Le masque est `rw-`, car un fichier est créé en 0666. Avec une ACL par défaut, c'est elle qui remplace le umask.
- `semaine-41` hérite des entrées **et** des ACL par défaut, ce qui propage la règle en profondeur, ainsi que du bit setgid.

### 3.3 Le masque et `chmod g-w`

J'ajoute `u:tarek:rwx` sur `tournee-j2.csv`, puis je lance `chmod g-w`. Les entrées ne changent pas, mais elles deviennent toutes `#effective:r-x` et `mask::r-x`. tarek ne peut plus écrire (`rc=1`).

**Explication :** quand un fichier porte une ACL étendue, les bits « groupe » affichés par `ls -l` et modifiés par `chmod` **sont le masque**, et non l'entrée `group::`. Le masque est la limite haute de toutes les entrées nommées (`user:x`, `group:y`) et du groupe propriétaire. `chmod g-w` retire donc l'écriture à tout le monde sauf au propriétaire, même si l'entrée de tarek indique toujours `rwx`. Après `setfacl -m m::rwx`, tarek écrit de nouveau (`rc=0`).

Conséquence en exploitation : un script qui fait `chmod 640` sur une arborescence avec ACL casse silencieusement les délégations.

### 3.4 Sauvegarde et restauration

| Opération | Résultat |
|---|---|
| `getfacl -R transport > /root/acl-transport-2026-11-03.txt` | 78 lignes (copie : `configs/acl-transport-2026-11-03.txt`) |
| `setfacl -R -b transport` | toutes les ACL supprimées, il ne reste que `user::/group::/other::` |
| `setfacl --restore=…` | ACL d'accès et par défaut restaurées à l'identique |
| `cp -a` | ACL, propriétaire, groupe et setgid conservés |
| `cp -r` | **tout est perdu** : `root:root`, plus d'ACL, plus de bit `s` |
| `tar --acls --xattrs` | ACL conservées (le `+` apparaît dans `tar -tv`) |

La sauvegarde est faite avec des chemins **relatifs** (`cd /srv/helios/projets`), ce qui permet de la restaurer ailleurs.

---

## Mission 4 — Délégation sudo

### 4.1 Règle `helios-ops` (`configs/90-helios-ops`)

- `Cmnd_Alias HELIOS_SVC` : `start/stop/restart/status` de `helios-collect.service`, `start/stop` de `helios.target`, uniquement en root.
- `Cmnd_Alias HELIOS_LOG` : `journalctl -u helios-collect.service *` et `-u helios-archive.service *`.
- Lecture des données **en tant que `helios`** et non root : `(helios) ls /var/lib/helios, cat …/telemetry.csv`.
- `!DANGEREUX` (`su`, `sudo`, `passwd root`, `vi`, `vim`, `less`, `find`). Cette liste sert de documentation et de garde-fou. La vraie sécurité vient de la liste blanche, car une liste noire se contourne (copie ou renommage de binaire).
- `Defaults:%helios-ops` : `timestamp_timeout=5`, `passwd_tries=2`, `lecture=always`, `log_output`, `iolog_dir=/var/log/sudo-io`, `logfile=/var/log/sudo-helios.log`.
- Validation par `visudo -cf` **avant** installation en `0440` : une erreur de syntaxe dans `sudoers.d` casse sudo pour tout le monde.

### 4.2 Vérifier et tracer

| Test (sous julien) | rc |
|---|---|
| `sudo systemctl restart helios-collect.service` | **0** |
| `sudo systemctl restart sshd` | **1** (« n'est pas autorisé ») |
| `sudo -u helios cat /var/lib/helios/telemetry.csv` | 0 (3 dernières mesures affichées) |
| `sudo journalctl -u helios-collect.service -n 5 --no-pager` | 0 |
| nadia : `sudo -l` | 1 (« ne peut pas utiliser sudo ») |

La traçabilité est assurée à trois niveaux :

- `/var/log/sudo-helios.log` ;
- `journalctl -t sudo`, qui enregistre aussi les refus (`command not allowed`) ;
- `sudoreplay -l user julien`, qui liste les 3 sessions enregistrées (TSID 000001 à 000003). On peut les rejouer avec `sudoreplay 000001`.

Le rejeu avec `-m 0.2` a échoué avec « attente maximum invalide ». La locale française attend une virgule décimale. `LC_ALL=C sudoreplay -m 0.2 …` corrige le problème, et le script est corrigé en conséquence.

### 4.3 Évasion via `sudo vim`, puis correction

**Mauvaise règle** : `nadia ALL=(root) NOPASSWD: /usr/bin/vim /srv/helios/projets/transport/*`. Le joker `*` accepte **n'importe quels arguments supplémentaires**, et vim permet d'exécuter des commandes shell :

```
sudo -n /usr/bin/vim …/tournee-nadia.csv -E -s -c '!/usr/bin/id > /tmp/evasion-id.txt' -c 'q!'
→ uid=0(root) gid=0(root)
```

nadia exécute alors n'importe quelle commande en root, et peut par exemple lire `/etc/shadow` (empreinte masquée dans le rendu).

**Correction** (`configs/91-nadia-edition`) :

```
Defaults:nadia !sudoedit_checkdir
nadia ALL=(root) sudoedit /srv/helios/projets/transport/*
```

Avec `sudoedit`, l'éditeur tourne **sous l'identité de nadia**, sur une copie temporaire. Seule la recopie finale est faite par sudo en root, donc un `:!sh` dans l'éditeur ne donne qu'un shell nadia. `!sudoedit_checkdir` est nécessaire parce que le répertoire est inscriptible par le groupe `transport`, dont nadia fait partie. Par défaut, sudoedit refuse les répertoires que l'utilisateur peut modifier (protection contre les liens symboliques). Ici, le setgid et le sticky ne s'appliquent pas, et les fichiers appartiennent aux membres de l'équipe.

Résultat : `sudo vim` est refusé (`rc=1`). `sudoedit` avec un éditeur de démonstration (`SUDO_EDITOR=/usr/local/bin/tp2-editeur-demo`) modifie le fichier (`rc=0`), qui garde son propriétaire `nadia:transport`.

---

## Bonus — Audit (lecture seule)

Les commandes sont dans `captures/bonus-audit.txt`. Points sains : aucun compte sans mot de passe, `sudoers.d` en `0440 root:root` (la mauvaise règle `99-mauvais-exemple` a été retirée), répertoires personnels en `0700`, audit-ext sans sudo et avec une expiration fixée.

**Cinq constats et leur remédiation :**

| # | Constat | Risque | Remédiation |
|---|---|---|---|
| 1 | umask **002** pour le groupe `transport` : les fichiers sont créés en `rw-rw-r--`. | Un compte qui a la traversée du répertoire lit les fichiers sans ACL explicite. C'est le cas d'audit-ext, qui lit `nouvelle.csv` (3.2), et ce sera le cas de tout compte ajouté plus tard avec `x`. | Mettre `umask 007` dans `helios-umask.sh`. Les ACL par défaut (`d:o::---`) couvrent déjà les nouveaux fichiers. Corriger l'existant avec `chmod -R o-rwx transport`. |
| 2 | `journalctl -u helios-collect.service *` : le joker laisse julien ajouter **n'importe quelle option**. | `-u sshd` en plus permet de lire les journaux de **toutes** les unités en root. `--vacuum-time=1s` permet d'effacer les journaux archivés, donc de supprimer des traces. | Remplacer `*` par des options figées (ex. `journalctl -u helios-collect.service -n 200 --no-pager`) ou par un script wrapper en `0755 root`. Sinon, utiliser les expressions régulières sudoers (sudo ≥ 1.9.10). |
| 3 | `/srv/helios/depot` en `1777 root:root`, accessible en écriture à tous. | Avec le sticky bit, personne n'efface les fichiers des autres, mais n'importe quel compte (audit-ext compris) peut y déposer des fichiers, remplir le disque ou déposer un leurre. | `chown root:transport` + `chmod 1770`, et quota ou volume dédié si besoin. |
| 4 | Binaires setuid inutiles sur un serveur : `vmware-user-suid-wrapper` (VM VirtualBox), `Xorg.wrap`, `fusermount`/`fusermount3`, `pkexec`, `at`. | Surface d'attaque locale : un binaire setuid vulnérable donne root (ex. CVE-2021-4034 « PwnKit » dans `pkexec`). | Désinstaller les paquets inutiles (`open-vm-tools-desktop`, environnement graphique) ou faire `chmod u-s`. Comparer l'inventaire à une référence à chaque audit. |
| 5 | Exception nominative `user:tarek:rwx` laissée sur `tournee-j2.csv`, avec masque remis à `rwx`. | Un droit individuel, hors groupe, est oublié dans les revues. Le `x` sur un fichier de données le rend « exécutable ». | `setfacl -x u:tarek tournee-j2.csv`. tarek, membre de `transport`, a déjà `rw` par le groupe. Traiter les exceptions nominatives avec une date de fin et les revoir avec `getfacl -R -s`. |
