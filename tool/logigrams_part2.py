"""Schémas 4 à 6 — voir `build_logigrams.py` pour le validateur."""

from build_logigrams import n, e

vibe = {
    "name": "NeoVibe — 4. Une Vibe, de la capture au partage",
    "nodes": [
        n("intro4", "note", "La règle : 1 contenu = 1 contexte",
          desc="Une Vibe part vers UN seul endroit. Ce n'est pas une limite "
               "technique : c'est ce qui empêche un contenu d'échapper aux "
               "règles qu'on lui a données."),

        n("capture", "client", "Écran de capture", children=[
            n("t_choix", "condition", "quel type de Vibe ?"),
            n("t_std", "action", "Standard",
              desc="une ou deux faces, le verso est facultatif"),
            n("t_one", "action", "Oneshot",
              desc="avant et arrière d'un seul déclenchement, aucun outil"),
            n("t_be", "action", "BeReal",
              desc="déclenché par notification, sans retouche"),
            n("v_faces", "variable", "faces", dtype="fichier", value="photo ou vidéo"),
        ]),

        n("prep", "module", "Préparation avant l'envoi", children=[
            n("seal", "transform", "chiffrement par blocs",
              desc="on peut lire le début sans tout télécharger"),
            n("v_cle4", "variable", "clé du média", dtype="secret",
              value="elle ne part PAS avec le fichier"),
            n("up", "action", "envoi au coffre"),
        ]),

        n("dest", "condition", "Où l'envoyer ?", desc="choix EXCLUSIF"),
        n("d_story", "action", "Story", desc="visible 24 h"),
        n("d_pub", "action", "Publication", desc="reste dans ma bibliothèque"),
        n("d_cercle", "action", "Envoi direct",
          desc="à une ou plusieurs personnes choisies"),
        n("d_biblio", "action", "Bibliothèque de conversation",
          desc="chacun dépose, tout se révèle à 18 h 30"),

        n("regles", "module", "Les règles attachées au contenu", children=[
            n("v_vues", "variable", "nombre de vues", dtype="number",
              value="décompté par le SERVEUR, pas par l'app"),
            n("v_duree", "variable", "durée par face", dtype="number"),
            n("v_save", "variable", "peut être enregistrée ?", dtype="boolean"),
            n("v_ttl", "variable", "expiration", dtype="date", value="24 h"),
        ]),

        n("oneofone", "note", "One of One",
          desc="un seul destinataire et aucune publication : la règle s'applique "
               "TOUTE SEULE à l'envoi, ce n'est plus un type à choisir"),

        n("srv4", "cluster", "Serveur", children=[
            n("t_contents", "table", "contents", desc="stories et publications"),
            n("t_cards", "table", "cards", desc="vibes envoyées en messagerie"),
            n("t_lib", "table", "library_vibes", desc="bibliothèques de conversation"),
            n("coffre4", "storage", "coffres de médias", desc="octets chiffrés"),
        ]),

        n("purge", "trigger", "Ménage automatique (chaque nuit)",
          desc="ce qui a expiré disparaît"),
    ],
    "edges": [
        e("t_choix", "t_std", "flow"),
        e("t_choix", "t_one", "flow"),
        e("t_choix", "t_be", "flow"),
        e("t_std", "seal", "flow"),
        e("t_one", "seal", "flow"),
        e("t_be", "seal", "flow"),
        e("v_faces", "seal", "data"),
        e("seal", "v_cle4", "data", "produit la clé"),
        e("seal", "up", "flow"),
        e("up", "coffre4", "data", "octets chiffrés"),
        e("up", "dest", "flow"),
        e("dest", "d_story", "flow"),
        e("dest", "d_pub", "flow"),
        e("dest", "d_cercle", "flow"),
        e("dest", "d_biblio", "flow"),
        e("d_story", "t_contents", "data", "INSERT"),
        e("d_pub", "t_contents", "data", "INSERT"),
        e("d_cercle", "t_cards", "data", "INSERT + 1 livraison par personne"),
        e("d_biblio", "t_lib", "data", "INSERT"),
        e("regles", "d_cercle", "dep", "s'attachent ici"),
        e("oneofone", "d_cercle", "dep"),
        e("purge", "t_contents", "flow", "DELETE si expiré"),
        e("intro4", "dest", "dep"),
    ],
}

livraison = {
    "name": "NeoVibe — 5. Comment un média arrive à l'écran",
    "nodes": [
        n("intro5", "note", "Deux barrières, pas une",
          desc="Avoir les octets ne suffit pas : ils sont chiffrés. Avoir la clé "
               "ne suffit pas : il faut aussi les octets. Le serveur ne donne la "
               "clé qu'à celui qui y a droit — et il en profite pour compter la vue."),

        n("ecran5", "client", "Visionneuse", children=[
            n("ouvre", "trigger", "l'utilisateur ouvre une Vibe"),
        ]),

        n("c_cache", "condition", "déjà téléchargé ?"),
        n("cache", "cache", "Cache local", children=[
            n("v_blocs", "variable", "blocs déjà là", dtype="array"),
        ]),

        n("srv5", "cluster", "Serveur", children=[
            n("rpc5", "api", "open_card_media",
              desc="vérifie le droit, DÉCOMPTE une vue et rend la clé — "
                   "en une seule opération indivisible"),
            n("c_droit", "condition", "a-t-il le droit ?"),
            n("c_reste", "condition", "reste-t-il des vues ?"),
            n("t_keys", "table", "clé du média"),
            n("url", "action", "URL signée, valable quelques minutes"),
            n("coffre5", "storage", "coffre"),
            n("refus5", "error", "refusé"),
        ]),

        n("dl", "action", "télécharger par tranches",
          desc="juste ce qu'il faut pour commencer à lire"),

        n("natif5", "container", "Lecteur natif (Kotlin)", children=[
            n("dechiffre", "transform", "déchiffrer bloc par bloc",
              desc="en mémoire, à la volée"),
            n("lecture", "action", "afficher / lire la vidéo"),
        ]),

        n("jamais", "note", "Jamais de clair sur le disque",
          desc="« Ce qui se passe sur NeoVibe reste sur NeoVibe ». Un fichier "
               "déchiffré écrit sur le téléphone serait une promesse rompue."),

        n("vue", "trigger", "après 3 secondes à l'écran",
          desc="c'est là qu'on dit au serveur « il l'a vraiment vue »"),
        n("t_views", "table", "content_views"),
    ],
    "edges": [
        e("ouvre", "c_cache", "flow"),
        e("c_cache", "dechiffre", "flow", "oui"),
        e("c_cache", "url", "flow", "non"),
        e("ouvre", "rpc5", "call", "la clé est nécessaire dans tous les cas"),
        e("rpc5", "c_droit", "flow"),
        e("c_droit", "refus5", "flow", "non"),
        e("c_droit", "c_reste", "flow", "oui"),
        e("c_reste", "refus5", "flow", "épuisées"),
        e("c_reste", "t_keys", "flow", "oui — rend la clé"),
        e("url", "coffre5", "call"),
        e("coffre5", "dl", "data", "tranches d'octets"),
        e("dl", "cache", "data", "range"),
        e("cache", "dechiffre", "data", "octets chiffrés"),
        e("t_keys", "dechiffre", "data", "la clé"),
        e("dechiffre", "lecture", "flow"),
        e("lecture", "vue", "flow"),
        e("vue", "t_views", "data", "INSERT"),
        e("jamais", "dechiffre", "dep"),
        e("intro5", "rpc5", "dep"),
    ],
}

donnees = {
    "name": "NeoVibe — 6. Le modèle de données",
    "nodes": [
        n("intro6", "note", "29 tables, 7 familles",
          desc="Chaque famille a ses propres règles de durée de vie et d'accès. "
               "C'est pour ça qu'elles ne se mélangent pas."),

        n("g_id", "group", "Qui es-tu", children=[
            n("t_profiles", "table", "profiles", desc="pseudo, avatar, réglages"),
            n("t_device", "table", "device_keys",
              desc="clés publiques — lisibles UNIQUEMENT par tes amis"),
        ]),

        n("g_lien", "group", "Le lien social", children=[
            n("t_conn6", "table", "connections", desc="l'amitié"),
            n("t_req", "table", "connection_requests", desc="demandes par recommandation"),
            n("t_enc", "table", "encounters", desc="croisements certifiés (24 h)"),
            n("t_waves", "table", "waves", desc="« le presque »"),
            n("t_reco", "table", "recommendations", desc="A présente B à C"),
            n("t_blocks", "table", "blocks", desc="blocages"),
        ]),

        n("g_contenu", "group", "Contenus publiés", children=[
            n("t_contents6", "table", "contents", desc="le socle : stories + publications"),
            n("t_stories", "table", "stories", desc="24 h"),
            n("t_items", "table", "library_items", desc="ma bibliothèque"),
            n("t_grants", "table", "content_grants", desc="qui a le droit"),
            n("t_ckeys", "table", "content_media_keys", desc="clés"),
            n("t_views6", "table", "content_views", desc="qui a vu"),
        ]),

        n("g_vibes", "group", "Vibes envoyées", children=[
            n("t_cards6", "table", "cards"),
            n("t_deliv", "table", "card_deliveries",
              desc="une par destinataire — les vues restantes vivent ici"),
            n("t_ckeys2", "table", "card_media_keys"),
        ]),

        n("g_conv", "group", "Conversations", children=[
            n("t_conv6", "table", "conversations"),
            n("t_members", "table", "conversation_members"),
            n("t_msg", "table", "messages"),
            n("t_reads", "table", "message_reads"),
            n("t_cat", "table", "conversation_categories"),
            n("t_catm", "table", "conversation_category_members"),
        ]),

        n("g_biblio", "group", "Bibliothèques éphémères", children=[
            n("t_lv", "table", "library_vibes", desc="révélation à 18 h 30"),
            n("t_lvk", "table", "library_vibe_keys"),
            n("t_lacc", "table", "library_access"),
        ]),

        n("g_mod", "group", "Modération et outils", children=[
            n("t_creport", "table", "content_reports"),
            n("t_preport", "table", "profile_reports"),
            n("t_dev", "table", "dev_reports",
              desc="diagnostics de test — à retirer avant la prod"),
        ]),

        n("note_rls", "note", "La sécurité est DANS la base",
          desc="71 règles : même si l'app était modifiée, PostgreSQL refuserait "
               "de rendre ce à quoi on n'a pas droit."),
        n("note_cle", "note", "Les clés sont rangées à part",
          desc="Les octets d'un média vivent dans un coffre, sa clé dans une "
               "table. Obtenir l'un ne donne jamais l'autre."),
    ],
    "edges": [
        e("t_device", "t_conn6", "dep", "lisible seulement entre amis"),
        e("t_enc", "t_conn6", "flow", "10 s de contact → amitié possible"),
        e("t_reco", "t_req", "flow", "crée une demande"),
        e("t_req", "t_conn6", "flow", "acceptée"),
        e("t_stories", "t_contents6", "dep", "une story EST un contenu"),
        e("t_items", "t_contents6", "dep"),
        e("t_grants", "t_contents6", "dep"),
        e("t_ckeys", "t_contents6", "dep"),
        e("t_views6", "t_contents6", "dep"),
        e("t_deliv", "t_cards6", "dep"),
        e("t_ckeys2", "t_cards6", "dep"),
        e("t_deliv", "t_msg", "dep", "apparaît dans le fil"),
        e("t_members", "t_conv6", "dep"),
        e("t_msg", "t_conv6", "dep"),
        e("t_reads", "t_msg", "dep"),
        e("t_lv", "t_conv6", "dep"),
        e("t_lvk", "t_lv", "dep"),
        e("t_conn6", "t_members", "dep", "on ne parle qu'à ses amis"),
        e("note_rls", "t_conn6", "dep"),
        e("note_cle", "t_ckeys", "dep"),
        e("intro6", "g_id", "dep"),
    ],
}
