-- Bloquer déchire AUSSI le ticket de proximité.
--
-- ## 🔴 Le trou que ceci ferme — relevé en base le 2026-08-29
--
-- `block_user` faisait déjà le ménage : il supprimait l'amitié et les demandes
-- en attente. Mais il laissait intacte la ligne de `ping_pairs` — le « ticket »
-- émis quand deux appareils se sont mutuellement entendus.
--
-- Or c'est ce ticket, et lui seul, que regardent les deux fonctions qui
-- ouvrent quelque chose entre deux inconnus :
--
--   | fonction | fenêtre |
--   |---|---|
--   | `get_or_create_proximity_conversation` | `fenetre_canal()` = 3 min |
--   | `request_connection_from_proximity`    | `fenetre_rencontre()` = 10 min |
--
-- **Aucune des deux ne consulte `blocks`.** Une personne qu'on venait de
-- bloquer pouvait donc encore ouvrir un fil de discussion pendant 3 minutes, et
-- envoyer une demande d'ami pendant 10 minutes.
--
-- ## ⚠️ Pourquoi supprimer le ticket, et pas ajouter un filtre
--
-- Ajouter `is_blocked` dans les deux fonctions marcherait, et laisserait la
-- barrière énoncée NÉGATIVEMENT : « le ticket existe, mais deux endroits
-- refusent de s'en servir ». Il faudrait alors se souvenir de le refuser dans
-- le troisième endroit, le jour où il apparaîtra.
--
-- `confirm_ping` empêche déjà toute paire de NAÎTRE entre deux personnes qui se
-- sont bloquées. En supprimant celles qui existent, la règle devient positive
-- et complète : **entre deux personnes qui se sont bloquées, il n'y a pas de
-- ticket.** Il n'y a plus rien à filtrer, donc plus rien à oublier de filtrer.
--
-- ## Effet visible
--
-- Après un déblocage, il faut se revoir (10 à 20 s) avant que « Écrire » et
-- « Demander en ami » redeviennent possibles. C'est le comportement attendu :
-- le ticket atteste d'une proximité, et celle d'avant le blocage a été
-- répudiée.

create or replace function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'private'
as $function$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Non authentifié';
  end if;
  if p_user_id is null or p_user_id = me then
    raise exception 'Destinataire invalide';
  end if;

  insert into public.blocks (blocker_id, blocked_id)
  values (me, p_user_id)
  on conflict do nothing;

  -- ⚠️ **L'amitié part avec.** Le déclencheur sur `connections` emporte à son
  -- tour le croisement et les constats : sans ça, deux personnes qui se sont
  -- bloquées continueraient d'accumuler des streaks.
  delete from public.connections c
  where c.user_low = least(me, p_user_id)
    and c.user_high = greatest(me, p_user_id);

  -- ⚠️ **Les demandes en cours aussi**, dans les deux sens. Laisser une demande
  -- en attente entre deux personnes qui se sont bloquées, c'est garder une porte
  -- que le blocage venait de fermer.
  delete from public.connection_requests r
  where (r.sender_id = me and r.receiver_id = p_user_id)
     or (r.sender_id = p_user_id and r.receiver_id = me);

  -- 🔴 **LE TICKET DE PROXIMITÉ, ajouté le 2026-08-29.**
  --
  -- C'est lui qui ouvre le chat de proximité et la demande d'ami entre
  -- inconnus. Le laisser en place, c'était laisser 3 et 10 minutes de porte
  -- ouverte à quelqu'un qu'on vient de bloquer.
  delete from public.ping_pairs pp
  where pp.user_low = least(me, p_user_id)
    and pp.user_high = greatest(me, p_user_id);

  -- ⚠️ **Et les confirmations qui n'ont pas encore trouvé leur miroir.**
  --
  -- Vérifié avant d'écrire ceci : `private.is_blocked` est **symétrique**, donc
  -- `confirm_ping` coupe les DEUX côtés tant que le blocage tient. Ce n'est
  -- donc pas ce qui recréerait la paire pendant le blocage.
  --
  -- Ce que ça ferme est ailleurs, et c'est réel : une paire naît quand deux
  -- confirmations se font face **à un créneau près** — jusqu'à 45 minutes de
  -- tolérance. Après un déblocage, une confirmation d'AVANT le blocage
  -- rencontrerait la première d'après, et fabriquerait un ticket à partir d'une
  -- proximité que le blocage venait précisément de répudier.
  delete from public.ping_confirmations pc
  where (pc.observer_id = me and pc.subject_id = p_user_id)
     or (pc.observer_id = p_user_id and pc.subject_id = me);
end;
$function$;
