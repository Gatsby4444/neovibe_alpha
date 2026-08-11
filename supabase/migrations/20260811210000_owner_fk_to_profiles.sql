-- CORRECTIF — les clés étrangères des propriétaires pointaient vers
-- `auth.users` au lieu de `public.profiles`.
--
-- La convention de tout le projet est `owner_id references public.profiles(id)` :
-- `cards`, `saved_cards`, `library_vibes` la suivent, et l'ancienne table
-- `stories` la suivait aussi. En reconstruisant les tables aux étapes 1 et 2,
-- j'ai pointé vers `auth.users` — correct sur le papier, mais cela casse la
-- couche client.
--
-- **Pourquoi ça casse** : PostgREST résout les jointures par le NOM de la
-- contrainte. L'app demande `profiles!stories_owner_id_fkey(*)`. La contrainte
-- existait toujours, mais elle ne menait plus à `profiles` — la requête des
-- stories échouait donc **entièrement**, et aucune story ne pouvait s'afficher.
--
-- **Leçon** : une clé étrangère n'est pas seulement une contrainte
-- d'intégrité, c'est aussi le **chemin que le client emprunte pour joindre**.
-- En changer la cible est un changement d'API — invisible en SQL, invisible à
-- `flutter analyze`, et visible seulement à l'exécution. Quand on reconstruit
-- une table, relever les contraintes de l'ancienne avant de composer la
-- nouvelle, au lieu de les réécrire de mémoire.

alter table public.stories
  drop constraint stories_owner_id_fkey,
  add constraint stories_owner_id_fkey
    foreign key (owner_id) references public.profiles (id) on delete cascade;

alter table public.library_items
  drop constraint library_items_owner_id_fkey,
  add constraint library_items_owner_id_fkey
    foreign key (owner_id) references public.profiles (id) on delete cascade;

alter table public.contents
  drop constraint contents_owner_id_fkey,
  add constraint contents_owner_id_fkey
    foreign key (owner_id) references public.profiles (id) on delete cascade;

alter table public.content_views
  drop constraint content_views_viewer_id_fkey,
  add constraint content_views_viewer_id_fkey
    foreign key (viewer_id) references public.profiles (id) on delete cascade;

alter table public.content_grants
  drop constraint content_grants_grantee_id_fkey,
  add constraint content_grants_grantee_id_fkey
    foreign key (grantee_id) references public.profiles (id) on delete cascade;

alter table public.content_grants
  drop constraint content_grants_granted_by_fkey,
  add constraint content_grants_granted_by_fkey
    foreign key (granted_by) references public.profiles (id) on delete cascade;
