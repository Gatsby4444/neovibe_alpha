-- Le secret par PAIRE remplace la clé de diffusion partagée.
-- Décision de Jay, 2026-08-20 (RAPPELS #51).
--
-- ## Ce qu'on supprime, et pourquoi la cause plutôt que le symptôme
--
-- `broadcast_key` était **un secret unique partagé avec tous les amis à la
-- fois**. Tout le reste en découlait mécaniquement : il fallait le distribuer
-- (donc un serveur et une synchronisation), le remplacer quand un ami partait
-- (donc une rotation), et attendre que tout le monde l'apprenne (donc un trou).
--
-- Trois défauts en sont nés, tous documentés :
--   - le trou de 7 jours : un ami qui n'avait pas rouvert l'app cessait de nous
--     voir, en silence, jusqu'à sa prochaine synchronisation ;
--   - `broadcast_key_prev` prétendait le combler et ne changeait **aucun**
--     résultat de reconnaissance — l'émission n'a jamais utilisé que la clé
--     courante (audit du 2026-08-18, point A) ;
--   - une révocation aveuglait TOUS les autres amis, puisqu'elle faisait
--     tourner l'unique clé (RAPPELS #46 ②).
--
-- ## Ce qu'on met à la place
--
-- Chaque **paire** dérive son propre secret, et il ne transite jamais :
--
--     S_AB = X25519(clé privée de A, clé publique de B)
--          = X25519(clé privée de B, clé publique de A)
--
-- Le serveur ne transporte donc plus que des clés **publiques**. Il n'y a plus
-- rien à garder synchronisé, donc plus de trou. Retirer un ami est une
-- opération purement locale — on efface son secret et on cesse d'émettre son
-- jeton — et cela n'a **aucun effet** sur les autres amis.
--
-- ## Sens ENTRANT et SORTANT relevés avant de couper (règle 8)
--
-- Entrant — qui lit ces colonnes ? Relevé en base le 2026-08-20 :
--   - fonctions : `report_encounter` et `submit_ble_connection` lisent
--     `device_keys`, mais **uniquement `ed_pub`**. Vérifié dans `prosrc`.
--   - politiques : `device_keys_own` et `device_keys_friends` ne nomment aucune
--     colonne — elles filtrent sur `user_id`.
--   - vues, triggers, clés étrangères, jobs cron : aucun.
-- Sortant — ce que ces colonnes utilisaient : rien, ce sont des données.
--
-- `ed_pub` est CONSERVÉE : elle sert aux signatures (certificat de croisement,
-- enregistrement d'amitié), qui n'ont rien à voir avec la reconnaissance.

alter table public.device_keys
  add column if not exists x25519_pub text;

comment on column public.device_keys.x25519_pub is
  'Clé publique X25519, pour dériver le secret par paire. PUBLIQUE : rien ici ne '
  'permet de reconnaître qui que ce soit sans la clé privée d''en face.';

-- ⚠️ Nullable **volontairement, et temporairement**. Les lignes existantes ont
-- été écrites par une version qui n'avait pas de clé X25519, et personne ne peut
-- la calculer à leur place : seule la clé privée, restée sur l'appareil, le
-- peut. Chaque appareil republie à sa prochaine synchronisation.
--
-- Un ami sans `x25519_pub` est simplement **non reconnaissable** en attendant —
-- il n'est plus traité comme un ami parti, parce que la révocation par rotation
-- n'existe plus. C'était le faux positif documenté au point d'appel de
-- `_pullFriendKeys` ; il disparaît avec la cause.
--
-- À passer `not null` une fois que tous les appareils de test ont republié.

alter table public.device_keys drop column if exists broadcast_key;
alter table public.device_keys drop column if exists broadcast_key_prev;
alter table public.device_keys drop column if exists rotated_at;
