# RUNBOOK — portail de suivi des tournées (srv-core)

Service : `helios-suivi.service` (python http.server, port 8080, compte `helios-suivi`), publication `helios-suivi-publish.timer` (toutes les 2 min), sauvegarde `helios-suivi-backup.timer` (03:15). Contrôle global : `sudo /usr/local/sbin/helios-suivi-audit.sh` (doit finir par `Bilan : 9/9`).

## 1. Le portail ne répond plus

- **Symptôme** : Zabbix `helios.suivi.http` ≠ 200 (souvent `000`).
- **Diagnostic** : `systemctl status helios-suivi.service` ; `journalctl -u helios-suivi.service -n 50 --no-pager` ; `ss -ltnp | grep 8080`.
- **Réparation** : `systemctl restart helios-suivi.service` (lea : `sudo systemctl restart helios-suivi.service`). Si l'unit échoue, regarder le journal (OOM à 128M, erreur python) avant de toucher au durcissement.
- **Vérification** : `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/etat.json` → `200`.

## 2. etat.json est figé

- **Symptôme** : Zabbix `helios.suivi.age` > 300 (ou la date `genere` du JSON ne bouge plus).
- **Diagnostic** : `systemctl list-timers helios-suivi-publish.timer` ; `journalctl -t helios-suivi-publish -n 10` (rc 3 = télémétrie illisible ou www non inscriptible, rc 1 = dernière ligne invalide, rc 2 = verrou) ; `systemctl is-active helios-collect.service` (le collecteur du TP1 alimente le CSV).
- **Réparation** : `systemctl start helios-suivi-publish.service` (lea : `sudo systemctl start helios-suivi-publish.service`) ; si rc 3, reposer l'ACL : `setfacl -m u:helios-suivi:r /var/lib/helios/telemetry.csv`, `setfacl -m u:helios-suivi:x /var/lib/helios` ; relancer `helios-collect.service` s'il est arrêté.
- **Vérification** : `zabbix_get -s 127.0.0.1 -k helios.suivi.age` → nombre < 300.

## 3. Injoignable depuis le réseau métier alors que le service tourne

- **Symptôme** : `curl http://10.42.0.10:8080/` échoue depuis srv-edge, mais `helios.suivi.http` = 200 en local.
- **Diagnostic** : `firewall-cmd --zone=internal --query-port=8080/tcp` (runtime) et `firewall-cmd --permanent --zone=internal --query-port=8080/tcp` ; `firewall-cmd --get-active-zones` (bond0 / bond0.42 doivent être en internal) ; `ip -br a show bond0`.
- **Réparation** : `firewall-cmd --zone=internal --add-port=8080/tcp` puis la même avec `--permanent`. Jamais ailleurs que dans internal, jamais `systemctl stop firewalld`.
- **Vérification** : depuis srv-edge `curl -s -o /dev/null -w '%{http_code}\n' http://10.42.0.10:8080/etat.json` → `200` ; `nc -zv -w2 192.168.56.10 8080` doit toujours échouer.

## 4. Restaurer le portail après suppression ou corruption

- **Symptôme** : `index.html` absent (404) ou contenu abîmé, ou ACL de www modifiées.
- **Diagnostic** : `ls -l /srv/helios/suivi/www` ; `getfacl -p /srv/helios/suivi/www` ; dernière archive : `ls -1t /srv/helios/archives/suivi/*.tar.gz | head -1`, empreinte : `cd /srv/helios/archives/suivi && sha256sum -c <archive>.sha256`.
- **Réparation** (un seul fichier, ACL comprises) : `tar --acls --xattrs -xzpf <archive> -C / srv/helios/suivi/www/index.html` ; tout le répertoire : même commande avec `srv/helios/suivi`.
- **Vérification** : `getfacl -p /srv/helios/suivi/www/index.html` (lea:suivi, `user:helios-suivi:rw-`) et `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/index.html` → `200`.
