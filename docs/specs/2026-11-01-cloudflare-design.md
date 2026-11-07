# Plugin `cloudflare` — Cloudflare et Caddy pour les agents Claude Code

Conception, 2026-11-01. Auteur : `Orch : Cloudflare config`, à partir des réponses de l'opérateur.
Ce qui est la décision de l'opérateur est marqué **(opérateur)** ; ce qui est un choix de l'auteur, **(choix)**.

## 1. Intention

Gérer Cloudflare et Caddy va devenir récurrent (opérateur). Aujourd'hui, chaque modification est faite à la
main ou par des scripts jetables d'une session (`curl` + `jq`), sans garde-fous communs : la session du
2026-11-01 a montré ce que ça coûte — 15 sous-domaines proxifiés morts depuis des mois parce qu'Universal
SSL était coupé, un token en clair dans le Caddyfile, un `caddy reload` qui casse s'il est lancé sans le
token chargé. Le plugin donne aux agents des **scripts API** fiables, qui consomment **le moins de tokens
possible** (opérateur), et la **connaissance de Caddy** pour bien configurer un service (opérateur).

## 2. Objectifs

### Cloudflare (opérateur)
- **Comptes désignés par nom** : `perso` (perso, zone `example.com`, l'actuel), `pro` (pro,
  plus tard), d'autres ensuite. Les identifiants de chaque compte suivent le motif
  `{NOM}_CLOUDFLARE_*` (ex. `PERSO_CLOUDFLARE_API_TOKEN`, `PERSO_CLOUDFLARE_ACCOUNT_ID`), lus dans
  l'environnement ou dans `~/.env`. Toute commande prend le compte en paramètre ; un compte par
  défaut est configurable.
- **DNS, toutes zones du compte** : lister les zones ; lister, créer, modifier, supprimer des
  enregistrements (tous types, proxifié ou non) ; exporter une zone.
- **Protections, tous types** (opérateur : « pas que par pays », « toutes les protections nécessaires ») :
  règles de pare-feu personnalisées (expressions, dont pays/ASN/IP/chemin/user-agent), limitation de
  débit, règles gérées (WAF managé), règles d'accès IP, mode anti-bots, niveau de sécurité,
  « Under Attack ». Mise en place **facile** : un agent doit pouvoir appliquer « bloquer tout sauf la
  France sur app.example.com » en un appel, pas en composant un JSON de ruleset à la main.
- **Cache** sur les entrées proxifiées : règles de cache par hôte/chemin, purge (tout, par URL, par hôte).
- **Workers** : lister, déployer un script, supprimer, gérer les routes et domaines personnalisés.
- **Réglages de base** (opérateur : « fonctionnalités de base auxquelles je n'aurais pas pensé ») : SSL/TLS
  (mode, Universal SSL, version min, TLS 1.3, Always Use HTTPS) ; état des certificats de bord ;
  vérification du token.

### Caddy (opérateur)
- Ajouter, modifier, retirer **un bloc par service** dans le Caddyfile.
- Avant rechargement : **validation de syntaxe** (`caddy validate`).
- Rechargement **à chaud** (`caddy reload`), jamais d'arrêt.
- Après rechargement : **Caddy tourne toujours** et **rien n'est cassé** — chaque site répond comme avant,
  pas seulement le nouveau.
- **Connaître la documentation Caddy** : ce qui est possible et comment l'écrire, pour que l'agent
  configure au mieux selon le besoin (reverse_proxy, en-têtes, auth, compression, cache, websockets,
  matchers, handle, TLS…).

### Commandes combinées (choix, validé par l'opérateur sur le résumé)
- `publish` : enregistrement A (proxifié par défaut) + bloc Caddy + validate + reload + vérification HTTPS.
- `unpublish` : l'inverse.
- `inventory` : sauvegarde de la zone, réglages SSL, correspondance DNS ↔ blocs Caddy (sous-domaines sans
  bloc, blocs sans enregistrement), état HTTPS de chaque nom.
- `check <hôte>` : résolution publique, code HTTPS par le bord Cloudflare, émetteur et échéance du
  certificat.

## 3. Non-objectifs

- Pas d'interface graphique ni de panneau (choix ; à rouvrir plus tard si utile).
- Pas de couverture des produits Cloudflare non cités : R2, D1, KV, Pages, Zero Trust/Tunnel, Email
  Routing (choix — Tunnel/Access pour SSH est une piste séparée, proposée à l'opérateur le 2026-11-01).
- Pas de gestion d'un Caddy distant ni de plusieurs instances Caddy (choix : un Caddy local par machine,
  le plugin installé sur chaque machine qui a un Caddy).
- Pas de choix des protections par domaine : c'est un chantier de l'opérateur, à faire **avec** le plugin ensuite.

## 4. Anti-objectifs (échec même si ça « marche »)

- Passer par l'API d'administration de Caddy (`:2019`) pour modifier la config : le Caddyfile reprend le
  dessus au rechargement suivant, la modification se perd. **Le Caddyfile est la seule source de vérité.**
- Un token qui apparaît dans une sortie, un log, un argument de processus (`ps`) ou un fichier du dépôt.
- Une modification sans confirmation (opérateur, réponse 2).
- Une modification de zone sans sauvegarde préalable restaurable.
- Un rechargement qui laisse Caddy sur une config cassée ou un site qui ne répond plus sans retour arrière.
- Des sorties verbeuses (JSON brut de l'API) qui gaspillent le contexte des agents.
- Quoi que ce soit de propre à une machine dans le dépôt (règle de l'opérateur : zone, IP, chemins, noms
  d'hôte vont dans une config locale).

## 5. Contraintes

- **Modèle du dépôt** (choix, sur le modèle de `LounisBou/claude-github`, prior art de l'opérateur) : dépôt
  `LounisBou/claude-cloudflare`, plugin `cloudflare`, inscrit dans la marketplace `lounisbou`
  (`LounisBou/claude-plugins-marketplace`). Un **outil natif** (mod `hooks/register.ts` via
  `$.tool.register`, comme `mcp__github__gh`) façade d'un **moteur Python 3.9+ en bibliothèque
  standard seule** (`engine/cf.py`, requête JSON sur stdin, pas d'argv) ; une **skill de repli**
  (comme `github-curl`) qui lance le même moteur en Bash là où les mods ne se chargent pas
  (`claude -p`) ; `/cloudflare:install` et `/cloudflare:doctor`.
- **Confirmation des modifications** (opérateur : « tout le monde pourra le faire avec des demandes de
  confirmation pour les modifications ») : comme `claude-github`, une liste `READS` des commandes de
  lecture ; **toute commande absente de la liste est une écriture** ; une écriture passe par la
  vérification de permission de Claude Code (demande à l'utilisateur, règles `allow/ask/deny`
  respectées). La lecture passe sans demande.
- **Jusqu'à nouvel ordre** (opérateur, réponse 2 « A pour aujourd'hui ») : seul `Orch : Cloudflare config`
  modifie la zone et le Caddyfile ; les autres sessions lisent et demandent. Le plugin ne code pas
  cette règle, il la rend possible plus tard.
- **Sobriété en tokens** (opérateur) : sorties texte compactes par défaut (une ligne par enregistrement,
  tableau court), `--json` sur demande ; la fiche de référence de l'outil est courte, et la doc Caddy
  est découpée en fiches par sujet que l'agent ouvre seulement au besoin.
- **Secrets** : tokens lus dans l'environnement ou `~/.env` (motif `{NOM}_CLOUDFLARE_*`), jamais
  affichés ; le token Caddy (DNS-01) vit dans un fichier d'environnement local (ici
  `/opt/homebrew/etc/caddy.env`, chmod 600) chargé dans l'environnement du processus `caddy`
  (validate/reload), jamais passé en argument.
- **Config locale par machine** (hors dépôt, ex. `~/.config/claude-cloudflare/config.json`) : comptes
  connus et compte par défaut, IP publique de cible par défaut, chemin du binaire `caddy`, du
  Caddyfile, du fichier d'env du token, du répertoire de sauvegarde, snippet TLS à importer
  (`tls_config` ici). Une machine sans Caddy n'a que la partie Cloudflare.
- **Règles de la machine home-server** (`~/CLAUDE.md`, `~/MEMORY.md`) : jamais d'arrêt de Caddy ; une
  sauvegarde du Caddyfile avant chaque édition ; `caddy validate` avant `caddy reload`.

## 6. Comportements décidés

- **Sauvegarde avant écriture** (choix) : avant toute écriture sur une zone, export JSON des objets
  touchés (enregistrements, ruleset, réglage) dans le répertoire de sauvegarde horodaté ; commande
  `restore` pour rejouer une sauvegarde. Idem Caddyfile : copie `Caddyfile.bak-<horodatage>` avant
  édition.
- **Cycle Caddy** (choix) : éditer → `validate` (env chargé) → si échec, restaurer et s'arrêter →
  relevé « avant » des sites → `reload` → Caddy toujours vivant (API admin `GET /config/` en lecture,
  processus présent) → relevé « après » de **tous** les sites du Caddyfile → si un site change de
  classe de réponse (répondait, ne répond plus), restaurer la sauvegarde, recharger, et rapporter.
- **Proxifié par défaut** (choix, conforme à la décision de l'opérateur du 2026-11-01) : `publish` crée un A
  proxifié ; `--no-proxy` pour l'exception (ex. Plex, `home`).
- **Garde SSL** (choix, leçon du 2026-11-01) : `publish` en proxifié refuse si Universal SSL est coupé
  ou si le mode SSL n'est pas `full`/`strict`, et dit pourquoi.
- **Protections faciles** (choix) : des commandes de haut niveau (`block-countries`,
  `allow-only-countries`, `rate-limit`, `challenge`, `ip-allow`/`ip-block`, `under-attack`) qui
  composent le ruleset, plus une commande bas niveau qui pose une expression Cloudflare brute pour
  tout le reste.

- **Forfaits** (choix) : la zone `example.com` est en **Free** (constaté le 2026-11-01) ; le
  forfait d'une zone future est inconnu. Le moteur lit le forfait de la zone et ses quotas (règles
  personnalisées, limitation de débit, règles gérées, bots) et **refuse clairement** ce que le
  forfait n'offre pas, au lieu d'échouer sur une erreur d'API. Sur Free, les protections par hôte sont
  fusionnées dans une même règle quand le quota l'impose.
- **Objets existants** (choix) : le plugin gère aussi ce qu'il n'a pas créé. Caddy : un bloc est
  identifié par son hôte (aujourd'hui, un hôte par bloc) ; le parseur suit les accolades, laisse
  intacts le bloc d'options globales, les snippets (`(tls_config)`) et les blocs qu'il ne vise pas, et
  refuse un bloc à plusieurs hôtes ou à joker qu'il ne sait pas désigner sans ambiguïté. Cloudflare :
  une écriture dans un ruleset conserve toutes les règles qu'elle ne vise pas (lecture, fusion,
  réécriture), y compris celles créées dans le tableau de bord.
- **Critère de retour arrière Caddy** (choix) : sonde **locale** (127.0.0.1:443 avec SNI de chaque
  hôte), pour ne tester que le rechargement, pas Cloudflare. Un site est « cassé » s'il passait la
  poignée TLS et rendait une réponse HTTP avant, et qu'après il échoue en connexion ou en TLS. Un
  changement de code HTTP (502 compris : service arrêté derrière) n'est pas une casse ; il est
  rapporté. Caddy non vivant après rechargement = casse.
- **Confirmation** (choix, sur le modèle de `claude-github`, convention existante de l'opérateur) : une
  demande par commande d'écriture — `publish` est **une** demande pour tout son cycle ; sauvegardes et
  retour arrière automatiques font partie de la commande confirmée. Les règles `allow/ask/deny` et les
  autorisations « pour la session » de Claude Code sont celles de l'utilisateur et sont respectées.
  Dans la skill de repli Bash, les écritures passent par un point d'entrée distinct
  (`cf-write.py` vs `cf.py`) pour que des règles de permission Bash puissent les distinguer.
- **Machines** (opérateur, 2026-11-01 : « B ») : la partie Caddy gère **macOS avec Caddy Homebrew/launchd**
  (home-server) **et Linux avec Caddy sous systemd**. La config locale déclare le gestionnaire
  (`launchd` ou `systemd`), les chemins, et la façon de lancer `caddy` avec les droits requis (sous
  Linux, Caddyfile et service souvent à root : `sudo` explicite, déclaré dans la config, jamais
  supposé). Règle commune : `caddy validate` puis `caddy reload`, jamais d'arrêt ni de
  `systemctl restart` / `brew services restart`. Le fichier d'env du jeton DNS-01 est chargé dans
  l'environnement de `caddy validate|reload` sur les deux ; au démarrage du service, c'est
  `--envfile` (launchd) ou `EnvironmentFile=` (systemd), que `doctor` vérifie présent.
- **Jetons** (choix) : un jeton par compte, `{NOM}_CLOUDFLARE_API_TOKEN` (+ `{NOM}_CLOUDFLARE_ACCOUNT_ID`) ;
  `doctor` vérifie qu'il couvre les permissions nécessaires et dit lesquelles manquent. Le jeton DNS-01
  de Caddy (fichier d'env de la config locale) est vérifié par `doctor` (présent, valide, droit
  d'édition DNS) sans être affiché.

## 7. Laissé au constructeur

- Le découpage interne du moteur (`cflib/` par domaine, sur le modèle de `ghlib/`), le format exact des
  sorties compactes, les noms définitifs des sous-commandes.
- La forme de la doc Caddy embarquée (fiches tirées de caddyserver.com/docs, par directive ou par
  thème) et sa taille, dans la contrainte de sobriété.
- La méthode d'édition du Caddyfile (insertion/suppression de blocs délimités, sans reformater le reste
  du fichier — `caddy fmt` n'est pas appliqué au fichier entier).
- Les tests (le modèle `claude-github` a `tests/run-tests.sh` ; appels API simulés, aucune écriture
  sur un vrai compte dans les tests).
