# Administration Linux Server — BTC2 · David.K

| TP | Sujet | Rendu |
|---|---|---|
| [TP1](TP1/RENDU.pdf) — [rendu (PDF, 5 p.)](TP1/RENDU.pdf) · [rapport détaillé](TP1/RAPPORT.md) | systemd, réseau avancé (bond, VLAN, policy routing), automatisation | `TP1/` |
| [TP2](TP2/RENDU.pdf) — [rendu (PDF, 5 p.)](TP2/RENDU.pdf) · [rapport détaillé](TP2/RAPPORT.md) | comptes, politique d'authentification, setgid/sticky/umask, ACL POSIX, sudo | `TP2/` |
| [TP3](TP3/RENDU.pdf) — [rendu (PDF, 5 p.)](TP3/RENDU.pdf) · [rapport détaillé](TP3/RAPPORT.md) | firewalld par zone, durcissement sshd, journald/auditd, détection et blocage | `TP3/` |

## Arborescence TP1

```
TP1/
├── RAPPORT.md            rapport (valeurs remplies par tp1.sh collecte)
├── configs/              units, drop-in, scripts, bond0.txt
├── captures/             sorties de commandes, SVG de boot, tcpdump, bascule
└── scripts/tp1.sh        déroule le TP et enregistre les preuves
```

## Dérouler le TP1

Sur `srv-core`, en root :

```bash
dnf -y install git
git clone https://github.com/<ton-compte>/<ce-depot>.git /root/tp && cd /root/tp/TP1
chmod +x scripts/tp1.sh

./scripts/tp1.sh m1-boot-avant   ; systemctl reboot
./scripts/tp1.sh m1-boot-apres
./scripts/tp1.sh m1-service
#   -> sur srv-edge (cloner aussi le dépôt) : ./scripts/tp1.sh m2-edge
./scripts/tp1.sh m2-core         # IF1=... IF2=... si tes cartes ne sont pas enp0s9/enp0s10
./scripts/tp1.sh m2-bascule      # te demande de couper/rétablir le lien sur l'hôte
systemctl reboot
./scripts/tp1.sh m2-verif
./scripts/tp1.sh m3
./scripts/tp1.sh bonus
./scripts/tp1.sh collecte        # livrables + critères + remplit RAPPORT.md

git add -A && git commit -m "TP1 : preuves et rapport" && git push
```

Le push HTTPS demande un *personal access token* GitHub à la place du mot de passe.

## Dérouler le TP2

Sur `srv-core`, en root, dans le même dépôt :

```bash
cd /root/tp && git pull && cd TP2 && chmod +x scripts/tp2.sh
./scripts/tp2.sh m1 ; ./scripts/tp2.sh m2 ; ./scripts/tp2.sh m3 ; ./scripts/tp2.sh m4
./scripts/tp2.sh bonus ; ./scripts/tp2.sh collecte
git add -A && git commit -m "TP2 : preuves" && git push
```

## Dérouler le TP3

Prérequis : adaptateur 2 de chaque VM en *réseau privé hôte* (`enp0s8`, 192.168.56.0/24). Dépôt cloné en root sur les deux VM (`/root/tp`). Les étapes alternent entre les deux machines, et chaque étape indique la suivante :

```
srv-core : m0   srv-edge : e1   srv-core : m1   srv-edge : e2   srv-core : m2a
srv-edge : e3   srv-core : m2   srv-edge : e4   srv-core : m3a (redémarre)
srv-core : m3   srv-edge : e5   srv-core : m3b  srv-edge : e6   srv-core : fin
```
