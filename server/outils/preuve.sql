-- L'instrument de la preuve par comparaison (docs/serveur-rust.md §4) :
-- le JOURNAL DES CHANGEMENTS. Installé seulement dans la base locale de
-- travail, jamais en production.
--
-- Chaque ligne insérée, modifiée ou supprimée — y compris par une cascade
-- ou un déclencheur — est notée dans `nv_proof.changes`, mais seulement
-- dans une transaction qui l'a demandé (`set local nv_proof.capture = 'on'`).
-- La preuve joue une situation par l'ancien gardien puis par le nouveau,
-- chacun dans sa transaction annulée ensuite, et compare les deux journaux.
create schema if not exists nv_proof;
grant usage on schema nv_proof to anon, authenticated, service_role;

create table if not exists nv_proof.changes (
  n bigserial primary key,
  tbl text not null,
  op text not null,
  old jsonb,
  new jsonb
);

create or replace function nv_proof.capture() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('nv_proof.capture', true), '') <> 'on' then
    return null;
  end if;
  insert into nv_proof.changes (tbl, op, old, new)
  values (tg_table_schema || '.' || tg_table_name, tg_op,
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end);
  return null;
end $$;

do $$
declare r record;
begin
  for r in
    select schemaname, tablename from pg_tables
     where schemaname in ('public', 'private', 'nv')
        or (schemaname = 'auth' and tablename = 'users')
        or (schemaname = 'storage' and tablename = 'objects')
  loop
    execute format('drop trigger if exists zz_nv_proof on %I.%I', r.schemaname, r.tablename);
    execute format('create trigger zz_nv_proof after insert or update or delete on %I.%I '
                   'for each row execute function nv_proof.capture()', r.schemaname, r.tablename);
  end loop;
end $$;
