"""Schémas 7 et 8 : la reconnaissance de proximité, telle qu'elle est et telle
qu'elle pourrait être.

Le 7 décrit l'architecture en place (clé de diffusion unique, partagée avec tous
les amis) et rend visibles ses deux trous. Le 8 décrit l'alternative discutée
avec Jay le 2026-08-19 : un secret **par paire**, dérivé et jamais transmis.

⚠️ Le 8 était une proposition ; il est **implémenté depuis le 2026-08-20**
(`RAPPELS.md` #53). Deux réserves qui se lisent sur le schéma : le natif diffuse
seul mais ne RECONNAÎT pas encore, et l'émission multi-annonces n'est pas faite
— le cycle est en temps partagé.
"""

from build_logigrams import n, e

# ---------------------------------------------------------------------------
# 7 — La reconnaissance aujourd'hui : une clé partagée par tous
# ---------------------------------------------------------------------------

reconnaissance = {
    "name": "NeoVibe — 7. Reconnaissance : la clé de diffusion, et ses deux trous",
    "nodes": [
        n("moi", "group", "MON TÉLÉPHONE", desc="celui qui émet et qui écoute", children=[
            n("ident", "module", "ProximityIdentity",
              desc="mon identité d'appareil — un seul exemplaire dans toute l'app",
              children=[
                  n("k_cur", "variable", "broadcast_key (courante)", dtype="secret",
                    value="32 octets aléatoires"),
                  n("k_prev", "variable", "broadcast_key_prev", dtype="secret",
                    value="l'ancienne, gardée après rotation"),
                  n("rot_at", "variable", "rotated_at", dtype="date",
                    value="date de la dernière rotation"),
              ]),
            n("calc", "transform", "currentRotatingId()",
              desc="HMAC(clé, « nv-slot-N ») → 16 octets. N'utilise QUE la clé courante"),
            n("sup", "service", "ProximitySupervisor",
              desc="vit en Dart : meurt avec l'interface", children=[
                  n("tick", "trigger", "minuteur — chaque minute"),
                  n("cond_slot", "condition", "créneau de 15 min changé ?"),
                  n("push", "action", "updateAdvert(nouvel ID)"),
              ]),
            n("natif", "container", "ProximityService (Kotlin)",
              desc="service de premier plan : possède la radio, survit à l'interface",
              children=[
                  n("adv", "action", "advertising BLE",
                    desc="crie l'ID toutes les ~100 ms. Ne le calcule JAMAIS lui-même"),
                  n("scan", "trigger", "scan BLE", desc="détecte les annonces alentour"),
              ]),
            n("sync", "service", "ProximitySync.run()",
              desc="le SEUL chemin vers le serveur. Aucun minuteur : que des déclencheurs",
              children=[
                  n("s_rot", "condition", "clé vieille de 7 jours ?"),
                  n("s_new", "action", "rotation : K1 devient « prev », K2 devient courante"),
                  n("s_pub", "action", "_publishKeys — upsert device_keys"),
                  n("s_pull", "action", "_pullFriendKeys — remplace tout le carnet"),
              ]),
            n("trig", "trigger", "6 déclencheurs de la synchro",
              desc="ouverture de l'app · croisement certifié · ami accepté (x2) · wave · reset dev"),
            n("book", "cache", "FriendKeyBook",
              desc="carnet local : reconnaître un ami hors ligne, sans poignée de main",
              children=[
                  n("f_key", "variable", "broadcastKey (de l'ami)", dtype="secret"),
                  n("f_prev", "variable", "previousBroadcastKey (de l'ami)", dtype="secret"),
              ]),
            n("index", "transform", "rotatingIndex(slot)",
              desc="2 clés × 3 créneaux par ami → table ID(hex) → ami. Le double de travail"),
            n("onscan", "fn", "PeerNetwork._onScan"),
            n("cond_known", "condition", "cet ID est-il dans ma table ?"),
            n("vu", "action", "« X est là » — reconnu hors ligne, sans rien lui demander"),
        ]),

        n("sb", "cluster", "Supabase",
          desc="n'intervient QUE quand l'app tourne et qu'il y a du réseau", children=[
              n("tbl", "table", "device_keys", children=[
                  n("c_key", "variable", "broadcast_key", dtype="string"),
                  n("c_prev", "variable", "broadcast_key_prev", dtype="string"),
                  n("c_rot", "variable", "rotated_at", dtype="date"),
              ]),
          ]),

        n("ami", "group", "TÉLÉPHONE DE L'AMI",
          desc="il ne reçoit rien tant qu'il n'ouvre pas son app", children=[
              n("a_sync", "service", "sa synchro",
                desc="part quand IL ouvre son app — pas quand JE tourne ma clé"),
              n("a_book", "cache", "son carnet de clés"),
              n("a_index", "transform", "son index rotatif"),
              n("a_cond", "condition", "l'ID qu'il capte est-il dans son index ?"),
              n("a_ok", "action", "il me voit", desc="il a resynchronisé : il a K2"),
              n("a_ko", "error", "il ne me voit plus — en silence",
                desc="il n'a pas resynchronisé : il n'a que K1 et K0"),
          ]),

        n("note_a", "note", "POINT A — la clé précédente ne sert à personne",
          desc="Dès la rotation je n'émets QUE K2. Celui qui a resynchronisé a K2 : "
               "la précédente ne lui sert à rien. Celui qui n'a pas resynchronisé n'a "
               "ni K2 ni la publication de K1 : elle ne lui parvient pas. Elle coûte "
               "une colonne, un champ et le DOUBLE de l'indexation, pour zéro effet."),
        n("note_h", "note", "POINT H (à vérifier sur appareil) — l'ID émis peut se figer",
          desc="Le minuteur du créneau vit en Dart. Si Android détruit l'activité, "
               "plus personne ne pousse de nouvel ID : le natif rejoue le dernier reçu. "
               "Passé ~30 min il sort de la fenêtre slot-1 / slot / slot+1 et PLUS AUCUN "
               "ami ne me reconnaît, même avec la bonne clé."),
    ],

    "edges": [
        e("trig", "sync", "flow", "déclenche"),
        e("sync", "s_rot", "flow"),
        e("s_rot", "s_new", "flow", "oui"),
        e("s_rot", "s_pub", "flow", "non"),
        e("s_new", "s_pub", "flow"),
        e("s_new", "k_cur", "data", "écrit K2"),
        e("s_new", "k_prev", "data", "écrit K1"),
        e("s_new", "rot_at", "data", "now()"),
        e("s_pub", "tbl", "data", "upsert des 2 clés"),
        e("tbl", "s_pull", "data", "SELECT les clés de mes amis"),
        e("s_pull", "book", "data", "replace() — remplace TOUT"),

        e("k_cur", "calc", "dep", "SEULE la courante"),
        e("k_prev", "c_prev", "dep", "publiée… mais jamais émise"),
        e("tick", "cond_slot", "flow"),
        e("cond_slot", "calc", "flow", "oui"),
        e("calc", "push", "flow", "ID du créneau (16 octets)"),
        e("push", "adv", "call", "updateAdvert"),

        e("book", "index", "dep", "les 2 clés de chaque ami"),
        e("index", "cond_known", "dep", "table ID → ami"),
        e("scan", "onscan", "event", "adresse + ID + RSSI"),
        e("onscan", "cond_known", "flow"),
        e("cond_known", "vu", "flow", "oui"),

        e("adv", "a_cond", "data", "mon ID rotatif, en clair dans l'air"),
        e("tbl", "a_sync", "data", "SELECT ma clé — seulement s'il ouvre l'app"),
        e("a_sync", "a_book", "data", "replace()"),
        e("a_book", "a_index", "dep"),
        e("a_index", "a_cond", "dep"),
        e("a_cond", "a_ok", "flow", "oui — il a K2"),
        e("a_cond", "a_ko", "flow", "non — il en est resté à K1"),
    ],
}


# ---------------------------------------------------------------------------
# 8 — PROPOSITION : un secret par paire, dérivé, jamais transmis
# ---------------------------------------------------------------------------

par_paire = {
    "name": "NeoVibe — 8. Le secret par paire (rien à distribuer)",
    "nodes": [
        n("intro", "note", "L'idée en une phrase (implémenté le 2026-08-20)",
          desc="Aujourd'hui UN secret est partagé avec TOUS les amis, donc il faut le "
               "distribuer, le tenir à jour et le remplacer — d'où le trou. Ici, chaque "
               "PAIRE calcule son propre secret de son côté, à partir de clés publiques. "
               "Rien de secret ne transite jamais. Il n'y a donc plus rien à synchroniser."),

        n("once", "group", "UNE SEULE FOIS — quand on devient amis", children=[
            n("meet", "trigger", "rencontre BLE, ou recommandation d'un ami commun"),
            n("swap", "action", "échange des clés PUBLIQUES",
              desc="déjà fait aujourd'hui : FriendRequest / FriendAccept portent devicePublicKey"),
            n("dh", "transform", "S_AB = X25519(ma clé privée, sa clé publique)",
              desc="Diffie-Hellman : les deux côtés obtiennent le MÊME secret sans que le "
                   "secret ne circule. Primitive déjà utilisée dans secure_channel.dart"),
            n("carnet", "cache", "carnet local", children=[
                n("v_pub", "variable", "sa clé publique", dtype="string"),
                n("v_s", "variable", "S_AB — secret de CETTE paire", dtype="secret",
                  value="ne quitte jamais l'appareil, n'est jamais envoyé au serveur"),
            ]),
        ]),

        n("emit", "group", "MON TÉLÉPHONE — ce que j'émets", children=[
            n("cycle", "loop", "je cycle sur mes N amis",
              desc="une annonce sur N s'adresse à chaque ami. Latence de détection ∝ N — "
                   "À MESURER sur appareil"),
            n("tok", "transform", "token = HMAC(S_AB, créneau)",
              desc="un jeton DIFFÉRENT par ami : seul l'ami visé peut le reconnaître"),
            n("adv2", "action", "advertising BLE"),
            n("revoke", "action", "retirer un ami = effacer S_AB, cesser d'émettre son jeton",
              desc="instantané, hors ligne, SANS AUCUN effet sur les autres amis"),
        ]),

        n("recv", "group", "TÉLÉPHONE DE L'AMI — ce qu'il calcule", children=[
            n("pre", "transform", "table des jetons attendus",
              desc="N amis × 3 créneaux, calculée localement. Moitié moins qu'aujourd'hui "
                   "(plus de clé « précédente »)"),
            n("match", "condition", "le jeton capté est-il dans ma table ?"),
            n("hit", "action", "c'est Charles — et personne d'autre ne pouvait le savoir"),
            n("miss", "action", "du bruit : on ignore, aucune connexion ouverte"),
        ]),

        n("cross", "group", "LE CROISEMENT — ce qu'on cherche vraiment", children=[
            n("link", "action", "connexion BLE brève",
              desc="ouverte SEULEMENT vers un ami déjà reconnu : jamais vers un inconnu"),
            n("mutual", "condition", "les DEUX côtés ont-ils signé ?"),
            n("cert", "transform", "certificat de croisement co-signé A + B",
              desc="existe déjà : sigA / sigB dans CertFinalMessage"),
            n("oneway", "error", "observation à sens unique — ignorée",
              desc="un guetteur qui écoute sans jamais s'annoncer ne produit AUCUN croisement"),
            n("moteur", "service", "moteur de décision du croisement", children=[
                n("m_band", "variable", "bande de proximité", dtype="enum"),
                n("m_geo", "variable", "recoupement géographique", dtype="object"),
                n("m_hist", "variable", "historique de la paire", dtype="array"),
            ]),
            n("notif", "action", "notification « vous vous êtes croisés »"),
        ]),

        n("srv", "external", "Supabase",
          desc="ne sert plus qu'à transporter des clés PUBLIQUES, et seulement quand la "
               "rencontre n'est pas physique. Plus aucun secret côté serveur"),

        n("note_trou", "note", "CE QUE ÇA SUPPRIME",
          desc="① Le trou de 7 jours : il n'y a plus de clé partagée à distribuer, donc "
               "plus rien à rater. ② Le coût de la révocation (RAPPELS #46) : retirer un "
               "ami n'aveugle plus les autres. ③ Le secret global : une fuite ne compromet "
               "qu'UNE relation, pas toutes. ④ La dépendance au réseau : le ping devient "
               "entièrement hors ligne après l'amitié."),
        n("note_stalk", "note", "ANTI-STALKING : structurel, pas une option",
          desc="Un croisement n'existe que s'il est CO-SIGNÉ. On ne peut donc pas observer "
               "sans être observé : le guetteur passif ne produit rien. Et chaque jeton "
               "n'étant lisible que par un seul ami, un réseau de capteurs anonymes ne voit "
               "que du bruit — il ne peut ni te suivre, ni te compter."),
        n("note_cout", "note", "CE QUE ÇA COÛTE — à mesurer, pas à supposer",
          desc="① Latence de détection ∝ nombre d'amis (N annonces à faire tourner). "
               "② Le nombre de jetons distincts émis laisse deviner le nombre d'amis. "
               "③ Une réinstallation change la clé publique : les paires se recalculent à "
               "la prochaine synchro des deux côtés. ④ C'est une rupture de protocole : "
               "à faire AVANT la mise en production, pas après."),
    ],

    "edges": [
        e("meet", "swap", "flow"),
        e("swap", "dh", "flow", "sa clé publique"),
        e("dh", "v_s", "data", "écrit S_AB"),
        e("swap", "v_pub", "data"),
        e("srv", "swap", "data", "clés publiques (recommandation)"),

        e("v_s", "tok", "dep", "un secret par ami"),
        e("cycle", "tok", "flow"),
        e("tok", "adv2", "flow", "jeton du créneau"),
        e("v_s", "revoke", "dep"),
        e("revoke", "cycle", "event", "un ami de moins dans le cycle"),

        e("adv2", "match", "data", "jeton lisible par UN SEUL destinataire"),
        e("v_s", "pre", "dep", "le même S_AB, calculé de son côté"),
        e("pre", "match", "dep", "table jeton → ami"),
        e("match", "hit", "flow", "oui"),
        e("match", "miss", "flow", "non"),

        e("hit", "link", "flow", "ami reconnu"),
        e("link", "mutual", "flow"),
        e("mutual", "oneway", "flow", "non"),
        e("mutual", "cert", "flow", "oui"),
        e("cert", "moteur", "data", "croisement candidat"),
        e("moteur", "notif", "flow", "vrai croisement"),
        e("m_band", "moteur", "dep"),
        e("m_geo", "moteur", "dep"),
        e("m_hist", "moteur", "dep"),
    ],
}
