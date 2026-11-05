# TP3 — Sécurisation d'un serveur Linux : pare-feu, SSH, journaux

**Auteur :** David.K · **Module :** Administration d'un Linux Server (BTC2) · **Jour 3/5** (suite des TP1 et TP2)
**Environnement :** `srv-core2` (Rocky Linux 9, hostname `srv-core`, la cible) et `srv-edge` (Ubuntu 24.04, joue l'administrateur et l'attaquant)

Les sorties citées sont dans `captures/`. Elles ont été produites le 4 novembre 2026 par `scripts/tp3.sh` : étapes `m0` à `fin` sur srv-core, `e1` à `e6` sur srv-edge. Les fichiers `edge-*.txt` ont été produits sur srv-edge, puis envoyés à srv-core par `scp` sur le port 2242. Les fichiers déployés sont dans `configs/`, les captures d'écran dans `captures/ecrans/`. Le rendu illustré de 5 pages est `RENDU.pdf`.

## 0. Réseau d'administration

Le TP suppose une interface d'administration `enp0s8` en 192.168.56.0/24, que mes VM n'avaient pas. J'ai réglé l'adaptateur 2 de chaque VM en **réseau privé hôte** VirtualBox (l'hôte Windows est 192.168.56.1).

- **srv-core** : profil NetworkManager `admin`, 192.168.56.10/24, sans passerelle (`ipv4.never-default`).
- **srv-edge** : `netplan set ethernets.enp0s8.addresses=[192.168.56.11/24]`.

Le ping de srv-edge vers srv-core passe. Le ping vers l'hôte .1 ne passe pas, car le pare-feu Windows bloque l'ICMP.

---

## Mission 1 — Pare-feu firewalld segmenté par zone

### Interface → zone → politique

| Interface | Connexion NM | Zone | Politique | Justification |
|---|---|---|---|---|
| `enp0s3` (NAT) | `enp0s3` | **drop** | rien n'entre, sans réponse | Le NAT ne sert qu'aux sorties (dnf, git). `drop` ne répond même pas : un scan n'apprend rien. Les réponses aux connexions sortantes passent (suivi d'état). |
| `enp0s8` (admin) | `admin` | **work** | SSH seulement, depuis 192.168.56.0/24, avec journalisation et limite de débit | C'est le seul chemin d'administration. La règle riche limite le *brute force*. Le port Zabbix est rejeté explicitement. |
| `bond0` (métier) | `bond0` | **internal** | SSH, et 10051/tcp pour la supervision au TP4 | Réseau métier de confiance. Les services hérités inutiles (mdns, samba-client, cockpit, dhcpv6-client) sont retirés. |
| `bond0.42` (VLAN transport) | `bond0.42` | **internal** | idem | Même niveau de confiance que le réseau métier. |
| zone par défaut | — | **drop** | — | Une interface ajoutée plus tard sans zone est fermée par défaut. |

La zone se déclare **dans le profil NetworkManager** (`nmcli con mod … connection.zone`), sinon elle serait perdue au prochain `nmcli con up`. Les ports physiques du bond (`enp0s9`, `enp0s10`) apparaissent dans la zone par défaut `drop` : c'est sans effet, car le noyau présente les paquets avec `iif=bond0` (ou `bond0.42`), donc ils passent par la zone `internal`.

### Règles riches, ipset, refus journalisés

- `rule service name="ssh" log prefix="SSH-NEW " level="info" limit value="3/m" accept limit value="6/m"` :
  - chaque nouvelle connexion SSH est journalisée par le noyau (au plus 3 lignes par minute) et acceptée dans la limite de 6 par minute ;
  - au-delà, le paquet tombe sur la cible par défaut de la zone : `REJECT` avec `icmp admin-prohibited` ;
  - la limite nftables a une **rafale de 5** : dans la rafale de 12 `nc` depuis srv-edge, les connexions 1 à 4 passent (le scan nmap et le `nc` précédent avaient déjà consommé une partie de la rafale), puis « No route to host » (`captures/edge-e2-apres.txt`).
- `rule port port="10051" protocol="tcp" reject` sur `work` : Zabbix n'est joignable que depuis le réseau métier. `nc` vers 10051 donne « Connection refused ».
- ipset `helios-blacklist` (`hash:ip`, `maxelem 65536`) avec une règle `drop` en tête des zones `work` et `internal`. Il est alimenté par la mission 3.
- `--set-log-denied=unicast` : tout refus est tracé avec le préfixe `filter_IN_work_REJECT`.

### Ce que firewalld a écrit (`captures/m1-nftables.txt`)

`nft list tables` ne montre qu'une table `inet firewalld` : firewalld 1.x génère directement du nftables. La chaîne `filter_IN_work` enchaîne `_pre`, `_log`, `_deny`, `_allow` et `_post`, puis accepte l'ICMP, journalise et rejette avec `admin-prohibited`. `iptables -S` ne renvoie que des politiques `ACCEPT` vides : iptables n'est plus qu'une couche de compatibilité, et les vraies règles ne sont pas là.

### Avant / après (nmap depuis srv-edge)

| Port | Avant (firewalld arrêté au TP1) | Après la mission 1 | Après la mission 2 |
|---|---|---|---|
| 22/tcp | open | open (limité) | **filtered** |
| 2242/tcp | — | — | **open** |
| 80, 111, 9090 | closed (le noyau répond RST) | **filtered** | filtered |
| 10051 | closed | filtered (reject depuis work) | filtered |

« closed » révélait que la machine existe et répond. Avec `drop` et le reject `admin-prohibited`, nmap ne voit plus que des ports filtrés.

---

## Mission 2 — Durcissement de sshd

### Préparation

Le groupe système `ssh-admins` regroupe sysops et julien. sysops a été créé sur les deux VM. Sur srv-edge, sa clé **ed25519** a été générée (`-a 100` : 100 tours de KDF pour protéger la clé privée), puis déposée avec `ssh-copy-id` pendant que le mot de passe était encore accepté. La connexion par clé a été vérifiée (`rc=0`) **avant** toute coupure. Sur srv-core, `authorized_keys` est en `0600 sysops:sysops`. Les empreintes des clés d'hôte (ECDSA, ED25519, RSA) sont dans `captures/m2-prep.txt`.

### Drop-in `10-helios-hardening.conf`

| Directive | Rôle |
|---|---|
| `Port 2242`, `AddressFamily inet`, `ListenAddress 192.168.56.10` et `10.42.0.10` | Écoute uniquement sur les réseaux d'administration et métier, jamais sur le NAT, et en IPv4 seulement. |
| `PermitRootLogin no` | root ne se connecte jamais directement : on passe par un compte nominatif, puis sudo (traçabilité). |
| `PubkeyAuthentication yes`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitEmptyPasswords no` | Plus aucune authentification par secret mémorisable. |
| `AuthenticationMethods publickey` | Seule méthode acceptée (voir le bonus). |
| `MaxAuthTries 3`, `LoginGraceTime 30`, `MaxStartups 10:30:60`, `MaxSessions 4` | Limitent le *brute force* et les connexions non authentifiées (refus aléatoire de 30 % au-delà de 10, refus total à 60). |
| `AllowGroups ssh-admins` | Liste blanche par groupe : un compte valide hors groupe est refusé (nadia, root). |
| `X11Forwarding`, `AllowAgentForwarding`, `AllowTcpForwarding`, `AllowStreamLocalForwarding`, `PermitTunnel`, `GatewayPorts` à `no` | Pas de pivot à travers le serveur. |
| `PermitUserEnvironment no` | Empêche `~/.ssh/environment` d'injecter `LD_PRELOAD` et autres. |
| `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `TCPKeepAlive no` | Coupe une session morte après 10 min, avec un keepalive dans le canal chiffré (non usurpable). |
| `LogLevel VERBOSE` | Journalise l'empreinte de la clé utilisée, utile à l'investigation. |
| `Banner /etc/issue.net`, `PrintLastLog yes` | Avertissement légal et dernière connexion. |
| `Subsystem sftp internal-sftp -l INFO -f AUTHPRIV` | SFTP sans binaire externe, journalisé en authpriv. |
| `Match Group helios-ops` / `AllowTcpForwarding yes` / `PermitOpen localhost:10051` | Exception maîtrisée : seul helios-ops peut ouvrir un tunnel, et seulement vers Zabbix local. |

`sshd -t` valide la syntaxe avant tout redémarrage.

### Crypto-policies et sshd_config : l'interaction

Sur Rocky 9, `/etc/ssh/sshd_config` commence par `Include /etc/ssh/sshd_config.d/*.conf`. Les fichiers sont lus par ordre alphabétique, et `50-redhat.conf` inclut `/etc/crypto-policies/back-ends/opensshserver.config`. **sshd retient la première valeur lue** pour chaque mot-clé, donc :

1. Un `Ciphers`, `KexAlgorithms` ou `MACs` écrit après `50-redhat.conf` (dans `sshd_config` ou un `60-*.conf`) est **ignoré en silence**.
2. Pour agir localement, il faut un fichier au nom inférieur, d'où `05-helios-crypto.conf`, et **hors d'un bloc `Match`**. Ajouté en fin de `10-helios-hardening.conf`, il tomberait dans le `Match Group`, et `sshd -t` le refuserait.
3. Le mécanisme `CRYPTO_POLICY=` de `/etc/sysconfig/sshd` (RHEL 8) n'existe plus sur RHEL 9.

L'approche recommandée reste la politique système : `update-crypto-policies --set DEFAULT:NO-SHA1`. Elle s'applique à **toutes** les bibliothèques (OpenSSL, GnuTLS, NSS, libssh). Constat : avec `DEFAULT:NO-SHA1`, sshd propose encore `hmac-sha1` et `hmac-sha1-etm` en MAC. Le sous-module NO-SHA1 retire SHA-1 des **signatures et des échanges de clés**, pas des MAC. C'est le drop-in `05-helios-crypto.conf` qui ramène les listes à `chacha20-poly1305` / `aes256-gcm` / `aes256-ctr`, `curve25519` / `dh-group16-sha512` et `hmac-sha2-*-etm`. Le test 7 le confirme : un client qui n'offre que `diffie-hellman-group14-sha1` reçoit « no matching key exchange method found ».

### Les trois conséquences d'un changement de port SSH sur RHEL 9

1. **SELinux** : sshd (domaine `sshd_t`) n'a le droit de se lier (`name_bind`) qu'aux ports de type `ssh_port_t`. Démonstration : `systemctl restart sshd` échoue (`status=255`) et `ausearch -m AVC` montre `avc: denied { name_bind } … src=2242 … tcontext=…unreserved_port_t`. Après `semanage port -a -t ssh_port_t -p tcp 2242`, sshd démarre.
2. **Pare-feu** : le service `ssh` de firewalld désigne le port 22. Il faut ouvrir 2242 (`--add-port` en `internal`, règle riche sur le port en `work`) et retirer l'ancien. Sinon on se coupe l'accès.
3. **Clients et outils** : tous les clients doivent préciser `-p 2242` (ou `Port 2242` dans `~/.ssh/config`) et `known_hosts` crée une nouvelle entrée `[192.168.56.10]:2242`. Les outils qui supposent le port 22 sont aussi touchés : supervision, sauvegardes, Ansible.

Constat supplémentaire au redémarrage : avec des `ListenAddress` explicites, sshd démarre avant que NetworkManager ait posé les IP. Il échoue (« Bind to port 2242 on 10.42.0.10 failed: Cannot assign requested address »), puis `Restart=on-failure` le relance environ 40 s plus tard (`captures/m3-requetes.txt`). Correctif propre : un drop-in `After=network-online.target` / `Wants=network-online.target` sur `sshd.service`, ou `net.ipv4.ip_nonlocal_bind=1`.

### Les sept tests depuis srv-edge (`captures/edge-e4-tests.txt`, `captures/m2-traces.txt`)

| # | Test | Résultat | Trace côté srv-core |
|---|---|---|---|
| 1 | `nc -zv 192.168.56.10 22` | **échec** (rc=1, « No route to host ») | `filter_IN_work_REJECT … DPT=22` |
| 2 | `ssh -p 2242 sysops@…` | **succès** par clé, bannière affichée, `id -nG` = `sysops ssh-admins` | `Accepted publickey for sysops … ED25519 SHA256:sLai…` |
| 3 | `ssh -p 2242 root@…` | **refus** (rc=255, « Permission denied (publickey) ») | `User root … not allowed because none of user's groups are listed in AllowGroups` |
| 4 | mot de passe forcé | **refus** (rc=255) : le serveur ne propose que `publickey` | `Connection closed by authenticating user sysops … [preauth]` |
| 5 | `ssh -p 2242 nadia@…` | **refus** (rc=255) | `User nadia … not allowed because … AllowGroups` |
| 6 | tunnel `-L 9999:localhost:10051` | l'écoute locale s'ouvre, mais l'usage échoue : « channel 2: open failed: administratively prohibited » (sysops n'est pas dans helios-ops) | refus du `direct-tcpip` |
| 7 | `-o KexAlgorithms=diffie-hellman-group14-sha1` | **refus** (rc=255) | `Unable to negotiate … no matching key exchange method found` |

`sshd -T` confirme : `port 2242`, `permitrootlogin no`, `passwordauthentication no`, `allowgroups ssh-admins`, `maxauthtries 3`, `loglevel VERBOSE`, `authenticationmethods publickey`. `semanage port -l` donne `ssh_port_t tcp 2242, 22`.

---

## Mission 3 — Journaux et détection

### journald persistant (`configs/50-helios.conf`)

Les réglages : `Storage=persistent`, `SystemMaxUse=500M`, `SystemKeepFree=1G`, `SystemMaxFileSize=50M`, rotation quotidienne (`MaxFileSec=1day`), rétention d'un mois, `RateLimitBurst=10000` par 30 s (on ne perd pas une rafale d'attaque) et `ForwardToSyslog=no`.

`journalctl --flush` crée `/var/log/journal/<machine-id>/` tout de suite, et `journalctl --verify` répond `PASS`. `Seal=yes` n'agit qu'avec une clé FSS : j'ai lancé `journalctl --setup-keys` et la **clé de vérification est conservée hors du dépôt** (`/root/journald-fss-verification.key`, mode 600). Elle sert à prouver qu'un journal n'a pas été modifié après coup.

Preuve de persistance : avant la configuration, `--list-boots` ne montrait qu'**un** démarrage. Après, il en liste **5**, dont `-3` à 14:45, le démarrage d'avant la configuration, toujours consultable.

### Cinq requêtes d'investigation et ce qu'elles révèlent (`captures/m3-requetes.txt`)

1. **`journalctl -u sshd.service --since '-2h' -p warning`** : seulement les erreurs de sshd, avec le numéro de démarrage. Elle révèle l'échec SELinux (`status=255/EXCEPTION`) et, à chaque démarrage, l'échec `Bind to port 2242 … Cannot assign requested address`. C'est la course entre sshd et le réseau décrite plus haut.
2. **`journalctl _SYSTEMD_UNIT=sshd.service -g 'Invalid user|Failed|Accepted'`** : la chronologie des authentifications. Les `Accepted publickey for sysops` portent l'empreinte de la clé (LogLevel VERBOSE), puis viennent cinq `Invalid user pirate from 192.168.56.11`. Seules 5 tentatives sur 10 atteignent sshd, les autres sont absorbées par la limite du pare-feu.
3. **`journalctl --facility=authpriv --since today`** : tout ce qui touche à l'authentification (PAM, gdm, sudo, polkit, sshd en écoute, et les messages de `helios-watch-auth` toutes les 2 minutes). C'est la vue de « qui s'est connecté à la machine et comment ».
4. **`journalctl _UID=5101 --since today`** : l'activité de nadia. Résultat vide (« No entries ») : nadia n'a rien fait sur la machine aujourd'hui, ce qui confirme que son refus SSH (test 5) n'a ouvert aucune session.
5. **`lastb` / `last -F`** : `lastb` (fichier `btmp`) liste les connexions SSH ratées de `pirate` depuis 192.168.56.11, et les essais de mot de passe de nadia du TP2 (faillock). `last -F` montre les démarrages, les ouvertures de session et un « crash » à 15:27. C'est un arrêt non propre, à recouper avec `journalctl -b -1`.

Compléments :

- `journalctl -t sudo -o json-pretty` montre les champs de confiance (`_AUDIT_LOGINUID=1000`, `_CMDLINE=sudo -i`, `_EXE`), que l'utilisateur ne peut pas falsifier contrairement au texte du message.
- `journalctl -b -1 -p err` (démarrage précédent) ne montre que des avertissements matériels propres à VirtualBox (pilote e1000 non maintenu, vmwgfx).
- `lslogins` résume la dernière connexion et le dernier échec par compte.

### auditd (`configs/90-helios.rules`)

`auditctl -l` liste **12 règles** :

- surveillance en écriture et attributs (`-p wa`) de `passwd`, `shadow`, `group`, `gshadow`, `sudoers`, `sudoers.d/`, `sshd_config` et `sshd_config.d/` ;
- surveillance de l'**exécution** (`-p x`) de `helios-lastlog` ;
- `execve` en 64 et 32 bits par un compte humain (`auid>=1000`) devenu root (`euid=0`) ;
- surveillance de `/etc/firewalld/`.

Les règles 32 bits ferment le contournement par un binaire i386. `auid!=unset` exclut les démons.

Exploitation :

- `ausearch -k sudoers -i` montre le `touch` / `rm` de `/etc/sudoers.d/test-audit` (`proctitle=touch …`, `auid=dav`, `uid=root`) ;
- `ausearch -k helios-setgid` montre l'exécution du binaire par julien ;
- `ausearch -k privesc` montre chaque commande root lancée par dav via `sudo -i` (`auid=dav uid=root`), même après le changement d'identité. C'est l'intérêt de l'**auid**, qui suit l'utilisateur à travers su et sudo ;
- `aureport --auth/--failed/-k --summary` donne les synthèses (11 authentifications échouées, clés `privesc` et `identity` en tête).

### Détection automatique (`configs/helios-watch-auth.sh` + `.service` + `.timer`)

Le script suit le modèle « script robuste » du TP1 :

- `set -euo pipefail`, `IFS` strict, `trap ERR` ;
- **verrou `flock -n`** sur `/run/helios-watch-auth.lock` : une seconde instance sort en **rc=2** ;
- journalisation par `logger -t helios-watch-auth` (priorités info, notice, warning, err).

Fonctionnement :

1. Il lit `journalctl -u sshd --since -10min` (fenêtre glissante) et ne garde que les événements d'échec : `Invalid user`, `Failed …`, `Connection closed by invalid|authenticating user`, `not allowed because…`, `maximum authentication attempts`.
2. Il compte ces événements par adresse IP.
3. Au-delà de **5**, l'adresse est ajoutée à l'ipset (runtime) et notée dans `/var/lib/helios/blocked.txt`, avec une `ALERTE` en priorité *warning*.
4. **Liste blanche** en dur : `192.168.56.1` (poste du formateur, ici l'hôte) et `127.0.0.1`.
5. **Idempotence** : une adresse déjà présente dans l'ipset est ignorée sans message. Une adresse connue dans `blocked.txt` mais absente de l'ipset (après un `--reload`) est remise sans nouvelle alerte.

Remarque honnête sur le comptage : une connexion d'utilisateur inconnu produit **deux** événements (`Invalid user` puis `Connection closed by invalid user`). L'attaque de 10 essais n'a fait passer que 5 connexions à travers la limite 6/m, soit 10 événements, donc au-dessus du seuil. Compter par connexion (PID `sshd-session`) serait plus juste, mais avec la limite du pare-feu le seuil « plus de 5 » ne serait alors jamais atteint en une rafale.

L'unité `helios-watch-auth.service` est de type `oneshot`, avec `SuccessExitStatus=2`, `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`, `NoNewPrivileges` et `Nice=10`. Le timer utilise `OnCalendar=*:0/2`, `AccuracySec=10s`, `Persistent=no` (rattraper une analyse manquée n'a pas de sens pour une fenêtre glissante). `systemd-analyze verify` répond OK.

**Test** (`captures/edge-e5-attaque.txt`, `captures/m3-blocage.txt`) :

1. srv-edge lance 10 essais `pirate@`, qui renvoient tous rc=255.
2. Le timer de 16:10 journalise `ALERTE : 192.168.56.11 bloquee (10 echecs SSH en 10min, seuil 5)`. `firewall-cmd --ipset=helios-blacklist --get-entries` et `nft list set` contiennent **192.168.56.11**.
3. Depuis srv-edge, `nc` et `ssh` vers 2242 **expirent** : l'ipset applique un `drop`, sans réponse.
4. Les passages suivants du timer affichent « 1 source(s) en echec, 0 nouveau(x) blocage(s) », avec une seule `ALERTE`. Le lancement en parallèle d'une instance qui tient le verrou donne **rc=2**.
5. Déblocage : arrêt du timer, puis `--remove-entry`, nettoyage de `blocked.txt`, et `systemd-run --on-active=11min` pour relancer le timer après la sortie de la fenêtre. srv-edge se reconnecte (`edge-e6-retabli.txt`, rc=0), et `list-timers` affiche de nouveau une prochaine exécution.

Limite : l'entrée d'ipset est *runtime*, donc un `firewall-cmd --reload` ou un redémarrage la purge. Le script la remet au passage suivant tant que l'adresse est dans `blocked.txt`. Pour un vrai bannissement temporaire, il faudrait un `timeout` sur l'ipset ou fail2ban.

---

## Bonus

1. **Immuabilité d'auditd** (`captures/bonus-immuable.txt`). Avec `-e 2` en fin de règles, `auditctl -s` affiche `enabled 2`. `auditctl -D` échoue (« Operation not permitted ») et l'ajout d'une règle aussi (« The audit system is in immutable mode »). Même root ne peut plus effacer ses traces avant le prochain redémarrage. Retour à `-e 1` : le fichier est corrigé, et le changement ne prend effet qu'**au démarrage suivant** (`enabled 1` ensuite).
2. **Rapports** : `aureport --start this-week --summary` donne 4 198 événements, 16 connexions ratées, 2 AVC et 6 clés. `aureport --executable --summary` place en tête `systemd`, `sshd-session`, `su` et `sudo`.
3. **Revue crypto** :
   - `ssh -Q cipher` et `ssh -Q kex` montrent que le **client** connaît encore `3des-cbc`, `aes*-cbc`, `diffie-hellman-group1-sha1` et `group14-sha1`. Le serveur, lui, n'offre plus que des primitives AEAD ou ETM et des KEX à courbe 25519 ou DH 4096 bits SHA-512, ce qui est l'état de l'art.
   - **`AuthenticationMethods publickey` est plus fort que `PasswordAuthentication no` seul**. `PasswordAuthentication no` ne ferme qu'une méthode : `keyboard-interactive` (PAM), `hostbased` ou `gssapi` resteraient possibles si elles sont activées ailleurs ou réactivées par un drop-in lu plus tôt. Sur RHEL, `KbdInteractiveAuthentication` via PAM demande justement un mot de passe. `AuthenticationMethods` est une **liste blanche** : toute session doit avoir réussi `publickey`, quelle que soit la méthode activée par ailleurs. Il permet aussi d'exiger plusieurs facteurs (`publickey,keyboard-interactive`).
