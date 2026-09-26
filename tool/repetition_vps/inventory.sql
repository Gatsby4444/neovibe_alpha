-- L'inventaire comparable d'une base NeoVibe : une ligne par objet, triée.
-- Rejoué sur la base de dev ET sur la base reconstruite par les migrations
-- (tool/repetition_vps/repeter.py).
with s(n) as (values ('public'), ('private'))
select l from (
  select 'table ' || n.nspname || '.' || c.relname || ' kind=' || c.relkind::text
         || ' rls=' || c.relrowsecurity || ' force=' || c.relforcerowsecurity as l
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select n from s) and c.relkind in ('r','v','m','p')
  union all
  select 'col ' || n.nspname || '.' || c.relname || '.' || a.attname || ' ' || format_type(a.atttypid, a.atttypmod)
         || ' notnull=' || a.attnotnull || ' def=' || coalesce(pg_get_expr(d.adbin, d.adrelid), '')
    from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
   where n.nspname in (select n from s) and c.relkind in ('r','v','m','p') and a.attnum > 0 and not a.attisdropped
  union all
  select 'con ' || n.nspname || '.' || c.relname || ' ' || co.conname || ' ' || pg_get_constraintdef(co.oid)
    from pg_constraint co join pg_class c on c.oid = co.conrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select n from s)
  union all
  select 'idx ' || n.nspname || ' ' || pg_get_indexdef(i.indexrelid)
    from pg_index i join pg_class c on c.oid = i.indexrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select n from s)
  union all
  select 'fn ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ') secdef=' || p.prosecdef
         || ' md5=' || md5(pg_get_functiondef(p.oid))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in (select n from s) and p.prokind in ('f','p')
  union all
  select 'fnexec ' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ') anon='
         || has_function_privilege('anon', p.oid, 'execute') || ' auth=' || has_function_privilege('authenticated', p.oid, 'execute')
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in (select n from s) and p.prokind in ('f','p')
  union all
  select 'pol ' || schemaname || '.' || tablename || ' ' || policyname || ' ' || cmd || ' ' || permissive || ' ' || roles::text
         || ' using=' || coalesce(qual, '') || ' check=' || coalesce(with_check, '')
    from pg_policies where schemaname in ('public', 'private', 'storage')
  union all
  select 'trg ' || pg_get_triggerdef(t.oid)
    from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
   where not t.tgisinternal and (n.nspname in (select n from s) or (n.nspname = 'auth' and c.relname = 'users'))
  union all
  select 'view ' || n.nspname || '.' || c.relname || ' md5=' || md5(pg_get_viewdef(c.oid))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname in (select n from s) and c.relkind in ('v','m')
  union all
  select 'enum ' || t.typname || ' ' || string_agg(e.enumlabel, ',' order by e.enumsortorder)
    from pg_type t join pg_enum e on e.enumtypid = t.oid join pg_namespace n on n.oid = t.typnamespace
   where n.nspname in (select n from s) group by t.typname
  union all
  select 'grant ' || table_schema || '.' || table_name || ' ' || grantee || ' ' || privilege_type
    from information_schema.role_table_grants
   where table_schema in (select n from s) and grantee in ('anon', 'authenticated', 'service_role')
  union all
  select 'colgrant ' || table_schema || '.' || table_name || '.' || column_name || ' ' || grantee || ' ' || privilege_type
    from information_schema.column_privileges
   where table_schema in (select n from s) and grantee in ('anon', 'authenticated')
     and not exists (select 1 from information_schema.role_table_grants g
                      where g.table_schema = column_privileges.table_schema and g.table_name = column_privileges.table_name
                        and g.grantee = column_privileges.grantee and g.privilege_type = column_privileges.privilege_type)
  union all
  select 'nsp ' || nspname || ' anon=' || has_schema_privilege('anon', oid, 'usage') || ' auth=' || has_schema_privilege('authenticated', oid, 'usage')
    from pg_namespace where nspname in (select n from s)
  union all
  select 'cron ' || jobname || ' @ ' || schedule || ' md5=' || md5(regexp_replace(command, '\s+', ' ', 'g')) from cron.job
  union all
  select 'realtime ' || schemaname || '.' || tablename from pg_publication_tables where pubname = 'supabase_realtime'
  union all
  select 'bucket ' || id || ' public=' || public || ' limit=' || coalesce(file_size_limit::text, '-')
         || ' mime=' || coalesce(allowed_mime_types::text, '-') from storage.buckets
) x order by l;
