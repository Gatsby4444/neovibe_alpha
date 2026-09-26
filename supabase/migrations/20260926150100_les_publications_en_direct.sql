-- « [Ami] a publié » : les publications passent enfin dans le direct.
--
-- Relevé le 2026-09-26 (inventaire du plan du serveur Rust) : l'écouteur
-- FOMO de l'app (`lib/features/notifications/fomo_listener.dart`) s'abonne
-- aux insertions dans `library_items` pour afficher « [Ami] a publié »,
-- mais la table n'a JAMAIS été ajoutée à la publication `supabase_realtime`
-- — et elle a été supprimée puis recréée le 2026-08-11
-- (`20260811190000_publications_autonomous.sql`), ce qui l'en aurait retirée
-- de toute façon. Le direct ne diffuse que les tables de cette publication :
-- l'abonnement ne recevait donc rien, sans aucune erreur.
--
-- La lecture reste gardée : le direct n'envoie une ligne qu'à ceux que la
-- politique `library_select_audience` autorise à la voir.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime'
                    and schemaname = 'public' and tablename = 'library_items') then
    alter publication supabase_realtime add table public.library_items;
  end if;
end $$;
