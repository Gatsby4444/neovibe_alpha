-- ===========================================================================
-- `device_keys.x25519_pub` devient NOT NULL
-- ===========================================================================
--
-- `RAPPELS.md` #54 ③, ouvert le 2026-08-20 : *« `x25519_pub` est NULLABLE en
-- base, le temps que les appareils de test republient. À passer `not null` une
-- fois que c'est fait. »*
--
-- ✅ **La condition est remplie, et vérifiée avant d'écrire cette ligne**
-- (2026-08-30) : `device_keys` porte 2 lignes, **zéro sans clé**.
--
-- ## Pourquoi ce n'est pas cosmétique
--
-- Une ligne sans clé publique est un objet qui ne peut RIEN faire : le secret
-- par paire se dérive des deux clés (`ProximityIdentity.pairSecrets`). Sans
-- elle, l'ami n'est ni reconnu, ni émis — et **rien ne lève**. La règle
-- s'énonce donc positivement, comme le demande `CLAUDE.md` : *cette ligne
-- n'existe pas*, plutôt que *cette ligne existe mais ne sert à rien*.
--
-- ## Inventaire avant de resserrer — les deux sens
--
-- ⬅️ **Qui écrit ici ?** Une seule politique, `device_keys_own [ALL]`, et un
--    seul appelant Dart, `ProximitySync._publishKeys`, qui passe toujours une
--    valeur (elle vient du coffre de l'appareil, `nv_x25519_seed`).
-- ➡️ **Qui lit ?** `_pullFriendKeys` et la politique `device_keys_friends`.
--    Aucun des deux ne traite le cas nul autrement que comme un ami absent :
--    resserrer ne change donc aucun comportement, ça supprime un état
--    impossible à atteindre légitimement.
-- ===========================================================================

alter table public.device_keys
  alter column x25519_pub set not null;

comment on column public.device_keys.x25519_pub is
  'Clé publique X25519 de l''appareil. NOT NULL depuis le 2026-08-30 : une '
  'ligne sans clé ne permet de dériver aucun secret par paire, donc l''ami '
  'n''est ni reconnu ni émis — sans qu''aucune erreur ne soit levée.';
