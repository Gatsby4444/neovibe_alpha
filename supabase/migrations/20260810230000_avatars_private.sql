-- Les avatars ne sont plus publics — decision de Jay, 2026-08-10 :
-- « controle complet de l'ecosysteme ».
--
-- Jusqu'ici `avatars` etait le SEUL bucket public : n'importe qui connaissant
-- l'URL lisait n'importe quelle photo de profil, SANS COMPTE. C'est l'usage
-- courant pour des avatars, mais il contredit frontalement la these du produit —
-- une app dont l'entree se merite par la presence physique ne peut pas laisser
-- le visage de ses membres accessible a l'internet entier.
--
-- Nouveau perimetre : ceux qui peuvent deja voir le PROFIL. `can_view_profile`
-- couvre exactement le bon cercle — connexion, croisement physique,
-- conversation partagee, demande en cours, recommandation.
--
-- Cote app, `profiles.avatar_url` stocke desormais le CHEMIN et non une URL :
-- il n'existe plus d'URL publique. L'affichage passe par `avatarUrlProvider`
-- (core/widgets/avatar.dart), qui demande une URL signee d'1 h.

update storage.buckets set public = false where id = 'avatars';

drop policy if exists avatars_read_public on storage.objects;
drop policy if exists avatars_read_via_profile on storage.objects;

create policy avatars_read_via_profile on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    -- Le chemin est `<uid>/avatar.jpg` : le premier segment identifie le
    -- proprietaire, sans avoir a joindre `profiles`.
    and private.can_view_profile(
      (select auth.uid()),
      ((storage.foldername(name))[1])::uuid
    )
  );

drop policy if exists avatars_write_own on storage.objects;
create policy avatars_write_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
