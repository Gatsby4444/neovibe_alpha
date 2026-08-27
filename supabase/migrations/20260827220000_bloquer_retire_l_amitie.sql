-- Bloquer quelqu'un, c'est cesser d'être son ami.
--
-- ## Ce que Jay a constaté, le 2026-08-27
--
--     « lorsque je bloque un ami, sur cet ami dans le compteur d'ami (le sien)
--       je compte toujours. J'ai testé en bloquant mimi. Il est toujours compté
--       chez moi aussi. »
--
-- C'était le comportement du code : `block_user` insérait une ligne dans
-- `blocks` et **ne touchait pas à `connections`**. Le compteur d'amis lit
-- `connections` — donc un ami bloqué restait un ami.
--
-- ## Pourquoi c'était pire qu'un affichage bizarre
--
-- ⚠️ **Le serveur continuait d'accepter vos croisements.** `report_sightings`
-- exige `connections.status = 'full'` — rien de plus. Deux personnes qui se
-- sont bloquées, mais restées « connectées », **continuaient d'accumuler des
-- croisements**, donc des streaks. Le blocage ne coupait pas ce qu'il y a de
-- plus intime dans le produit.
--
-- ## La règle, tranchée par Jay
--
-- **Bloquer retire l'amitié.** C'est ce que fait la plupart des applications, et
-- ça supprime l'ambiguïté : « ami » veut dire une seule chose.
--
-- ⚠️ **C'est irréversible, et c'est assumé** : débloquer ne rend pas l'amitié.
-- Il faudra se redemander — donc, la barrière du produit étant ce qu'elle est,
-- **se recroiser physiquement**. C'est cohérent : on ne redevient pas ami par
-- inadvertance.
--
-- ⚠️ **Le déclencheur `connections_delete_oublie` fait le reste** : supprimer la
-- connexion emporte le croisement et les constats de la paire. Un blocage efface
-- donc aussi l'historique de proximité — ce qui est exactement l'intention.
--
-- ⚠️ **Et les clés suivent** : `device_keys_friends` n'expose la clé publique
-- qu'entre amis. Plus d'amitié, plus de clé, donc **plus de reconnaissance par
-- la radio des deux côtés**. Le blocage atteint le Bluetooth sans qu'aucun
-- client n'ait à coopérer.

create or replace function public.block_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
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
end;
$$;

revoke all on function public.block_user(uuid) from public;
grant execute on function public.block_user(uuid) to authenticated;

comment on function public.block_user(uuid) is
  'Bloque quelqu''un ET retire l''amitié, les demandes en cours, et — par le '
  'déclencheur sur `connections` — le croisement et les constats de la paire. '
  '⚠️ Irréversible : débloquer ne rend pas l''amitié, il faut se redemander, '
  'donc se recroiser physiquement (décision de Jay, 2026-08-27).';
