-- Après `tool/seed_feed.dart` : les CROISEMENTS et les AJOUTS AU FEED qui
-- font apparaître le contenu des bots dans le feed de Jay (Charles).
--
-- - yanis et sofia (croisés, pas amis) : un croisement ping d'AUJOURD'HUI
--   → leur contenu public arrive par la source « croisés » (3 jours) ;
-- - léa, malik, chloé (amis) : ils AJOUTENT certains de leurs contenus au
--   feed de Jay, sous leur identité (`add_to_feed`) → source « amis »,
--   anonyme jusqu'au like.
--
-- Rejouable : `on conflict do nothing` partout.
-- Usage : python scratchpad/sql.py tool/seed_feed.sql   (PAT de dev)

create temp table jay as select 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c'::uuid as id;
grant select on jay to authenticated;

-- 1. Les croisements d'aujourd'hui (yanis, sofia) — par le PAT, comme le ping
insert into public.ping_pairs (user_low, user_high, first_seen_at, last_seen_at)
select least(j.id, b), greatest(j.id, b), now() - interval '2 hours', now() - interval '1 hour'
from jay j, unnest(array['e4fa3db6-3701-448b-aef3-09accc50ca70', 'a2a1f91a-116f-45a2-8c7b-f6d6fe29e7d5']::uuid[]) as b
on conflict (user_low, user_high) do update set last_seen_at = excluded.last_seen_at;

-- 2. Les ajouts des amis, sous leur identité (les mêmes règles que l'app)
set local role authenticated;

-- léa : sa publication « lac » et son flow
select set_config('request.jwt.claims', json_build_object('sub', '8a13fc20-2ab7-4ebe-806f-fda0930fc790', 'role', 'authenticated')::text, true);
select public.add_to_feed(li.id, array[(select id from jay)])
from public.library_items li
where li.owner_id = '8a13fc20-2ab7-4ebe-806f-fda0930fc790' and li.is_public and li.kind in ('album', 'flow')
  and li.created_at > now() - interval '1 day';

-- malik : son flow seulement
select set_config('request.jwt.claims', json_build_object('sub', '04fee059-168c-4252-9fe9-36a99c7fa3fa', 'role', 'authenticated')::text, true);
select public.add_to_feed(li.id, array[(select id from jay)])
from public.library_items li
where li.owner_id = '04fee059-168c-4252-9fe9-36a99c7fa3fa' and li.kind = 'flow' and li.created_at > now() - interval '1 day';

-- chloé : sa Vibe
select set_config('request.jwt.claims', json_build_object('sub', '8dc0a329-a598-4144-b667-4e7e269040f0', 'role', 'authenticated')::text, true);
select public.add_to_feed(li.id, array[(select id from jay)])
from public.library_items li
where li.owner_id = '8dc0a329-a598-4144-b667-4e7e269040f0' and li.kind = 'card' and li.created_at > now() - interval '1 day';

-- 3. Ce que Jay verra
select set_config('request.jwt.claims', json_build_object('sub', (select id from jay), 'role', 'authenticated')::text, true);
select 'tout' as mode, kind::text, count(*)::text as n from public.feed_items(null, 'all', null, null) group by kind
union all
select 'amis', kind::text, count(*)::text from public.feed_items(null, 'friends', null, null) group by kind
order by 1, 2;
