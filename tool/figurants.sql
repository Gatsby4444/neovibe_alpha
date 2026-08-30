-- ===========================================================================
-- FIGURANTS — 150 faux amis pour Charles, pour tester la constellation en
-- volume. Demandé par Jay le 2026-08-30.
-- ===========================================================================
--
-- 🔴 **CE FICHIER N'EST PAS UNE MIGRATION, ET NE DOIT JAMAIS EN DEVENIR UNE.**
--
-- Il vit dans `tool/` exprès. Rangé dans `supabase/migrations/`, il partirait
-- un jour en production et y créerait 150 comptes fantômes — le genre de chose
-- qu'on découvre trois mois plus tard en se demandant qui sont ces gens.
--
-- ⚠️ À supprimer avant la production, avec les bots de test (`RAPPELS.md` #14).
-- La commande de nettoyage est tout en bas.
--
-- ## Ce qu'il fabrique
--
-- * 150 comptes, tous d'identifiant `00000000-0000-4000-8000-…` — donc
--   reconnaissables d'un coup d'œil et supprimables d'une seule requête ;
-- * tous amis de Charles ;
-- * avec des **historiques de croisement variés**, pour que les trois paliers
--   et les filtres soient réellement éprouvés :
--
--   | Part | Palier obtenu | Série |
--   |---|---|---|
--   | ~1 sur 7 | Inséparable (18 jours d'affilée) | 18 |
--   | ~2 sur 7 | Proche (9 jours espacés de 3) | 9 |
--   | ~1 sur 7 | Ami (3 jours d'affilée) | 3 |
--   | ~3 sur 7 | Ami (jamais croisé) | 0 |
--
-- ⚠️ Aucun `device_keys` : ces comptes ne peuvent pas être reconnus par le
-- BLE, et c'est voulu. Le ping n'a rien à voir avec ce test, et leur en donner
-- un ferait apparaître 150 inconnus dans l'écran Ping.
-- ===========================================================================

-- L'identifiant de Charles, écrit une seule fois.
create temp table cible as select 'e1fcb9b0-619d-40d5-9e6c-25ea35cb8a0c'::uuid as id;

-- ---------------------------------------------------------------------------
-- 1. Les comptes et leurs profils
-- ---------------------------------------------------------------------------
create temp table figurants as
select
  i,
  ('00000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid as id,
  (array[
    'Léa','Hugo','Emma','Lucas','Chloé','Nathan','Manon','Enzo','Camille','Théo',
    'Sarah','Yanis','Inès','Malik','Jade','Rayan','Louise','Adam','Zoé','Noah',
    'Alice','Ethan','Lina','Gabriel','Maëlys','Sacha','Anna','Tom','Nina','Liam',
    'Rose','Axel','Julia','Noé','Clara','Ilyes','Eva','Milo','Lou','Amine'
  -- ⚠️ **Ce couple d'indices doit être INJECTIF.** Une première version prenait
  -- `(i*7) % 40` et `(i*11) % 30` : la paire se répétait tous les 120, et la
  -- base a refusé au 121ᵉ figurant — il existe une contrainte d'unicité sur
  -- `lower(display_name)`. Ici le prénom cycle et le nom change à chaque tour
  -- complet : 40 × 30 = 1200 noms distincts possibles.
  ])[1 + (i % 40)] as prenom,
  (array[
    'Martin','Bernard','Petit','Durand','Leroy','Moreau','Simon','Laurent',
    'Michel','Garcia','David','Bertrand','Roux','Vincent','Fournier','Morel',
    'Girard','André','Mercier','Blanc','Guerin','Boyer','Garnier','Chevalier',
    'Francois','Legrand','Gauthier','Perrin','Robin','Clement'
  ])[1 + ((i / 40) % 30)] as nom
from generate_series(1, 150) i;

insert into auth.users (id, email)
select id, 'figurant' || lpad(i::text, 3, '0') || '@neovibe.test' from figurants
on conflict (id) do nothing;

insert into public.profiles (id, display_name, tag_name, bio, stories_public)
select
  f.id,
  f.prenom || ' ' || f.nom,
  lower(f.prenom) || lpad(f.i::text, 3, '0'),
  (array[
    'Toujours partant pour un skate au parc',
    'Cherche un binôme pour le TP de physique',
    'Café à 8h ou rien',
    'Je ramène la musique',
    'Photo de mon chien sur demande',
    null
  ])[1 + (f.i * 5) % 6],
  f.i % 4 = 0
from figurants f
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. L'amitié avec Charles
-- ---------------------------------------------------------------------------
-- ⚠️ `user_low < user_high` est une contrainte de la table. Les identifiants
-- des figurants commencent par des zéros, celui de Charles par « e » : ils
-- sont donc toujours du côté bas. Ce n'est pas une chance, c'est le choix du
-- préfixe.
insert into public.connections (user_low, user_high, status, origin, established_at)
select f.id, c.id, 'full', 'proximity', now() - (f.i || ' days')::interval
from figurants f, cible c
on conflict (user_low, user_high) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Les historiques de croisement — c'est eux qui font les paliers
-- ---------------------------------------------------------------------------
insert into public.meeting_days (user_low, user_high, day)
select f.id, c.id, current_date - d
from figurants f, cible c, generate_series(0, 29) d
where case
        -- Inséparable : 18 jours d'affilée, donc 18 dans la fenêtre.
        when f.i % 7 = 0 then d < 18
        -- Proche : un jour sur trois. L'écart de 3 jours reste sous la
        -- tolérance de la série (2 jours manqués), donc la série tient.
        when f.i % 7 in (1, 2) then d % 3 = 0 and d < 27
        -- Ami avec une petite série en cours.
        when f.i % 7 = 3 then d < 3
        else false
      end
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 4. On recalcule, et on montre le résultat
-- ---------------------------------------------------------------------------
select private.refresh_all_tiers();

select c.tier::text as palier,
       count(*) as combien,
       min(c.tier_days) as jours_min,
       max(c.tier_days) as jours_max
from public.connections c, cible ci
where c.user_high = ci.id
group by c.tier
order by 1;

-- ===========================================================================
-- NETTOYAGE — à lancer avant la production, ou dès que le test est fini.
-- ===========================================================================
--
--   delete from auth.users
--    where id::text like '00000000-0000-4000-8000-%';
--
-- ⚠️ **Une seule ligne suffit, et c'est délibéré.** `profiles` casse en
-- cascade depuis `auth.users`, et `connections` et `meeting_days` cassent en
-- cascade depuis `profiles`. Supprimer les profils d'abord laisserait 150
-- comptes orphelins dans `auth.users`, invisibles depuis l'app — le genre de
-- reste mort qui devient la panne de demain.
-- ===========================================================================

-- ===========================================================================
-- RÉDUCTION À 40 — 2026-08-30
-- ===========================================================================
--
-- Consigne de Jay : *« supprime les amis que tu as créé hier […] mais pas tous,
-- garde en 40 répartis dans les différentes catégories »*.
--
-- ## Ce que « catégories » veut dire ici, et pourquoi DEUX dimensions
--
-- Les figurants n'ont pas de `device_keys` : ils n'apparaissent donc jamais
-- dans le Ping, seulement dans la liste d'amis et la constellation. La
-- catégorie qui les distingue est le **palier**. Mais la mention spéciale est,
-- elle aussi, une catégorie d'affichage — et elle est arrivée après ce script.
-- Les deux sont donc tenues ensemble.
--
-- **Les paliers, gardés EN PROPORTION** (ce que Jay regarde depuis hier reste
-- le même, en plus petit) :
--
--   | Palier | Avant | Après |
--   |---|---|---|
--   | Inséparable (18 j) | 21 | 6 |
--   | Proche (9 j) | 44 | 12 |
--   | Ami, série de 3 | 22 | 6 |
--   | Ami, jamais croisé | 63 | 16 |
--
-- **Les mentions, réparties À ÉGALITÉ dans chaque palier** (14 privées,
-- 13 publiques, 13 sans) : à six exemplaires par palier, une sélection au fil
-- des identifiants aurait pu n'en garder qu'un seul type — la mention cycle
-- avec une période de 6 et le palier avec une période de 7.
--
-- ⚠️ **Relevé APRÈS coup, pas déduit du script** : 40 profils, 40 comptes
-- `auth.users`, 40 connexions, 234 `meeting_days`, zéro orphelin.
--
-- ⚠️ **Une conversation est restée à un seul membre** — Charles avait ouvert un
-- chat de test avec un figurant supprimé. Elle a été retirée dans la foulée :
-- c'est le sens sortant de la règle 8 de `CLAUDE.md`, ce que le nœud supprimé
-- APPELAIT devient orphelin à son tour. `content_grants` et `library_vibes`
-- vérifiés à zéro avant de couper (ce sont les deux seuls à ne pas casser en
-- cascade proprement : l'un est en `SET NULL`).
--
-- La requête telle qu'elle a été jouée :
--
-- with fig as (
--   select p.id,
--          c.tier::text as palier,
--          c.tier_days,
--          case when p.special_mention is null then 'sans'
--               when p.special_mention_public then 'publique'
--               else 'privee' end as mention
--   from public.profiles p
--   join public.connections c on c.user_low = p.id
--   where p.id::text like '00000000-0000-4000-8000-%'
-- ),
-- -- On numerote D'ABORD a l'interieur de chaque (palier, etat de mention) :
-- -- c'est ce rang qui, une fois trie en premier, fait alterner les trois etats
-- -- de mention au lieu de prendre les 6 premiers d'un seul bloc.
-- cycle as (
--   select f.*,
--          row_number() over (partition by palier, tier_days, mention order by id) as rm
--   from fig f
-- ),
-- range as (
--   select c.*,
--          row_number() over (partition by palier, tier_days order by rm, mention, id) as rang
--   from cycle c
-- ),
-- quota as (
--   select * from (values
--     ('inner', 18, 6),
--     ('close',  9, 12),
--     ('friend', 3, 6),
--     ('friend', 0, 16)
--   ) as q(palier, tier_days, combien)
-- ),
-- garder as (
--   select r.id from range r join quota q
--     on q.palier = r.palier and q.tier_days = r.tier_days
--   where r.rang <= q.combien
-- )
-- -- ⚠️ Le filtre de prefixe est repete ICI, et pas seulement dans les CTE : c'est
-- -- lui, et lui seul, qui borne la portee de la suppression aux figurants.
-- -- La cascade part de auth.users : profiles, puis connections et meeting_days.
-- delete from auth.users u
-- where u.id::text like '00000000-0000-4000-8000-%'
--   and u.id not in (select id from garder);
-- ===========================================================================
