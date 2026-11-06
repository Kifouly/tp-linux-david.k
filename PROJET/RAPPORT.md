# PROJET — Mise en production du portail de suivi des tournées

**Auteur :** David.K · **Module :** Administration d'un Linux Server (BTC2) · **Cible :** `srv-core2` (Rocky Linux 9, hostname `srv-core`, 1 vCPU) · **Poste distant :** `srv-edge` (Ubuntu 24.04)

Tout a été déployé le jeudi 5 novembre 2026, entre 11 h 18 et 11 h 58, avec `scripts/projet.sh` (une étape par exigence). Chaque étape écrit ses sorties dans `preuves/`. Les extraits ci-dessous sont copiés de ces fichiers. Les fichiers déployés sont dans `configs/`, les captures d'écran dans `preuves/ecrans/`, et le rendu illustré est `RENDU.pdf`.

Avant de commencer : l'instantané `04-debut-projet` a été pris sur srv-core2 (`preuves/ecrans/00-instantane-04-debut-projet.jpg`). Il n'y avait pas d'instantané `03-fin-TP3` sur ma VM. Les 5 prérequis passent (`preuves/00-prerequis.txt`) : collecteur actif, `telemetry.csv` qui grandit (4486 puis 4487 lignes en 6 s), `helios.target` présent, zone par défaut `drop`, sshd en 2242 sans mot de passe, timer de détection actif, SELinux `Enforcing`.

## 1. Tableau de conformité

| Exigence | Commande de preuve | Partie utile de la sortie |
|---|---|---|
| **E1** comptes | `id lea ; chage -l lea ; id helios-suivi` | `uid=5104(lea) gid=5003(suivi) groupes=5003(suivi)` · `Lea Fabre - responsable suivi des tournees` · `lea:1:90:14:7` (min 1, max 90, avertissement 14, inactivité 7) · `lea : ni wheel ni ssh-admins` · `helios-suivi:x:983:981:…:/srv/helios/suivi:/usr/sbin/nologin`, pas de `/home/helios-suivi`. Voir `e1-comptes.txt`. |
| **E2** répertoire publié | `ls -ld …/www ; getfacl -p …/www` | `drwxrws---+ root suivi …/www`, `user:helios-suivi:rwx`, `user:zabbix:--x`, `other::---`, `default:user:helios-suivi:rw-`. Fichier créé par lea avec `umask 077` : `-rw-rw----+ lea suivi essai-lea.txt`. `runuser -u helios-suivi -- cat` → rc=0, `runuser -u nadia -- cat` → `Permission non accordée`, `runuser -u zabbix -- ls www` → rc=2, `runuser -u zabbix -- stat etat.json` → rc=0. Voir `e2-acl.txt`, `e3-publication.txt`, `configs/getfacl-www.txt`. |
| **E3** publication | `runuser -u <compte> -- /usr/local/sbin/helios-suivi-publish.sh` | helios-suivi → `rc=0` ; deuxième instance pendant que le verrou est tenu → `rc=2` (« une autre publication est deja en cours ») ; lea → `rc=3` (« telemetrie illisible ») ; helios → `rc=3` (« www absent ou non inscriptible »). JSON valide : `"genere": "2026-11-05T11:35:19+01:00"`, `"mesures": 4659`. Journal : `etat.json publie : 4623 mesures` à 11:32:06, puis 11:34:05 (toutes les 2 min). Voir `e3-publication.txt`. |
| **E4** units | `systemctl show … helios-suivi.service ; systemd-analyze security ; kill -9` | `User=helios-suivi`, `MemoryMax=134217728`, `CPUQuotaPerSecUSec=500ms`, `Restart=always`, `PartOf=helios.target`, `WantedBy=helios.target`. `Overall exposure level for helios-suivi.service: 1.2 OK` (publication : `0.9 SAFE`). `GET / -> 200`, `GET /etat.json -> 200`. Après `kill -9` : `de nouveau active en 2.4 s`. Voir `e4-units.txt`. |
| **E5** sudo | `visudo -c ; sudo -l -U lea …` | `92-helios-suivi : analyse réussie`, fichier `-r--r-----. root root`. `sudo -l -U lea /usr/bin/systemctl restart helios-suivi.service` → listé ; `… restart sshd` → rc=1, rien de listé ; `journalctl -u helios-suivi.service -n 100 --vacuum-time=1s` → rc=1. Essai réel en lea : restart du portail rc=0, `restart sshd` → « lea n'est pas autorisé ». Trace dans `/var/log/sudo-suivi.log`. Voir `e5-sudo.txt`. |
| **E6** pare-feu | `firewall-cmd --zone=internal --query-port=8080/tcp` (runtime et `--permanent`) | `yes` / `yes` ; boucle sur toutes les zones : `8080 dans internal` seulement ; nftables : une seule règle `tcp dport 8080 accept`. Depuis srv-edge : `http://10.42.0.10:8080/etat.json` → `200`, `nc -zv 192.168.56.10 8080` → `No route to host` (rc=1). Voir `e6-pare-feu.txt`, `e6-e7-depuis-srv-edge.txt`, `configs/firewall-internal.txt`. |
| **E7** non-régression | `sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|allowgroups) '` | `port 2242`, `permitrootlogin no`, `passwordauthentication no`, `allowgroups ssh-admins` (identique à la fin du TP3). `ssh lea@192.168.56.10` depuis srv-edge → `Permission denied (publickey)` et côté serveur « not allowed because none of user's groups are listed in AllowGroups ». Timers et services TP1 à TP3 `active`, journald `Storage=persistent`, `Enforcing`, 12 règles auditd. Voir `e7-non-regression.txt`. |
| **E8** Zabbix | `zabbix_get -s 127.0.0.1 -k helios.suivi.http / helios.suivi.age` | Agent 7.0.32 (dépôt Zabbix, EPEL exclu), `Server=127.0.0.1` inchangé, `agent.ping` → `1`. Sondes : `200` et `60`. `zabbix-agent2` et `sysstat-collect.timer` active/enabled. Aucun AVC (`<no matches>`). Voir `e8-installation.txt`, `e8-sondes.txt`. |
| **E9** sauvegarde | `systemctl start helios-suivi-backup.service ; sha256sum -c ; tar -tvzf` | `rc=0`, `suivi-20261105-114614.tar.gz: Réussi`. L'archive contient www (avec propriétaires), les 5 units, le sudoers, la sonde et les scripts. Après 8 passages de plus : `7` archives, journal « 1 ancienne(s) supprimee(s) ». Verrou tenu → `rc=2`. Timer : `Fri 2026-11-06 03:15:00`, `Persistent=yes`. Restauration au §3. Voir `e9-sauvegarde.txt`. |
| **E10** audit (bonus) | `/usr/local/sbin/helios-suivi-audit.sh` | Serveur conforme : `Bilan : 9/9`, `rc=0` (`preuves/audit.txt`). Portail arrêté : `[KO] E4 … portail arrete`, `[KO] E8 … helios.suivi.http=000`, `rc=1`. 8080 retiré en runtime : `[KO] E6 … 8080 absent de internal (runtime)`. Après réparation : `Bilan : 9/9`. Voir `audit-pannes.txt`. Après un redémarrage complet des VM le 6 novembre (`up 10 min`) : `Bilan : 9/9`, `rc=0` sans aucune intervention (`audit-apres-reboot.txt`). |

## 2. Justifications

**(a) Durcissement de `helios-suivi.service`.** Le portail ne fait que lire `www` et écouter sur 8080, donc je lui ai tout enlevé sauf ça :
- compte dédié sans shell, `NoNewPrivileges`, `CapabilityBoundingSet=` vide (8080 > 1024, aucune capacité nécessaire) ;
- `ProtectSystem=strict` et `ProtectHome` : tout le système est en lecture seule, `/home` est invisible ;
- `PrivateTmp`, `PrivateDevices`, `ProtectKernel*`, `ProtectProc=invisible` ;
- `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `SystemCallFilter=@system-service ~@privileged @resources`, `MemoryDenyWriteExecute`, `UMask=0077`.

Score obtenu : **1.2 OK** (publication : 0.9 SAFE). Je n'ai eu aucune directive à retirer : python `http.server` démarre et répond avec tout ça, même `MemoryDenyWriteExecute`. La seule adaptation concerne l'unit de publication : avec `ProtectSystem=strict`, le script ne peut écrire que si `www` est déclaré dans `ReadWritePaths=/srv/helios/suivi/www`. Le verrou `flock` est pris sur le script lui-même, ouvert en lecture, ce qui reste possible sur un système en lecture seule.

**(b) `--x` et pas `r-x` pour zabbix sur `www`.** L'agent n'a besoin que d'atteindre un fichier dont il connaît le nom (`etat.json`) pour faire un `stat`. Le droit `x` sur un répertoire permet de le traverser. Le droit `r` permet d'en lister le contenu, donc de voir tous les fichiers déposés par l'équipe suivi, ce dont la supervision n'a pas besoin. Avec `--x` : `runuser -u zabbix -- ls www` échoue (rc=2) et `stat etat.json` réussit. J'ai retiré l'entrée pour voir (`preuves/e2-sans-acl-zabbix.txt`) : `stat` répond `Permission non accordée` et la sonde `helios.suivi.age` ne renvoie pas un nombre mais `sh: ligne 1: 1793875544 - : erreur de syntaxe`. Zabbix recevrait donc une valeur non numérique, et l'élément passerait en non supporté. Après remise de `u:zabbix:x`, la sonde renvoie `99`.

**(c) Le joker `*` dans une règle sudo `journalctl`.** Une règle `journalctl *` (ou `journalctl -u helios-suivi.service *`) accepte n'importe quels arguments après la partie fixe. lea pourrait alors lancer, en root :
- `journalctl --vacuum-time=1s` ou `--rotate`, qui suppriment les journaux archivés, donc les traces des incidents et des investigations du TP3 ;
- `journalctl -u sshd`, ou sans `-u`, qui lisent tous les journaux du système, y compris ceux des autres équipes.

Ma règle (`configs/92-helios-suivi`) liste des commandes complètes sans aucun joker : `-u helios-suivi.service -n 100` et `-u helios-suivi-publish.service -n 100`, avec et sans `--no-pager`. Sudo compare la ligne entière, donc toute option ajoutée est refusée : `sudo -l -U lea /usr/bin/journalctl -u helios-suivi.service -n 100 --vacuum-time=1s` → rc=1. La variante `--no-pager` évite de lancer `less` en root. Pour les variantes avec pager, systemd passe `less` en mode sécurisé quand il tourne sous sudo, mais je ne l'ai pas testé moi-même.

## 3. Test de restauration (E9.5)

Archive utilisée : `suivi-20261105-114626.tar.gz`, la dernière, faite par le script de sauvegarde. Sorties complètes : `preuves/e9-restauration.txt`.

(a) Extraction complète dans un répertoire de test, puis comparaison des ACL avec la production :

```
$ mkdir /root/restauration-test && tar --acls --xattrs -xzpf /srv/helios/archives/suivi/suivi-20261105-114626.tar.gz -C /root/restauration-test && ls -l /root/restauration-test/srv/helios/suivi/www
-rw-r-----+ 1 helios-suivi suivi 184  5 nov.  11:46 etat.json
-rw-rw----+ 1 lea          suivi 239  5 nov.  11:30 index.html
$ diff <(getfacl -p /srv/helios/suivi/www | grep -v '^# file') <(getfacl -p /root/restauration-test/srv/helios/suivi/www | grep -v '^# file') && echo 'ACL de www identiques a la production'
ACL de www identiques a la production
```

(b) Incident simulé : suppression de `index.html`, puis restauration de ce seul fichier :

```
$ getfacl -p /srv/helios/suivi/www/index.html > /root/acl-index-avant.txt ; rm -f /srv/helios/suivi/www/index.html ; curl … http://127.0.0.1:8080/index.html
index apres suppression : 404
$ duree tar --acls --xattrs -xzpf /srv/helios/archives/suivi/suivi-20261105-114626.tar.gz -C / srv/helios/suivi/www/index.html
duree : 0.27 s
$ ls -l /srv/helios/suivi/www/index.html ; diff /root/acl-index-avant.txt <(getfacl -p /srv/helios/suivi/www/index.html) && echo 'ACL de index.html identiques'
-rw-rw----+ 1 lea suivi 239  5 nov.  11:30 /srv/helios/suivi/www/index.html
ACL de index.html identiques
$ curl … http://127.0.0.1:8080/index.html ; ls -l --time-style=+%T /srv/helios/suivi/www ; date +%T
index restaure : 200
-rw-r-----+ 1 helios-suivi suivi 184 11:46:06 etat.json
-rw-rw----+ 1 lea          suivi 239 11:30:23 index.html
11:46:34
```

`index.html` revient avec son propriétaire lea, sa date d'origine et ses ACL. `etat.json` n'a pas été touché (11:46:06, antérieur à la restauration). Temps : l'extraction du fichier prend **0,27 s**. L'ensemble (a) + (b) a pris **2 s** à l'horloge (11:46:32 → 11:46:34), parce que les commandes étaient prêtes dans le script. À la main, il faut surtout le temps de retrouver le chemin exact dans l'archive (`tar -tzf`) : le chemin est relatif (`srv/helios/…`, sans `/` au début) et il faut extraire avec `-C /`.

## 4. Mesure sous charge

Pendant les 2000 `curl` (`preuves/charge.txt`) : `real 1m54,224s`. `CPUUsageNSec` du portail passe de 1 072 885 000 à 12 097 037 000, soit **11,0 s de CPU en 114 s (9,7 % d'un CPU)**. `MemoryCurrent` passe de 10,58 Mo à 10,59 Mo (pic 10,88 Mo, pour un plafond de 128 Mo). `sar -u` sur 40 s : `%user 38.80  %system 46.43  %idle 12.16`.

Le quota `CPUQuota=50%` n'a presque pas joué : `nr_throttled 1` sur 1737 périodes (7,5 ms bridées en tout). La machine (1 vCPU) est saturée par la boucle cliente, qui lance 2000 processus `curl`, et non par le portail, qui reste vers 10 %.

## 5. Limites connues

- **UID de lea.** La fiche impose l'UID 5104, déjà pris par le compte `sysops` créé au TP3. J'ai renuméroté `sysops` en 5105 (`preuves/e1-conflit-uid.txt`). Son `authorized_keys` a suivi, et la connexion par clé depuis srv-edge fonctionne toujours (le `scp` de l'étape edge passe). C'est quand même une modification d'un compte du TP3, que je signale.
- **Mon script d'audit avait deux faux KO** au premier passage (7/9 sur un serveur conforme). D'abord, `set -o pipefail` combiné à `grep -q` : grep s'arrête au premier résultat, `tar -tzf` reçoit SIGPIPE et le pipeline est faux (« index.html absent de l'archive »). Ensuite, le score de `systemd-analyze` était lu en avant-dernier champ, alors que la ligne finit par un émoji (« exposition OK > 4.0 »). Corrigé avec une fonction `cherche` (qui lit toute l'entrée) et en prenant le champ numérique. Le même défaut de `grep -q` pouvait aussi donner un faux OK sur le contrôle des jokers sudo, ce qui est pire, et c'est corrigé aussi.
- Juste après un redémarrage du portail, l'audit peut sortir un KO passager (curl `000` pendant les 2 à 3 s que python met à démarrer sur 1 vCPU). C'est pour ça que l'audit avec 8080 retiré donne 7/9 et pas 8/9. Il faudrait réessayer le curl quelques secondes avant de conclure.
- La sonde `helios.suivi.age` renvoie un texte d'erreur et pas une erreur propre si `stat` échoue. Avec une journée de plus, j'en ferais un petit script qui sort avec un code non nul.
- `sar -u 1 40` ne couvre que les 40 premières secondes des 114 s de la boucle. La moyenne est juste pour cette fenêtre, pas pour toute la charge.
- `python3 -m http.server` est un serveur de démonstration : pas de TLS, et il affiche la liste des fichiers si `index.html` manque (cas de l'incident E9.5 pendant 2 s). En vrai, je mettrais nginx avec `autoindex off`.
- Les 7 archives restent sur le même disque que la production. Il faudrait en copier une hors de la machine (srv-edge ou un NAS).
- Le redémarrage de vérification a été fait le 6 novembre (les deux VM relancées, audit à 9/9 après 10 min). Je n'ai pas mesuré combien de temps après le démarrage le portail répond pour la première fois.
- Depuis srv-edge, 192.168.56.10:8080 est refusé (« No route to host », c'est le `reject` de la zone `work` du TP3) et non ignoré en silence. Le port est bien fermé, mais il ne paraît pas « filtered » au sens nmap.
