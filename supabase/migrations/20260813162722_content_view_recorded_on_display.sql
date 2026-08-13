-- ════════════════════════════════════════════════════════════════════════
-- La vue d'un contenu du socle est enregistrée À L'AFFICHAGE, plus à la clé
-- ════════════════════════════════════════════════════════════════════════
--
-- Décision de Jay, 2026-08-13, en ouvrant le préchargement :
--   « les vues comptées séparément de l'envoi du fichier, côté client : quand
--     le client regarde disons 3 s le contenu, alors il envoie au serveur
--     qu'il l'a vu. »
--
-- POURQUOI c'était nécessaire
-- ---------------------------
-- `open_content_media` enregistrait une vue en rendant la clé. Précharger un
-- contenu — donc aller chercher sa clé d'avance — aurait inscrit au journal
-- de propagation des contenus que personne n'a regardés.
--
-- CE QUE ÇA CORRIGE EN PLUS
-- -------------------------
-- Il y avait DEUX portes vers une clé de contenu, aux comportements opposés :
-- `open_content_media` comptait, `library_media_keys` non. Consulter une
-- bibliothèque entière ne laissait donc aucune trace, alors qu'ouvrir une
-- seule publication en laissait une : **le journal sous-comptait déjà**.
-- Après cette migration, aucune des deux ne compte, et il n'existe plus qu'UN
-- SEUL point d'enregistrement. Le journal devient cohérent.
--
-- CE QUE ÇA COÛTE, ASSUMÉ
-- -----------------------
-- L'enregistrement dépend désormais du client : un client modifié pourrait ne
-- pas déclarer. C'est accepté ici et SEULEMENT ici — un contenu du socle n'a
-- **aucun budget de vues**, donc aucune promesse faite à son auteur n'en
-- dépend. `content_views` est un journal de propagation, pas une garantie.
--
-- ⚠️ NE S'APPLIQUE PAS AUX VIBES EN DM. `open_card_media` continue de vérifier,
-- décompter et rendre la clé dans une transaction unique — c'est la garantie
-- de la limite de vues (décision de Jay du 2026-08-10), et Jay a tranché le
-- 2026-08-13 qu'on ne préchargerait PAS les Vibes en messagerie.

create or replace function public.open_content_media(p_content_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid;
begin
  select owner_id into v_owner from contents where id = p_content_id;
  if not found or not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  -- La vue n'est PLUS enregistrée ici : obtenir la clé n'est pas regarder.
  -- Voir `public.record_content_view`, appelée après un temps d'affichage réel.
  return (select media_key from content_media_keys where content_id = p_content_id);
end;
$$;

-- ────────────────────────────────────────────────────────────────────────
-- Le seul point d'enregistrement d'une vue de contenu
-- ────────────────────────────────────────────────────────────────────────
--
-- Appelée par le client après un affichage RÉEL et prolongé (3 s). Le seuil
-- vit côté client : c'est une notion d'interface (« regarder »), pas une règle
-- de sécurité — et le serveur ne peut de toute façon pas l'observer.
--
-- L'audience est revérifiée : on n'inscrit pas au journal une vue d'un contenu
-- auquel l'appelant n'aurait pas droit. `record_view` est idempotente par
-- couple (contenu, spectateur) — elle incrémente au lieu de dupliquer.
create or replace function public.record_content_view(p_content_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me uuid := auth.uid();
  v_owner uuid;
begin
  select owner_id into v_owner from contents where id = p_content_id;
  if not found or not private.content_audience(p_content_id, v_me) then
    raise exception 'Contenu introuvable';
  end if;

  -- Regarder son propre contenu n'est pas une vue : c'était déjà la règle de
  -- `open_content_media`, elle est conservée telle quelle.
  if v_owner <> v_me then
    perform private.record_view(p_content_id, v_me);
  end if;
end;
$$;

-- Une RPC exposée sur /rest/v1/rpc/ : seuls les comptes authentifiés.
revoke all on function public.record_content_view(uuid) from public, anon;
grant execute on function public.record_content_view(uuid) to authenticated;
