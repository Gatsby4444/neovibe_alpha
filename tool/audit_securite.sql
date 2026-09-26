-- =============================================================================
-- AUDIT DE SÉCURITÉ SERVEUR — « la règle vit au serveur » (Jay, 2026-09-25)
-- =============================================================================
--
-- Rejoue, sous l'identité de vrais comptes de la base de DEV et avec la
-- sécurité active, chaque faille trouvée le 2026-09-25 — puis ANNULE tout
-- (`rollback`). Chaque ligne dit ce qui est attendu et ce qui s'est passé :
-- une ligne où `ok` vaut false est une régression.
--
-- Usage : le passer tel quel à la base de dev (requête SQL, PAT de
-- docdev/PATsupabase.txt). Dépend de comptes et de conversations de la base
-- de dev (Charles, le bot 92, la soirée terminée « Goat ») : à adapter si
-- ces données changent.
--
-- ⚠️ Une règle qui ne vit que dans l'écran n'est pas une règle : ce script
-- n'appelle QUE la base, jamais l'app.
-- =============================================================================

begin;
create temp table out(n serial, cas text, attendu text, resultat text) on commit drop;
grant all on out to authenticated;
grant usage on sequence out_n_seq to authenticated;
create temp table ev(id uuid) on commit drop;
grant all on ev to authenticated;

create or replace function pg_temp.essai(p_cas text, p_attendu text, p_sql text)
returns void language plpgsql as $f$
begin
  execute p_sql;
  insert into out(cas, attendu, resultat) values (p_cas, p_attendu, 'accepté');
exception when others then
  insert into out(cas, attendu, resultat) values (p_cas, p_attendu, 'refusé : ' || sqlerrm);
end $f$;
grant execute on function pg_temp.essai(text, text, text) to authenticated;

-- Le bot 92 est suspendu le temps de l'essai.
update profiles set suspended_at = now(), suspended_reason = 'audit'
 where id = '00000000-0000-4000-8000-000000000092';

set local role authenticated;

-- ── Charles ─────────────────────────────────────────────────────────────────
set local request.jwt.claims = '{"sub":"e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c","role":"authenticated"}';

select pg_temp.essai('chat d''une soirée terminée', 'refusé',
  $q$insert into messages (conversation_id, sender_id, kind, body) values ('2673ff29-a7ce-4899-a917-15c909c3cc2c', 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', 'text', 'x')$q$);
select pg_temp.essai('Drop d''une soirée terminée', 'refusé',
  $q$select public.add_vibe_to_library(gen_random_uuid(), '2673ff29-a7ce-4899-a917-15c909c3cc2c', 'x/p', 'x/s', 'k', 'standard', false, false, false, false, null, null, null, null, true)$q$);
select pg_temp.essai('Drop sans « caméra seulement » (fond uni, import, vieille app)', 'refusé',
  $q$select public.add_vibe_to_library(gen_random_uuid(), '2673ff29-a7ce-4899-a917-15c909c3cc2c', 'x/p', 'x/s', 'k', 'standard', false, false, false, false, null, null, null, null, null)$q$);
select pg_temp.essai('antidater son compte', 'refusé',
  $q$update profiles set created_at = '2020-01-01' where id = 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c'$q$);
select pg_temp.essai('modifier sa bio', 'accepté',
  $q$update profiles set bio = 'audit' where id = 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c'$q$);
select pg_temp.essai('story insérée en direct (sans expiration)', 'refusé',
  $q$insert into stories (id, owner_id, card_type, front_path, expires_at) values (gen_random_uuid(), 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', 'standard', 'x', '2099-01-01')$q$);
select pg_temp.essai('Vibe 1/1 sauvegardable', 'refusé',
  $q$insert into cards (owner_id, card_type, front_path, saveable) values ('e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', 'one_of_one', 'x', true)$q$);
select pg_temp.essai('Oneshot avec durée de lecture', 'refusé',
  $q$insert into cards (owner_id, card_type, front_path, back_path, view_duration_seconds) values ('e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', 'oneshot', 'x', 'y', 5)$q$);
select pg_temp.essai('soirée d''une taille inventée (77 m)', 'refusé',
  $q$select public.create_open_event('Audit', 45.76, 4.83, now() + interval '2 hours', 77, 10)$q$);
select pg_temp.essai('soirée ouverte avec une position à ± 2 km', 'refusé',
  $q$select public.create_open_event('Audit', 45.76, 4.83, now() + interval '2 hours', null, 2000)$q$);
insert into ev select public.create_open_event('Soirée de Charles', 45.76, 4.83, now() + interval '3 hours', null, 10);
select pg_temp.essai('rediriger un salut vers un inconnu', 'refusé',
  $q$do $d$ begin update waves set peer_id = '00000000-0000-4000-8000-000000000093' where user_id = 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c'; if not found then raise exception 'aucune ligne modifiable'; end if; end $d$$q$);

-- ── Le bot 92 : suspendu, et inconnu de la soirée de Charles ────────────────
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-000000000092","role":"authenticated"}';

select pg_temp.essai('suspendu : lever sa propre suspension', 'refusé',
  $q$update profiles set suspended_at = null where id = '00000000-0000-4000-8000-000000000092'$q$);
select pg_temp.essai('suspendu : envoyer une Vibe', 'refusé',
  $q$insert into cards (owner_id, card_type, front_path) values ('00000000-0000-4000-8000-000000000092', 'standard', 'x')$q$);
select pg_temp.essai('un inconnu renomme la soirée ouverte d''un autre', 'refusé',
  format($q$select public.update_event_settings(%L, 'Piratée')$q$, (select id from ev)));
select pg_temp.essai('un inconnu ferme la soirée ouverte d''un autre', 'refusé',
  format($q$select public.close_event(%L)$q$, (select id from ev)));
select pg_temp.essai('un compte ordinaire déclare un établissement', 'refusé',
  $q$select public.create_venue('Faux club', 48.85, 2.35, 60, 'Paris')$q$);

-- Affiche et taille d'une soirée (2026-09-25) — par un inconnu NON suspendu :
-- le second compte de Jay (ccc4b5ae…), ni organisateur, ni membre, ni admin
-- (relevé en base le 2026-09-26). ⚠️ Joués d'abord par le bot 92, ces cas
-- étaient refusés « Ton compte est suspendu » : la garde de suspension
-- répondait AVANT celle de l'organisateur, qui n'était donc jamais testée.
set local request.jwt.claims = '{"sub":"ccc4b5ae-6d7d-4896-a3f0-42b7fe78bc0c","role":"authenticated"}';
select pg_temp.essai('un inconnu change la description d''une soirée', 'refusé',
  $q$select public.set_event_details('120dbec7-08ca-4a38-8d93-c743dc0793df', 'piraté', null)$q$);
select pg_temp.essai('un inconnu dépose une affiche pour la soirée d''un autre', 'refusé',
  $q$insert into storage.objects (bucket_id, name, owner_id) values ('event_posters', 'ccc4b5ae-6d7d-4896-a3f0-42b7fe78bc0c/120dbec7-08ca-4a38-8d93-c743dc0793df/poster_x.jpg', 'ccc4b5ae-6d7d-4896-a3f0-42b7fe78bc0c')$q$);
select pg_temp.essai('un inconnu change la taille d''une soirée', 'refusé',
  format($q$select public.set_event_size(%L, 'plein_air')$q$, (select id from ev)));

-- La carte (2026-09-26) : la position des amis, la demande de position.
-- Le second compte de Jay (ccc4b5ae…) n'est PAS ami avec Charles (e1fcb9b0…).
select pg_temp.essai('un non-ami demande sa position à Charles', 'refusé',
  $q$select public.request_location('e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c')$q$);
select pg_temp.essai('écrire sa position directement (sans la règle de cadence)', 'refusé',
  $q$insert into public.friend_locations (user_id, lat, lon) values ('ccc4b5ae-6d7d-4896-a3f0-42b7fe78bc0c', 1, 1)$q$);
set local request.jwt.claims = '{"sub":"e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c","role":"authenticated"}';
select pg_temp.essai('une fausse demande de position écrite dans le chat', 'refusé',
  -- ⚠️ Sur une conversation qui EXISTE forcément (celle avec Testeur, ami de
  -- Charles) : une insertion qui ne vise aucune ligne passerait pour
  -- « acceptée » sans rien tester (constaté à la première écriture de ce cas).
  $q$insert into public.messages (conversation_id, sender_id, kind, body) values (public.get_or_create_direct_conversation('135ed9b3-03a0-4f28-a2f3-784223a2dcde'), 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c', 'location_request', 'faux')$q$);

select n, cas, attendu, resultat,
       (attendu = 'accepté') = (resultat = 'accepté') as ok
  from out order by n;
rollback;
