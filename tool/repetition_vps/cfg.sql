-- Les réglages posés par les migrations (lignes de configuration), comparés tels quels.
select 'signup_rules '||row_to_json(t)::text from private.signup_rules t
union all select 'crossing_windows '||row_to_json(t)::text from (select * from public.crossing_windows order by 1) t
union all select 'event_rules '||row_to_json(t)::text from public.event_rules t
union all select 'feed_rules '||row_to_json(t)::text from public.feed_rules t
union all select 'map_rules '||row_to_json(t)::text from public.map_rules t
order by 1;
