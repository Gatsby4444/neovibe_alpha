-- Le direct : chaque changement d'une table suivie est ANNONCÉ.
--
-- La base est le seul endroit par où passent TOUS les changements : les
-- opérations du serveur, les balais, les effacements en cascade. Chaque
-- ligne ajoutée, modifiée ou supprimée dans l'une des 10 tables que l'app
-- suit en direct est annoncée sur le canal `nv_direct` (après validation de
-- la transaction : PostgreSQL ne livre une annonce qu'au commit). Le
-- serveur l'écoute, vérifie pour chaque abonné qu'il a le droit de voir la
-- ligne (les règles de `nv-app/src/direct.rs`), et la lui envoie.
--
-- L'annonce porte la ligne entière si elle tient (8 000 octets, la limite
-- de PostgreSQL), sinon seulement sa clé : le serveur la relira.
create or replace function nv.annoncer() returns trigger
language plpgsql as $$
declare
  v_ligne jsonb := to_jsonb(coalesce(new, old));
  v_annonce text;
begin
  v_annonce := jsonb_build_object('t', tg_table_name, 'op', tg_op, 'ligne', v_ligne)::text;
  if octet_length(v_annonce) > 7900 then
    v_annonce := jsonb_build_object('t', tg_table_name, 'op', tg_op, 'ligne',
      jsonb_strip_nulls(jsonb_build_object(
        'id', v_ligne -> 'id',
        'event_id', v_ligne -> 'event_id', 'user_id', v_ligne -> 'user_id',
        'conversation_id', v_ligne -> 'conversation_id',
        'recipient_id', v_ligne -> 'recipient_id', 'sender_id', v_ligne -> 'sender_id',
        'receiver_id', v_ligne -> 'receiver_id', 'target_id', v_ligne -> 'target_id',
        'requester_id', v_ligne -> 'requester_id', 'owner_id', v_ligne -> 'owner_id')),
      'partielle', true)::text;
  end if;
  perform pg_notify('nv_direct', v_annonce);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['card_deliveries', 'connection_requests', 'connections', 'event_challenges',
                           'event_group_members', 'event_presences', 'library_items', 'location_requests',
                           'messages', 'removals']
  loop
    execute format('drop trigger if exists zz_nv_direct on public.%I', t);
    execute format('create trigger zz_nv_direct after insert or update or delete on public.%I '
                   'for each row execute function nv.annoncer()', t);
  end loop;
end $$;
