-- Le tampon Ed25519 de l'appareil est retiré — décision de Jay du 2026-08-27.
--
-- ## Ce que c'était
--
-- Chaque appareil portait **deux** clés :
--
-- | Clé | Rôle | Sort |
-- |---|---|---|
-- | **X25519** | fabriquer le jeton BLE que **seul un ami donné** reconnaît | 🟢 **vitale, intacte** |
-- | **Ed25519** | **signer** ce qui voyageait par la radio | 🔴 retirée ici |
--
-- ⚠️ **NE PAS CONFONDRE LES DEUX.** `device_keys.x25519_pub` reste le cœur du
-- ping : sans elle, plus aucun ami n'est reconnu. Seule `ed_pub` part.
--
-- ## Pourquoi elle ne sert plus à rien
--
-- Elle signait ce qui circulait **en Bluetooth** : le mini-profil, le certificat
-- de croisement co-signé, la demande d'ami et son acceptation. Tout cela est
-- parti le 2026-08-27 avec le transport BLE. Il ne restait qu'une chaîne
-- complète sans consommateur : l'appareil générait la clé, la publiait, et deux
-- fonctions serveur la relisaient — que **plus personne n'appelait**.
--
-- ## ⚠️ L'argument qui la maintenait en vie est tombé
--
-- Je l'avais conservée en invoquant `RAPPELS.md` #2 — l'attestation serveur
-- contre l'usurpation de pseudo hors ligne. **Cette prémisse est morte** : ce
-- chantier n'existait que parce qu'un pseudo pouvait être annoncé en BLE. La
-- radio ne transporte plus que des jetons opaques que seul le serveur sait
-- nommer. **Il n'y a plus de pseudo à usurper hors ligne.**
--
-- C'est la règle 6 de `CLAUDE.md` : après un changement d'architecture, rejouer
-- les décisions qui en dépendaient au lieu de dérouler un plan écrit avant.
--
-- ## ⚠️ Réversible, et à quel prix
--
-- Rien de signé n'est conservé nulle part : aucune donnée ne devient
-- illisible. Réintroduire un jour une identité signante ne coûterait que de
-- regénérer des clés et de les republier.
--
-- ## ⚠️ Sens entrant relevé avant de couper (règle 8)
--
-- Vérifié le 2026-08-27, côté serveur ET côté Dart :
--
--   * `report_encounter` — **aucun appelant** (le cas `encounter` de la file
--     d'envoi a été retiré avec le transport) ;
--   * `submit_ble_connection` — **aucun appelant** (le cas `connection` idem) ;
--   * `private.verify_ed25519` — appelé **uniquement** par ces deux-là ;
--   * `device_keys.ed_pub` — lu **uniquement** par ces deux-là.
--
-- Et le sens sortant : la colonne n'a ni index, ni vue, ni contrainte qui la
-- cite (seules `device_keys_pkey` sur `user_id` et la clé étrangère vers
-- `profiles` existent).
--
-- ⚠️ **UN CLIENT ANTÉRIEUR À v0.9.136 CASSERA SA SYNCHRO** : il fait un `upsert`
-- portant `ed_pub`, qui n'existera plus. Ce n'est pas destructeur — les clés
-- d'amis cessent simplement de se rafraîchir — mais **les deux appareils
-- doivent être mis à jour ensemble**.

-- L'ordre compte : les fonctions citent la colonne.
drop function if exists public.report_encounter(jsonb);
drop function if exists public.submit_ble_connection(jsonb);
drop function if exists private.verify_ed25519(text, text, text);

alter table public.device_keys drop column ed_pub;

comment on table public.device_keys is
  'La clé PUBLIQUE X25519 de chaque appareil, et rien d''autre. Elle sert à '
  'dériver le secret de paire dont naît le jeton BLE d''un ami. '
  '⚠️ La colonne `ed_pub` (tampon de signature Ed25519) a été retirée le '
  '2026-08-27 : ce qu''elle signait voyageait par la radio, et la radio ne '
  'transporte plus rien.';
