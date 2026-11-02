# TP1 — Configuration avancée du système Linux

**Auteur :** David.K · **Module :** Administration d'un Linux Server (BTC2) · **Jour 1/5**
**Environnement :** `srv-core` (Rocky Linux 9) + `srv-edge`

Toutes les sorties citées ici sont dans `captures/`, produites par `scripts/tp1.sh`. Les valeurs entre accolades doubles sont remplies automatiquement par `./scripts/tp1.sh collecte`.

---

## Préparation des VM

Au départ, `srv-core` et `srv-edge` n'avaient qu'une carte NAT (`captures/ecrans/00-*.jpg`). VM éteintes, j'ai ajouté dans VirtualBox :

| VM | Adaptateur | Mode | Nom réseau | Interface invitée |
|---|---|---|---|---|
| srv-core | 1 | NAT | — | `enp0s3` |
| srv-core | 3 | Réseau interne | `helios-lan` | `enp0s9` (bond, primaire) |
| srv-core | 4 | Réseau interne | `helios-lan` | `enp0s10` (bond, secours) |
| srv-edge | 1 | NAT | — | `enp0s3` |
| srv-edge | 3 | Réseau interne | `helios-lan` | `enp0s9` |

Captures : `captures/ecrans/01-*.jpg` à `03-*.jpg`. Le TP est finalement mené sur une réinstallation de srv-core nommée `srv-core2` (Rocky Linux 9), qui a reçu les mêmes cartes 3 et 4 sur `helios-lan` (`captures/ecrans/06-*.jpg`).

## Mission 1 — Services, processus et séquence de démarrage

### 1.1 Temps de démarrage

| | Mesure `systemd-analyze` |
|---|---|
| **Avant** | Startup finished in 7.813s (kernel) + 18.562s (initrd) + 1min 28.084s (userspace) = 1min 54.460s |
| **Après** | Startup finished in 5.664s (kernel) + 18.489s (initrd) + 1min 18.195s (userspace) = 1min 42.349s |

`systemd-analyze blame` (15 premières unités) — avant :

```
1min 10.580s kdump.service
     23.778s dev-disk-by\x2duuid-c9701013\x2d14d3\x2d41ae\x2da8a9\x2d71cbeb03be8a.device
     23.778s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1.0\x2dpart1.device
     23.778s dev-sda1.device
     23.778s sys-devices-pci0000:00-0000:00:0d.0-ata3-host2-target2:0:0-2:0:0:0-block-sda-sda1.device
     23.778s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1\x2dpart1.device
     23.778s dev-disk-by\x2did-ata\x2dVBOX_HARDDISK_VBbd3e7cb9\x2dc8b7ea63\x2dpart1.device
     23.778s dev-disk-by\x2dpartuuid-c4833c3a\x2d01.device
     23.390s dev-sda.device
     23.390s dev-disk-by\x2ddiskseq-1.device
     23.385s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1.0.device
     23.385s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1.device
     23.385s dev-disk-by\x2did-ata\x2dVBOX_HARDDISK_VBbd3e7cb9\x2dc8b7ea63.device
     23.385s sys-devices-pci0000:00-0000:00:0d.0-ata3-host2-target2:0:0-2:0:0:0-block-sda.device
     23.115s sys-devices-platform-serial8250-tty-ttyS2.device
```

Après :

```
43.669s kdump.service
33.799s dev-disk-by\x2did-ata\x2dVBOX_HARDDISK_VBbd3e7cb9\x2dc8b7ea63\x2dpart1.device
33.798s dev-disk-by\x2dpartuuid-c4833c3a\x2d01.device
33.798s sys-devices-pci0000:00-0000:00:0d.0-ata3-host1-target1:0:0-1:0:0:0-block-sda-sda1.device
33.798s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1\x2dpart1.device
33.798s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1.0\x2dpart1.device
33.782s dev-sda1.device
33.782s dev-disk-by\x2duuid-c9701013\x2d14d3\x2d41ae\x2da8a9\x2d71cbeb03be8a.device
33.761s dev-disk-by\x2did-ata\x2dVBOX_HARDDISK_VBbd3e7cb9\x2dc8b7ea63\x2dpart2.device
33.761s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1\x2dpart2.device
33.761s dev-disk-by\x2dpath-pci\x2d0000:00:0d.0\x2data\x2d1.0\x2dpart2.device
33.761s dev-sda2.device
33.761s sys-devices-pci0000:00-0000:00:0d.0-ata3-host1-target1:0:0-1:0:0:0-block-sda-sda2.device
33.761s dev-disk-by\x2dpartuuid-c4833c3a\x2d02.device
33.302s dev-sda.device
```

Chronogrammes : `captures/boot-avant.svg`, `captures/boot-apres.svg`.

**Analyse.** Le boot passe de 1 min 54,5 s à 1 min 42,3 s (−12 s, surtout côté userspace : 1 min 28 s → 1 min 18 s). Sur cette VM, l'unité la plus pénalisante n'est pas `NetworkManager-wait-online` mais `kdump.service` (1 min 10,6 s puis 43,7 s) : elle charge le noyau de capture pour les crash dumps. Les lignes `dev-*.device` de 23 à 34 s ne sont pas des unités « lentes ». Elles indiquent seulement *quand* le disque virtuel a été vu par udev, ce qui dépend de l'hôte VirtualBox. Pour gagner encore 40 à 70 s, il faudrait `systemctl disable kdump` (acceptable sur une VM de labo, à éviter en production où l'on veut un dump après un plantage noyau). Je ne l'ai pas fait car l'énoncé ne le demande pas.

**Unités désactivées et justification**

| Unité | Action | Justification |
|---|---|---|
| `NetworkManager-wait-online.service` | `mask` | Bloque le boot jusqu'à ce que *toutes* les connexions NM soient montées (jusqu'à 30 s si un lien est absent). C'est presque toujours l'unité la plus longue de `blame`. `mask` (lien vers `/dev/null`) plutôt que `disable` car elle est tirée par `network-online.target` : un simple `disable` n'empêcherait pas son démarrage. Le collecteur n'a pas besoin du réseau pour écrire en local. |
| `firewalld.service` | `disable --now` | Temporaire, demandé par l'énoncé pour ne pas filtrer le bond, le VLAN 42 et les tests ICMP. **Il sera réactivé au TP3.** Sur un serveur de production on ne le couperait pas. |

### 1.2 Le service `helios-collect.service`

Fichier : `configs/helios-collect.service`. Rôle de chaque directive :

| Directive | Rôle |
|---|---|
| `After=` / `Wants=network-online.target` | Ordre (démarre après) + dépendance faible (demande la target sans échouer si elle échoue). |
| `Type=simple` | Le processus lancé par `ExecStart` est le processus principal ; pas de fork. |
| `User=` / `Group=helios` | Compte système sans shell : le collecteur ne tourne pas en root. |
| `Environment=HELIOS_INTERVAL=15` | Variable lue par le script (`${HELIOS_INTERVAL:-15}`). |
| `Restart=on-failure` + `RestartSec=5s` | Relance après sortie non nulle, signal non propre (dont `SIGKILL`), timeout ou watchdog. Attente de 5 s entre deux relances. |
| `TimeoutStopSec=20s` | Délai entre `SIGTERM` et `SIGKILL` à l'arrêt. |
| `NoNewPrivileges=yes` | Interdit tout gain de privilège (setuid, capabilities de fichier). |
| `PrivateTmp=yes` | `/tmp` et `/var/tmp` privés au service. |
| `ProtectSystem=strict` | Toute l'arborescence est en lecture seule… |
| `ReadWritePaths=/var/lib/helios /var/log/helios` | …sauf ces deux répertoires. |
| `ProtectHome=yes` | `/home`, `/root`, `/run/user` inaccessibles. |
| `ProtectKernelTunables=yes` | `/proc/sys`, `/sys` en lecture seule. |
| `ProtectControlGroups=yes` | `/sys/fs/cgroup` en lecture seule. |
| `RestrictSUIDSGID=yes` | Interdit de créer des fichiers setuid/setgid. |
| `CapabilityBoundingSet=` (vide) | Aucune capability Linux possible. |
| `WantedBy=multi-user.target` | `enable` crée le lien dans `multi-user.target.wants/`. |

**Score `systemd-analyze security`**

| | Exposition |
|---|---|
| Unit d'origine | 5.3 MEDIUM 😐 |
| Unit + drop-in durci | 0.7 SAFE 😀 |

Détail complet : `captures/security-avant.txt`, `captures/security-apres.txt`. Plus le score est bas, moins le service est exposé.

### 1.3 Redémarrage automatique et drop-in

**Preuve `kill -9`** (`captures/kill9.txt`) : après `kill -9` du `MainPID`, le service repasse `active (running)` au bout de ~5 s avec un **nouveau PID** et `NRestarts` incrémenté. `SIGKILL` est un signal « non propre », donc couvert par `Restart=on-failure`.

**Drop-in** : `configs/override.conf`, déployé dans `/etc/systemd/system/helios-collect.service.d/override.conf` (c'est exactement ce que produit `systemctl edit`). L'unit d'origine n'est pas modifiée : une mise à jour du paquet ou une réinstallation ne fait pas perdre le réglage local, et `systemctl cat` montre clairement l'empilement.

| Directive | Effet observé (`captures/dropin.txt`) |
|---|---|
| `Environment=HELIOS_INTERVAL=5` | Une ligne toutes les 5 s dans `telemetry.csv` au lieu de 15. |
| `CPUQuota=20%` | `CPUQuotaPerSecUSec=200ms` (cgroup `cpu.max`). |
| `MemoryMax=96M` | `MemoryMax=100663296` (96 × 1024²) — au-delà, l'OOM killer frappe dans le cgroup. |
| `IOWeight=50` | Poids E/S relatif (défaut 100) : moitié moins prioritaire en contention. |
| `Nice=5` | Priorité CPU d'ordonnancement légèrement abaissée. |

Durcissement ajouté dans le même drop-in (le collecteur ne fait que lire `/proc/loadavg`, `/proc/meminfo` et écrire un CSV) : `PrivateNetwork`, `PrivateDevices`, `PrivateUsers`, `ProtectKernelModules`, `ProtectKernelLogs`, `ProtectClock`, `ProtectHostname`, `RestrictNamespaces`, `RestrictRealtime`, `LockPersonality`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies=AF_UNIX` (journald seulement), `SystemCallArchitectures=native`, `SystemCallFilter=@system-service ~@privileged`, `UMask=0027`.
Choix volontaire : **pas** de `ProcSubset=pid`, qui masquerait `/proc/loadavg` et `/proc/meminfo` et ferait planter le collecteur.

### 1.4 Target métier et priorités

`configs/helios.target` regroupe la pile applicative ; `systemctl add-wants` crée `/etc/systemd/system/helios.target.wants/helios-collect.service`. `AllowIsolate=no` empêche un `systemctl isolate helios.target` qui couperait tout le reste. `systemctl stop/start helios.target` arrête et relance le collecteur d'un coup (`captures/target.txt`).

Priorités (`captures/priorites.txt`) :

- `nice -n 19` lance `sha256sum` au niveau le moins prioritaire (NI=19).
- `renice -n 5` : root peut **remonter** la priorité d'un processus en cours (19 → 5) ; un utilisateur normal ne pourrait que la baisser.
- `ionice -c 2 -n 7` : classe *best-effort*, niveau 7 (le plus faible de la classe).
- `chrt -p` : politique `SCHED_OTHER`, priorité temps réel 0 — c'est un processus ordinaire, pas temps réel.

---

## Mission 2 — Réseau avancé

### 2.1 / 2.2 Bond `active-backup`

Options : `mode=active-backup` (un seul lien actif, l'autre en secours), `miimon=100` (état des liens vérifié toutes les 100 ms), `primary=enp0s9` (lien préféré, repris dès son retour), `fail_over_mac=active` (le bond prend la MAC du lien actif ; évite les problèmes de MAC dupliquée en VirtualBox). `ipv4.never-default yes` : pas de route par défaut sur ce réseau métier.

Le mode 802.3ad (LACP) agrège les liens en actif/actif mais nécessite un commutateur qui parle LACP ; VirtualBox n'en émule pas, d'où le choix d'`active-backup`.

**Bascule** (`captures/bascule-bond.txt`) : avant la coupure `Currently Active Slave: enp0s9` ; après `VBoxManage controlvm srv-core setlinkstate3 off`, `enp0s9` passe `MII Status: down` et le bond bascule sur `enp0s10`. Au retour du lien, `primary` fait revenir sur `enp0s9`.

Bilan du ping pendant le test (`ping -i 0.5 -c 80 10.42.0.11`, coupure puis rétablissement du câble de l'adaptateur 3) : `80 paquets transmis, 77 reçus, 3.75% packet loss` (`captures/bascule-ping.txt`).

Le journal noyau montre la bascule : `bond0: (slave enp0s9): link status definitely down, disabling slave` puis `making interface the new active one` pour `enp0s10` (`captures/ecrans/10-*.jpg`). Après rétablissement, `primary_reselect always` fait revenir le bond sur `enp0s9` (`captures/ecrans/11-*.jpg`).

**3 requêtes perdues, une de plus que la cible de 2.** Sans VBoxManage sur l'hôte, j'ai coupé le lien depuis le menu *Périphériques › Réseau › Connecter la carte réseau 3* de la fenêtre VM. La perte est cumulée sur les **deux** bascules : la coupure (enp0s9 → enp0s10) et le retour sur le primaire (enp0s10 → enp0s9). `fail_over_mac=active` impose à srv-edge de réapprendre la MAC dans son cache ARP à chaque bascule. Pour rester sous 2 pertes par bascule, on peut ajouter `num_grat_arp=3` (ARP gratuits envoyés à la bascule) ou `primary_reselect=failure` pour éviter le second basculement au retour du lien.

### 2.3 VLAN 802.1Q 42

`bond0.42` (10.42.42.10) sur `srv-core`, `enp0s9.42` (10.42.42.11) sur `srv-edge`. Mon `srv-edge` tourne sous Ubuntu Server 24.04, où le réseau est géré par netplan/systemd-networkd et non NetworkManager : l'IP métier et le VLAN y sont déclarés avec `netplan set` (écrits dans `/etc/netplan/70-netplan-set.yaml`, donc persistants), l'équivalent des profils `nmcli` de l'énoncé :

```
netplan set ethernets.enp0s9.addresses=[10.42.0.11/24]
netplan set "vlans.vlan42={id: 42, link: enp0s9, addresses: [10.42.42.11/24]}"
netplan apply
```

Résultat : `enp0s9 10.42.0.11/24` et `vlan42@enp0s9 10.42.42.11/24` (`captures/ecrans/04-*.jpg`, `05-*.jpg`). Un `netplan set` du VLAN champ par champ échoue (« missing 'link' property ») car netplan valide la définition à chaque appel : il faut poser `id` et `link` ensemble. La capture `captures/tcpdump-vlan42.txt` montre les trames `ethertype 802.1Q (0x8100), vlan 42` : le marquage est bien fait sur `bond0` et non en IP « nue ».

### 2.4 Routage par règles

- Table `142 transport` déclarée dans `/etc/iproute2/rt_tables`.
- Route `0.0.0.0/0 via 10.42.42.11 table 142` et règle `priority 100 from 10.42.42.10/32 lookup 142`, toutes deux portées par le profil NM `bond0.42` → persistantes.
- `ip route get 8.8.8.8 from 10.42.42.10` → `dev bond0.42 table transport` ; `ip route get 8.8.8.8` → `dev enp0s3` (passerelle NAT par défaut). Voir `captures/routage.txt`.
- Après `systemctl reboot`, tout est revérifié dans `captures/reseau-apres-reboot.txt`.

---

## Mission 3 — Automatisation

### 3.1 Script `helios-archive.sh`

Les cinq règles d'un script de production :

| Règle | Implémentation |
|---|---|
| Mode strict | `set -euo pipefail` (arrêt sur erreur, variable non définie, échec dans un pipe) + `IFS=$'\n\t'` (pas de découpage sur les espaces). |
| Verrou exclusif | `exec 9>/run/lock/...` puis `flock -n 9` : non bloquant, sort en code 2 si déjà pris. Le verrou est libéré automatiquement à la fermeture du descripteur, même en cas de crash. |
| Nettoyage | `trap cleanup EXIT` supprime le répertoire temporaire et journalise le code retour ; `trap ... INT TERM` transforme un signal en erreur propre. |
| Journalisation | `logger -t helios-archive -p daemon.<niveau>` → journald, consultable par `journalctl -t helios-archive`. |
| Codes retour | 0 OK · 1 erreur interne · 2 verrou pris · 3 prérequis manquant. |

Codes retour observés (`captures/archive-rc.txt`) :

| Cas | Attendu | Observé |
|---|---|---|
| Exécution normale | 0 | 0 |
| Une autre instance tient le verrou | 2 | 2 |
| `telemetry.csv` absent | 3 | 3 |

### 3.2 Timer systemd vs cron

Timer : `OnCalendar=*-*-* 02:30:00`, `RandomizedDelaySec=120` (décalage aléatoire jusqu'à 2 min), `AccuracySec=1min`, `Persistent=yes` (rattrapage). Le service est `Type=oneshot`, `Nice=10`, `IOSchedulingClass=idle`, et `ConditionPathExists=` évite de lancer le script si la source n'existe pas. Voir `captures/timer.txt` et `captures/cron.txt`.

| Critère | `cron` (`/etc/cron.d/helios-legacy`) | `systemd timer` |
|---|---|---|
| Rattrapage après VM éteinte | Non : si la VM est éteinte à 02:30, l'exécution est perdue (anacron ne gère que les tâches quotidiennes de `/etc/cron.daily`, pas une ligne `cron.d`). | Oui : `Persistent=yes` mémorise la dernière exécution et lance l'archivage au démarrage suivant. |
| Journalisation et corrélation | `journalctl -u crond` montre seulement le lancement (`CMD (...)`) ; la sortie du script part par mail (coupé ici par `MAILTO=""`) ou est perdue. | `journalctl -u helios-archive.service` donne lancement, sortie, durée et code retour, corrélés à l'unité ; `systemctl status` affiche le dernier résultat. |
| Expression de dépendances | Aucune : il faut tout tester dans le script. | `ConditionPathExists=`, `After=`, `Requires=`… ; ici le service n'est pas lancé si `telemetry.csv` manque. |
| Limitation de ressources | Rien de natif (il faudrait préfixer par `nice`/`ionice` dans la ligne). | Directives de l'unit : `Nice=10`, `IOSchedulingClass=idle`, possible `CPUQuota=`, `MemoryMax=`. |
| Dispersion de la charge | Heure fixe pour toutes les machines → pic simultané. | `RandomizedDelaySec=120` étale les déclenchements. |
| Prochaine exécution | Rien ne l'affiche ; il faut lire la crontab et calculer. | `systemctl list-timers` donne `NEXT` / `LEFT` / `LAST` ; `systemd-analyze calendar` valide l'expression. |

**Conclusion :** le timer est retenu : il rattrape les exécutions manquées, s'observe avec les mêmes outils que les autres services et porte ses propres limites de ressources. cron reste plus simple à écrire pour une tâche ponctuelle sans enjeu.

### Bonus — path unit

`configs/helios-inbox.path` surveille `/srv/helios/inbox` avec `PathChanged=` et lance `helios-archive.service` à chaque dépôt (`captures/bonus-path.txt`). `PathExistsGlob=` aurait relancé le service en boucle tant qu'un fichier existe, jusqu'à `unit-start-limit-hit`, puisque le script ne vide pas l'inbox.

---

## Critères de réussite

Vérifiés sur srv-core2 par `./scripts/tp1.sh collecte` → `captures/criteres.txt`.

| Critère | Résultat | Preuve |
|---|---|---|
| `helios-collect.service` enabled et survit à `kill -9` | ✅ PID 26962 tué → relancé en 5 s (PID 28222, `NRestarts=1`) | `kill9.txt` |
| `MemoryMax=100663296` sans modifier l'unit d'origine | ✅ via drop-in `override.conf` | `dropin.txt` |
| `helios.target` dépend de `helios-collect.service` | ✅ | `target.txt`, `criteres.txt` |
| Bond : deux ports `MII Status: up` + un `Active Slave` | ✅ `enp0s9` actif, `enp0s10` en secours | `bond-etat.txt`, `ecrans/11` |
| Coupure de l'adaptateur 3 : ≤ 2 requêtes ICMP perdues | ⚠️ 3 perdues sur 80 (coupure **et** retour cumulés, voir 2.2) | `bascule-ping.txt`, `ecrans/10` |
| `ip route get … from 10.42.42.10` → `bond0.42` ; sans `from` → `enp0s3` | ✅ | `routage.txt`, `ecrans/09` |
| Réseau persistant après `reboot` | ✅ bond0, bond0.42, règle 100 et table `transport` présents | `reseau-apres-reboot.txt` |
| Script : rc 2 (verrou) et rc 3 (source absente) | ✅ 0 / 2 / 3 | `archive-rc.txt`, `ecrans/12` |
| `list-timers` : `NEXT` cohérent avec 02:30 | ✅ `Tue 2026-11-03 02:31:46` (02:30 + `RandomizedDelaySec`) | `timer.txt`, `ecrans/12` |
| Score `systemd-analyze security` amélioré | ✅ 5.3 MEDIUM → 0.7 SAFE | `security-*.txt` |

## Captures d'écran (`captures/ecrans/`)

| Fichier | Moment |
|---|---|
| `00-*` | VM d'origine : une seule carte NAT |
| `01-*`, `02-*` | srv-core : adaptateurs 3 et 4 sur `helios-lan` |
| `03-*` | srv-edge : adaptateur 3 sur `helios-lan` |
| `04-*`, `05-*` | srv-edge : netplan, IP métier et VLAN 42 |
| `06-*` | srv-core2 câblée sur `helios-lan` |
| `07-*` | Priorités : `nice`, `renice`, `ionice`, `chrt` |
| `08-*` | `tcpdump` : trames 802.1Q `vlan 42` sur `bond0` |
| `09-*` | Règle `from 10.42.42.10 lookup transport` et `ip route get` |
| `10-*` | Bascule du bond : `enp0s9` down → `enp0s10` actif |
| `11-*` | Retour sur le lien primaire `enp0s9` |
| `12-*` | Codes retour 0/2/3, prochain déclenchement du timer, archives |
| `14-*` | Bonus : path unit déclenchée par un dépôt dans l'inbox |
| `15-*` | Synthèse `collecte` : boot avant/après, scores sécurité |
