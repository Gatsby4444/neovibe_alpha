-- Le rôle du serveur NeoVibe : `nv_server`.
--
-- Le serveur lit et écrit des DONNÉES ; il ne fait rien d'autre. Il ne se
-- connecte donc pas en `postgres` (superutilisateur : une seule injection
-- SQL lui donnerait la machine — `COPY … TO PROGRAM` —, les sauvegardes et
-- les rôles ; relevé par le gardien-securite le 2026-09-29). Les tables
-- restent à `postgres`, qui seul passe les migrations.
--
-- Ce que `nv_server` peut faire, énoncé positivement :
--   · se connecter à cette base ;
--   · lire, ajouter, modifier, effacer des lignes de toutes les tables des
--     schémas de l'app, utiliser leurs compteurs, appeler leurs fonctions ;
--   · passer outre les anciennes règles d'accès (RLS) : elles s'appuient sur
--     `auth.uid()`, que le serveur Rust ne renseigne pas — ses règles vivent
--     dans son gardien (nv-app). Elles tomberont avec l'ancien gardien
--     (étape 12, docs/serveur-rust.md).
-- Rien d'autre : ni superutilisateur, ni création de base ou de rôle, ni
-- lecture de fichiers du serveur, ni changement de structure.
--
-- Le rôle est créé ici SANS droit de connexion : c'est la machine qui le
-- lui donne, avec son mot de passe (server/outils/vps/installer.sh).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'nv_server') then
    create role nv_server nologin;
  end if;
end $$;
alter role nv_server nosuperuser nocreatedb nocreaterole noreplication bypassrls;

do $$
declare s text;
begin
  execute format('grant connect on database %I to nv_server', current_database());
  for s in
    select nspname from pg_namespace
     where nspname not like 'pg\_%' and nspname <> 'information_schema'
  loop
    execute format('grant usage on schema %I to nv_server', s);
    execute format('grant select, insert, update, delete on all tables in schema %I to nv_server', s);
    execute format('grant usage, select on all sequences in schema %I to nv_server', s);
    execute format('grant execute on all functions in schema %I to nv_server', s);
    -- Ce que les migrations futures créeront (en `postgres`) DANS CES
    -- SCHÉMAS suit la même règle. ⚠️ Un schéma créé plus tard n'est pas
    -- couvert : sa migration rejoue ce bloc pour lui (sinon « permission
    -- denied » au premier appel, pas à la construction).
    execute format('alter default privileges for role postgres in schema %I '
                   'grant select, insert, update, delete on tables to nv_server', s);
    execute format('alter default privileges for role postgres in schema %I '
                   'grant usage, select on sequences to nv_server', s);
    execute format('alter default privileges for role postgres in schema %I '
                   'grant execute on functions to nv_server', s);
  end loop;
end $$;
