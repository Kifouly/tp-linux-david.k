# Administration Linux Server — BTC2 · David.K

| TP | Sujet | Rendu |
|---|---|---|
| [TP1](TP1/RENDU.pdf) — [rendu (PDF, 5 p.)](TP1/RENDU.pdf) · [rapport détaillé](TP1/RAPPORT.md) | systemd, réseau avancé (bond, VLAN, policy routing), automatisation | `TP1/` |
| TP2 — `TP2/scripts/tp2.sh` | comptes, politique d'authentification, setgid/sticky/umask, ACL POSIX, sudo | `TP2/` |

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
