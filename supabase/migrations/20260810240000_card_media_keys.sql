-- La limite de vues devient une GARANTIE — decision de Jay, 2026-08-10 :
-- « on part sur la garantie […] on doit proteger nos utilisateurs. »
--
-- ─── Le defaut ─────────────────────────────────────────────────────────────
-- Le compteur vivait dans `mark_card_viewed`, une RPC que le client
-- CHOISISSAIT d'appeler, et la face etait telechargeable independamment. Un
-- client modifie sautait l'appel et gardait le fichier. La limite de vues
-- n'etait pas une garantie serveur : c'etait une convention client.
-- (Verifie dans le code : une face recue est mise en cache local et purgee par
-- l'app elle-meme quand les vues sont epuisees.)
--
-- ─── Le principe retenu ────────────────────────────────────────────────────
-- Les faces sont CHIFFREES au depot. Le decompte cesse d'etre une etape
-- separee : il devient **l'acte qui delivre la cle**. Pas de decompte, pas de
-- cle, pas d'image.
--
-- ─── Pourquoi ce modele et pas une URL signee par vue ──────────────────────
-- Objection de Jay, decisive : une URL par vue imposerait de RETELECHARGER la
-- face a chaque visionnage, donc de multiplier l'egress — alors que le cout
-- serveur doit rester bas. Ici les octets lourds voyagent UNE SEULE FOIS et
-- restent en cache local, chiffres ; seule la cle (44 caracteres) circule a
-- chaque vue. Trois ordres de grandeur plus economique, meme garantie.
--
-- ─── Limite assumee ────────────────────────────────────────────────────────
-- Un client modifie qui a deja dechiffre une fois peut conserver le clair.
-- Aucun mecanisme ne l'empeche sans retelecharger. La garantie est donc :
-- **aucun acces NOUVEAU sans le serveur** — pas « on ne revoit jamais ce qu'on
-- a dechiffre ». Coherent avec « couteux et visible, pas impossible ».

alter table public.cards
  add column if not exists encrypted boolean not null default false;

-- Table des cles, SANS AUCUNE POLITIQUE — comme `library_vibe_keys`. La RLS
-- agit par LIGNE et non par COLONNE : garder la cle dans `cards` la livrerait a
-- quiconque peut lire la ligne. Ici nul ne lit cette table directement.
create table if not exists public.card_media_keys (
  card_id uuid primary key references public.cards(id) on delete cascade,
  media_key text not null
);

alter table public.card_media_keys enable row level security;
revoke all on public.card_media_keys from public, anon, authenticated;

create or replace function public.set_card_media_key(
  p_card_id uuid,
  p_media_key text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  if not exists (
    select 1 from cards where id = p_card_id and owner_id = auth.uid()
  ) then
    raise exception 'Vibe introuvable';
  end if;

  -- `do nothing` et non `do update` : reecrire la cle rendrait illisibles les
  -- copies deja distribuees.
  insert into card_media_keys (card_id, media_key)
  values (p_card_id, p_media_key)
  on conflict (card_id) do nothing;
end;
$fn$;

-- Les chemins d'acces ILLIMITES, isoles de la livraison qui est LIMITEE.
-- `can_view_card_file` melange les deux ; le decompte a besoin de distinguer.
create or replace function private.has_unlimited_card_access(card uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $fn$
  select exists (
    select 1 from library_items li
    where li.card_id = card and can_view_library(li.owner_id, uid)
  )
  or exists (
    select 1 from library_items li
    where li.card_id = card and li.is_public and can_view_profile(uid, li.owner_id)
  )
  or exists (
    select 1 from saved_cards s where s.card_id = card and s.owner_id = uid
  )
  or is_story_card(card, uid);
$fn$;

-- ─── LE VERROU : obtenir la cle, c'est consommer une vue ───────────────────
create or replace function public.open_card_media(p_card_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_me uuid := auth.uid();
  v_card cards%rowtype;
  v_delivery card_deliveries%rowtype;
  v_effective_max integer;
begin
  select * into v_card from cards where id = p_card_id;
  if not found then
    raise exception 'Vibe introuvable';
  end if;

  -- 1. Le proprietaire : toujours, sans decompte. C'est son contenu.
  if v_card.owner_id = v_me then
    return (select media_key from card_media_keys where card_id = p_card_id);
  end if;

  -- 2. Acces ILLIMITE (bibliotheque, sauvegarde, story) : aucun decompte.
  --    Teste AVANT la livraison — « en bibliotheque, la lecture est
  --    illimitee », regle affichee dans l'app. Un destinataire ayant epuise
  --    ses vues doit donc pouvoir consulter une Vibe par ailleurs publiee.
  if private.has_unlimited_card_access(p_card_id, v_me) then
    return (select media_key from card_media_keys where card_id = p_card_id);
  end if;

  -- 3. Destinataire en conversation : ICI la limite s'applique, et le
  --    decompte est INDISSOCIABLE de la remise de la cle. C'est tout
  --    l'interet du mecanisme : le client ne peut plus sauter cette etape,
  --    puisque c'est elle qui lui donne de quoi lire.
  select * into v_delivery from card_deliveries
  where card_id = p_card_id and recipient_id = v_me
  for update;

  if not found then
    raise exception 'Vibe introuvable';
  end if;

  if v_delivery.destroyed_at is not null then
    raise exception 'Vibe detruite';
  end if;

  v_effective_max := coalesce(v_card.max_views, 2147483647)
    + case when v_delivery.replay_granted_at is not null then 1 else 0 end;

  if v_delivery.view_count >= v_effective_max then
    raise exception 'Plus de visionnages disponibles';
  end if;

  update card_deliveries
  set view_count = view_count + 1,
      first_viewed_at = coalesce(first_viewed_at, now())
  where id = v_delivery.id;

  return (select media_key from card_media_keys where card_id = p_card_id);
end;
$fn$;

revoke execute on function public.set_card_media_key(uuid, text) from public, anon;
revoke execute on function public.open_card_media(uuid) from public, anon;
grant execute on function public.set_card_media_key(uuid, text) to authenticated;
grant execute on function public.open_card_media(uuid) to authenticated;
