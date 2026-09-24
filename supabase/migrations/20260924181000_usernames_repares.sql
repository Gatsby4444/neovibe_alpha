-- =============================================================================
-- LES USERNAMES RÉPARÉS — 2026-09-24
-- =============================================================================
--
-- La migration précédente (`20260924180000_…`) a réduit TOUS les usernames à
-- trois lettres : `rpad(v, 3, '0')`, écrit pour compléter les noms trop
-- courts, coupe aussi les noms trop longs (« Charles » → « cha »). Constaté en
-- relisant la base juste après l'avoir appliquée.
--
-- Les noms d'origine se reconstruisent EXACTEMENT, sans deviner :
-- - les 8 comptes réels et bots, par leur adresse mail (noms relevés en base
--   le 2026-09-24, avant la migration) ;
-- - les figurants, par la formule de `tool/figurants.sql` (prénom et nom
--   calculés à partir du numéro contenu dans leur identifiant).
--
-- Puis la même conversion, corrigée, que la migration précédente.
-- =============================================================================

create temp table originaux (id uuid primary key, nom text not null);

insert into originaux (id, nom)
select u.id, v.nom
from auth.users u
join (values
  ('charles.btto001@gmail.com', 'Charles'),
  ('chloe.bot@neovibe.dev', 'Chloe'),
  ('lea.bot@neovibe.dev', 'Lea'),
  ('malik.bot@neovibe.dev', 'Malik'),
  ('mimidomp50@gmail.com', 'mimi'),
  ('sofia.bot@neovibe.dev', 'Sofia'),
  ('test@neovibe.dev', 'Testeur'),
  ('yanis.bot@neovibe.dev', 'Yanis')
) as v(email, nom) on v.email = u.email;

insert into originaux (id, nom)
select f.id, f.prenom || ' ' || f.nom
from (
  select
    ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as id,
    (array[
      'Léa','Hugo','Emma','Lucas','Chloé','Nathan','Manon','Enzo','Camille','Théo',
      'Sarah','Yanis','Inès','Malik','Jade','Rayan','Louise','Adam','Zoé','Noah',
      'Alice','Ethan','Lina','Gabriel','Maëlys','Sacha','Anna','Tom','Nina','Liam',
      'Rose','Axel','Julia','Noé','Clara','Ilyes','Eva','Milo','Lou','Amine'
    ])[1 + (i % 40)] as prenom,
    (array[
      'Martin','Bernard','Petit','Durand','Leroy','Moreau','Simon','Laurent',
      'Michel','Garcia','David','Bertrand','Roux','Vincent','Fournier','Morel',
      'Girard','André','Mercier','Blanc','Guerin','Boyer','Garnier','Chevalier',
      'Francois','Legrand','Gauthier','Perrin','Robin','Clement'
    ])[1 + ((i / 40) % 30)] as nom
  from generate_series(1, 150) i
) f
join public.profiles p on p.id = f.id;

-- Chaque profil doit avoir retrouvé son nom : sinon on n'écrit rien.
do $$
begin
  if exists (select 1 from public.profiles p
             where not exists (select 1 from originaux o where o.id = p.id)) then
    raise exception 'Un profil sans nom d''origine : réparation abandonnée';
  end if;
end $$;

-- Un nom provisoire d'abord : libère tous les noms à trois lettres, pour que
-- l'ordre des renommages ne puisse pas créer de collision.
update public.profiles
   set display_name = 'tmp.' || right(replace(id::text, '-', ''), 16);

do $$
declare
  r record;
  v_base text;
  v_try text;
  v_n integer;
begin
  for r in select id, nom from originaux order by id loop
    v_base := lower(translate(
      r.nom,
      'ÀÂÄÁÃÉÈÊËÎÏÍÔÖÓÕÙÛÜÚÇÑàâäáãéèêëîïíôöóõùûüúçñ',
      'AAAAAEEEEIIIOOOOUUUUCNaaaaaeeeeiiioooouuuucn'
    ));
    v_base := regexp_replace(v_base, '[[:space:]]+', '.', 'g');
    v_base := regexp_replace(v_base, '[^a-z0-9._]', '', 'g');
    v_base := regexp_replace(v_base, '[.]{2,}', '.', 'g');
    v_base := btrim(v_base, '.');
    if v_base = '' then v_base := 'neovibe'; end if;
    if length(v_base) < 3 then v_base := rpad(v_base, 3, '0'); end if;
    v_base := left(v_base, 20);
    v_try := v_base;
    v_n := 1;
    while exists (
      select 1 from public.profiles
      where lower(display_name) = v_try and id <> r.id
    ) loop
      v_n := v_n + 1;
      v_try := left(v_base, 20 - length(v_n::text)) || v_n::text;
    end loop;
    update public.profiles set display_name = v_try where id = r.id;
  end loop;
end $$;
