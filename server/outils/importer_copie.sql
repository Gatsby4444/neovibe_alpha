-- Importe la copie des données de dev (docdev/copie_base_dev/, montée en
-- /copie dans le conteneur) dans la base locale de travail.
--
-- Les déclencheurs sont suspendus pendant l'import (`replica`) : on recopie
-- un état, on ne rejoue pas les gestes qui l'ont produit. Les colonnes
-- calculées par la base (GENERATED ALWAYS) ne s'écrivent pas : elles sont
-- recalculées.
set session_replication_role = replica;

do $$
declare
  f text;
  v_schema text;
  v_table text;
  v_cols text;
  v_all text;
  n bigint;
begin
  -- D'abord tout vider d'un coup (les lignes de réglage posées par les
  -- migrations sont remplacées par celles de la copie, identiques).
  select string_agg(format('%I.%I', split_part(x, '.', 1), split_part(x, '.', 2)), ', ')
    into v_all
    from pg_ls_dir('/copie') x
   where x like '%.json'
     and to_regclass(format('%I.%I', split_part(x, '.', 1), split_part(x, '.', 2))) is not null;
  execute 'truncate ' || v_all || ' cascade';

  for f in select pg_ls_dir('/copie') order by 1 loop
    continue when f not like '%.json';
    v_schema := split_part(f, '.', 1);
    v_table := split_part(f, '.', 2);
    continue when to_regclass(format('%I.%I', v_schema, v_table)) is null;
    select string_agg(format('%I', column_name), ', ' order by ordinal_position)
      into v_cols
      from information_schema.columns
     where table_schema = v_schema and table_name = v_table
       and is_generated = 'NEVER';
    execute format(
      'insert into %I.%I (%s) overriding system value '
      'select %s from json_populate_recordset(null::%I.%I, pg_read_file(%L)::json)',
      v_schema, v_table, v_cols, v_cols, v_schema, v_table, '/copie/' || f);
    get diagnostics n = row_count;
    raise notice '% : %', f, n;
  end loop;
end $$;

-- Les compteurs automatiques repartent après la plus grande valeur copiée.
do $$
declare r record;
begin
  for r in
    select s.oid::regclass as seq, d.refobjid::regclass as tbl, a.attname as col
      from pg_class s
      join pg_depend d on d.objid = s.oid and d.deptype in ('a', 'i')
      join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
     where s.relkind = 'S'
  loop
    execute format('select setval(%L, coalesce((select max(%I) from %s), 0) + 1, false)',
                   r.seq, r.col, r.tbl);
  end loop;
end $$;

set session_replication_role = origin;
