"""Génère les logigrammes de NeoVibe, et les VALIDE avant de les écrire.

Pourquoi un script plutôt que six fichiers JSON écrits à la main : le format
Logigram tolère les erreurs à l'import (il signale et importe le reste), donc un
`in` qui pointe vers un bloc inexistant ne se voit pas — le bloc atterrit
simplement à la racine, et le schéma raconte autre chose que ce qu'on voulait.
Ici, chaque référence est vérifiée avant écriture.
"""

import json
import pathlib
import sys

TYPES = {
    "group", "cluster",
    "server", "container", "storage", "external",
    "service", "module", "api", "fn", "queue",
    "trigger", "action", "condition", "loop", "transform", "wait", "error", "task",
    "db", "table", "cache", "variable",
    "client", "user", "note",
}
DTYPES = {
    "string", "number", "boolean", "object", "array", "json", "uuid",
    "date", "enum", "secret", "fichier", "stream", "any",
}
KINDS = {"data", "call", "event", "dep", "flow"}


def n(id, type, label, **kw):
    d = {"id": id, "type": type, "label": label}
    d.update(kw)
    return d


def e(f, t, kind, label=None, **kw):
    d = {"from": f, "to": t, "kind": kind}
    if label:
        d["label"] = label
    d.update(kw)
    return d


def valider(schema):
    """Rend la liste des problèmes. Vide = bon."""
    pb = []
    ids = {}

    def parcourir(noeuds, parent=None):
        for nd in noeuds:
            i = nd.get("id")
            if not i:
                pb.append(f"bloc sans id : {nd.get('label')}")
                continue
            if i in ids:
                pb.append(f"id en double : {i}")
            ids[i] = nd
            if nd["type"] not in TYPES:
                pb.append(f"type inconnu « {nd['type']} » sur {i}")
            if nd["type"] == "variable" and "dtype" not in nd:
                pb.append(f"variable sans dtype : {i}")
            if nd.get("dtype") and nd["dtype"] not in DTYPES:
                pb.append(f"dtype inconnu « {nd['dtype']} » sur {i}")
            parcourir(nd.get("children", []), i)

    parcourir(schema["nodes"])

    for nd in schema["nodes"]:
        p = nd.get("in")
        if p and p not in ids:
            pb.append(f"« in » introuvable : {nd['id']} → {p}")

    for lien in schema["edges"]:
        for bout in ("from", "to"):
            if lien[bout] not in ids:
                pb.append(f"lien {bout} introuvable : {lien[bout]}")
        if lien["kind"] not in KINDS:
            pb.append(f"kind inconnu « {lien['kind']} »")
        if "x" in json.dumps(lien):
            pass
    return pb


# ─────────────────────────────────────────────────────────── 1. vue d'ensemble
vue_ensemble = {
    "name": "NeoVibe — 1. Vue d'ensemble",
    "nodes": [
        n("regle", "note", "La règle qui explique tout le reste",
          desc="On ne devient amis qu'en s'étant VU physiquement (Bluetooth), "
               "ou par recommandation d'un ami commun. Toute l'architecture "
               "découle de cette barrière."),

        n("tel", "client", "Ton téléphone", desc="Application Flutter (Dart) + code natif Android (Kotlin)", children=[
            n("app", "module", "L'app — 5 onglets", children=[
                n("t_vibe", "module", "Vibe", desc="la caméra : on crée un contenu"),
                n("t_ping", "module", "Ping", desc="qui est physiquement autour de moi"),
                n("t_cercle", "module", "Cercle", desc="mes conversations"),
                n("t_jeux", "module", "Jeux", desc="à construire"),
                n("t_profil", "module", "Profil", desc="moi, mes amis, ma bibliothèque"),
            ]),
            n("natif", "container", "Code natif Android (Kotlin)",
              desc="ce que Flutter ne sait pas faire seul", children=[
                n("k_ble", "fn", "Bluetooth (BleEngine)"),
                n("k_cam", "fn", "Caméra double flux (GPU)"),
                n("k_play", "fn", "Lecteur vidéo chiffré"),
            ]),
            n("local", "storage", "Mémoire de l'appareil",
              desc="ce qui ne part JAMAIS sur le serveur", children=[
                n("v_carnet", "variable", "carnet d'amis", dtype="json",
                  value="clés de reconnaissance"),
                n("v_convping", "variable", "conversations ping", dtype="json",
                  value="effacées après 12 h"),
                n("v_medias", "variable", "médias en cache", dtype="fichier",
                  value="chiffrés, jamais en clair"),
            ]),
        ]),

        n("autre", "user", "Une autre personne", desc="à quelques mètres de toi", children=[
            n("son_tel", "client", "Son téléphone"),
        ]),

        n("supa", "cluster", "Supabase — le serveur", desc="PostgreSQL + stockage + authentification", children=[
            n("auth", "service", "Authentification", desc="qui es-tu ?"),
            n("pg", "db", "Base de données", desc="29 tables — voir le schéma 6"),
            n("coffre", "storage", "Coffres de médias",
              desc="photos et vidéos, TOUJOURS chiffrées"),
            n("rt", "service", "Temps réel",
              desc="prévient l'app quand quelque chose change"),
            n("rls", "note", "Sécurité (RLS)",
              desc="71 règles dans la base elle-même : même en trichant, "
                   "l'app ne peut lire que ce à quoi elle a droit"),
        ]),

        n("note_ble", "note", "Pourquoi le Bluetooth ?",
          desc="Il marche sans internet et ne porte qu'à quelques mètres. "
               "C'est ce qui prouve qu'on s'est vraiment croisés."),
    ],
    "edges": [
        e("app", "natif", "call", "caméra, Bluetooth, lecteur"),
        e("app", "local", "data", "lit et écrit"),
        e("k_ble", "son_tel", "data", "annonce BLE + canal chiffré", arrow="both"),
        e("app", "auth", "call", "se connecter"),
        e("app", "pg", "call", "REST + fonctions SQL"),
        e("app", "coffre", "data", "envoie / télécharge"),
        e("rt", "app", "event", "ça a changé !"),
        e("regle", "k_ble", "dep"),
        e("note_ble", "k_ble", "dep"),
    ],
}

# ───────────────────────────────────────────────────────────── 2. le ping
ping = {
    "name": "NeoVibe — 2. Le Ping, couche par couche",
    "nodes": [
        n("intro", "note", "Lire de bas en haut",
          desc="Chaque couche ignore celles du dessus et peut être testée seule. "
               "C'est ce qui a permis de trouver 5 causes de messages perdus."),

        n("c0", "container", "Couche 0 — La radio (Kotlin)",
          desc="le matériel : elle DIT son état réel, elle ne fait plus semblant", children=[
            n("f_engine", "fn", "BleEngine", desc="annonce, scan, connexions GATT"),
            n("f_service", "service", "ProximityService",
              desc="service de premier plan : survit à la fermeture de l'app"),
            n("f_bridge", "module", "ProximityBridge",
              desc="les ORDRES descendent, les CONSTATS remontent — deux canaux"),
            n("v_statut", "variable", "état de la radio", dtype="enum",
              value="éteinte / permission / diffuse / détecte"),
        ]),

        n("c1", "module", "Couche 1 — Transport (PeerLink)",
          desc="découpe une trame en morceaux, et la recolle en face", children=[
            n("v_mtu", "variable", "taille d'un morceau", dtype="number", value="~182 octets"),
        ]),

        n("c3", "module", "Couche 3 — Canal sécurisé (SecureChannel)",
          desc="personne d'autre ne peut lire, ni se glisser au milieu", children=[
            n("v_eph", "variable", "clés éphémères", dtype="secret",
              value="c'est LEUR COUPLE qui identifie la session"),
            n("v_cle", "variable", "clé de session", dtype="secret", value="AES-GCM 256"),
            n("v_cpt", "variable", "compteur de trames", dtype="number",
              value="strictement croissant = anti-rejeu"),
        ]),

        n("c4", "module", "Couche 4 — Présence (PresenceTracker)",
          desc="qui est là, et à quelle distance", children=[
            n("v_etat", "variable", "état du pair", dtype="enum",
              value="détecté / en cours / identifié"),
            n("v_dist", "variable", "distance estimée", dtype="object",
              value="une BANDE et une tendance, jamais un chiffre exact"),
        ]),

        n("c5", "module", "Couche 5 — Protocole (WireFrame)",
          desc="le format du fil, déclaré une seule fois"),

        n("c6", "module", "Couche 6 — Réseau de pairs (PeerNetwork)",
          desc="transforme des octets en « untel est là et te parle »", children=[
            n("v_ident", "variable", "identité du pair", dtype="object",
              value="rangée avec la SESSION, jamais dans la présence"),
        ]),

        n("sup", "service", "Superviseur — intention ≠ état",
          desc="ce que TU veux (persisté) n'est pas ce que le matériel FAIT. "
               "C'est ce qui rattrape tout seul : app fermée, Bluetooth coupé…"),

        n("ctrl", "module", "Contrôleur — les règles du produit",
          desc="quand certifier un croisement, quoi faire d'une demande d'ami"),

        n("journal", "storage", "Journal local (ProximityJournal)", children=[
            n("v_recues", "variable", "demandes reçues", dtype="json"),
            n("v_envoyees", "variable", "demandes envoyées", dtype="json",
              value="envoyée / refusée / acceptée"),
        ]),

        n("sync", "module", "Couche 7 — Synchronisation",
          desc="ce qui remonte au serveur quand internet revient"),
        n("file", "queue", "File d'envoi", desc="croisements, connexions, waves"),

        n("ecran", "client", "Écran Ping",
          desc="ne dit jamais « personne » quand il ne sait pas"),

        n("trace", "note", "Journal des pertes",
          desc="10 endroits où une trame pouvait disparaître sans un mot sont "
               "désormais comptés. C'est ce qui a permis de trouver les défauts."),

        n("regle2", "note", "La règle la plus importante",
          desc="La PRÉSENCE dit OÙ et à quelle distance — jamais QUI. "
               "L'identité appartient à la session. Confondre les deux a coûté "
               "des messages perdus deux fois."),
    ],
    "edges": [
        e("f_engine", "f_service", "flow"),
        e("f_service", "f_bridge", "flow"),
        e("f_bridge", "c1", "data", "octets reçus"),
        e("f_bridge", "sup", "event", "état de la radio"),
        e("c1", "c5", "flow", "trame complète"),
        e("c5", "c3", "flow", "chiffrée ?"),
        e("c3", "c6", "data", "message en clair"),
        e("c6", "c4", "data", "met à jour la présence"),
        e("c6", "ctrl", "event", "untel est identifié / t'écrit"),
        e("sup", "c6", "event", "démarre / arrête"),
        e("ctrl", "journal", "data", "range"),
        e("ctrl", "file", "data", "à envoyer plus tard"),
        e("file", "sync", "flow"),
        e("ctrl", "ecran", "data", "ce qu'il faut afficher"),
        e("c4", "ecran", "data", "qui est autour"),
        e("regle2", "v_ident", "dep"),
        e("trace", "c6", "dep"),
        e("intro", "c0", "dep"),
    ],
}

# ────────────────────────────────────────────────────────── 3. devenir amis
amis = {
    "name": "NeoVibe — 3. Devenir amis (par proximité)",
    "nodes": [
        n("intro3", "note", "Le cœur du produit",
          desc="Aucun annuaire, aucune recherche. On ne peut demander qu'à "
               "quelqu'un qui est là, maintenant, à quelques mètres."),

        n("a", "user", "Charles — il demande", children=[
            n("btn", "trigger", "Appui sur « demander à se connecter »"),
            n("c_ami", "condition", "déjà amis ?"),
            n("c_deja", "condition", "demande déjà envoyée ?"),
            n("sign", "transform", "signer la demande",
              desc="avec la clé de l'appareil, qui ne sort jamais du téléphone"),
            n("envoi", "action", "envoyer par le canal chiffré"),
            n("range_out", "action", "ranger « envoyée »"),
            n("err1", "error", "« Vous êtes déjà connectés »"),
            n("err2", "error", "« Demande déjà envoyée »"),
            n("err3", "error", "« Rapproche-toi et réessaie »",
              desc="si le pair n'est plus à portée"),
        ]),

        n("b", "user", "mimi — elle répond", children=[
            n("recu", "trigger", "demande reçue"),
            n("c_sig", "condition", "signature valide ?"),
            n("c_ami2", "condition", "déjà amis ?"),
            n("range_in", "action", "ranger la demande"),
            n("choix", "condition", "elle accepte ?"),
            n("contre", "transform", "contre-signer",
              desc="le document porte alors LES DEUX signatures"),
            n("refus", "action", "envoyer un refus"),
            n("jete", "error", "jetée et consignée"),
        ]),

        n("retour", "action", "Charles reçoit la réponse", children=[
            n("c_notre", "condition", "cette demande est-elle bien la nôtre ?",
              desc="on vérifie NOTRE propre signature — un tiers ne peut pas la fabriquer"),
            n("ok", "action", "on est amis : ranger dans le carnet"),
            n("marque", "action", "marquer « refusée » — visible à l'écran"),
            n("intrus", "error", "acceptation refusée et consignée"),
        ]),

        n("file3", "queue", "File d'envoi", desc="on n'a pas besoin d'internet pour tout ça"),

        n("srv", "cluster", "Serveur", children=[
            n("rpc", "api", "submit_ble_connection"),
            n("c_srv", "condition", "les DEUX signatures sont-elles bonnes ?"),
            n("t_conn", "table", "connections", desc="l'amitié, enfin officielle"),
            n("refus_srv", "error", "refusé"),
        ]),

        n("notif", "trigger", "Notification si ça n'a jamais pu partir",
          desc="on a dit « vous êtes connectés » : si le serveur ne l'apprend "
               "jamais, il faut le dire"),
    ],
    "edges": [
        e("btn", "c_ami", "flow"),
        e("c_ami", "err1", "flow", "oui"),
        e("c_ami", "c_deja", "flow", "non"),
        e("c_deja", "err2", "flow", "oui"),
        e("c_deja", "sign", "flow", "non"),
        e("sign", "envoi", "flow"),
        e("envoi", "err3", "flow", "hors de portée"),
        e("envoi", "range_out", "flow", "parti"),
        e("envoi", "recu", "data", "par Bluetooth, chiffré"),

        e("recu", "c_sig", "flow"),
        e("c_sig", "jete", "flow", "non"),
        e("c_sig", "c_ami2", "flow", "oui"),
        e("c_ami2", "jete", "flow", "déjà amis"),
        e("c_ami2", "range_in", "flow", "non"),
        e("range_in", "choix", "flow"),
        e("choix", "contre", "flow", "accepte"),
        e("choix", "refus", "flow", "refuse"),

        e("contre", "c_notre", "data", "document co-signé"),
        e("refus", "c_notre", "event", "refus"),
        e("c_notre", "intrus", "flow", "non"),
        e("c_notre", "ok", "flow", "oui + acceptée"),
        e("c_notre", "marque", "flow", "oui + refusée"),

        e("ok", "file3", "data", "document co-signé"),
        e("contre", "file3", "data", "document co-signé"),
        e("file3", "rpc", "call", "quand internet revient"),
        e("rpc", "c_srv", "flow"),
        e("c_srv", "refus_srv", "flow", "non"),
        e("c_srv", "t_conn", "data", "oui — INSERT"),
        e("file3", "notif", "event", "abandonnée après 8 essais"),
        e("intro3", "btn", "dep"),
    ],
}

# ⚠️ Relatif à la RACINE du dépôt : lancer `python tool/build_logigrams.py`
# depuis la racine, pas depuis `tool/` (sinon les fichiers atterrissent dans
# `tool/docs/`, et on ne s'en aperçoit qu'en cherchant pourquoi Logigram ouvre
# une version périmée).
SORTIE = pathlib.Path(__file__).resolve().parent.parent / "docs" / "logigrams"


def ecrire(schema, fichier):
    pb = valider(schema)
    if pb:
        print(f"[ERREUR] {fichier}")
        for p in pb:
            print("   -", p)
        return False
    SORTIE.mkdir(parents=True, exist_ok=True)
    (SORTIE / fichier).write_text(
        json.dumps(schema, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    nb = json.dumps(schema).count('"type"')
    print(f"[OK] {fichier} — {nb} blocs, {len(schema['edges'])} liens")
    return True


if __name__ == "__main__":
    ok = True
    ok &= ecrire(vue_ensemble, "1-vue-ensemble.json")
    ok &= ecrire(ping, "2-le-ping.json")
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    from logigrams_part2 import vibe, livraison, donnees

    ok &= ecrire(amis, "3-devenir-amis.json")
    ok &= ecrire(vibe, "4-une-vibe.json")
    ok &= ecrire(livraison, "5-livraison-media.json")
    ok &= ecrire(donnees, "6-modele-de-donnees.json")
    sys.exit(0 if ok else 1)
