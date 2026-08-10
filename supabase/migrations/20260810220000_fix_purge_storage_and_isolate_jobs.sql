-- Correction d'une REGRESSION introduite le 2026-08-10 par la migration
-- 20260810190100.
--
-- ─── Le defaut ─────────────────────────────────────────────────────────────
-- `purge_expired_library_vibes()` supprimait directement dans
-- `storage.objects`. Supabase l'INTERDIT par un trigger
-- (`storage.protect_delete`) : il faut passer par l'API Storage. La fonction
-- levait donc a CHAQUE appel.
--
-- ─── Ce qui l'a rendu grave ────────────────────────────────────────────────
-- Je l'avais greffee sur la tache `neovibe_purge` existante. pg_cron execute la
-- commande d'un job en UNE SEULE TRANSACTION : l'echec de la derniere
-- instruction annulait donc TOUTES les precedentes. Pendant plusieurs heures,
-- ni les messages expires, ni les stories, ni les croisements, ni les demandes
-- de connexion n'ont ete purges — sans aucun signe dans l'app.
--
-- Constate dans `cron.job_run_details` : status 'failed' toutes les 5 minutes.
-- Decouvert par accident, en heurtant la meme interdiction lors d'une purge
-- manuelle. Sans cela, la panne pouvait durer des semaines.
--
-- ─── Double correction ─────────────────────────────────────────────────────
-- 1. La fonction ne touche plus au stockage. Supprimer la LIGNE suffit a rendre
--    les fichiers inaccessibles : les politiques de lecture du coffre joignent
--    `library_vibes`, sans ligne aucune lecture n'est autorisable. Les octets
--    restent orphelins — balayage par l'API Storage a prevoir (RAPPELS.md).
-- 2. La purge des bibliotheques prend son PROPRE job. Un echec futur, quelle
--    qu'en soit la cause, ne pourra plus emporter les autres purges.
--
-- ─── Regles retenues ───────────────────────────────────────────────────────
-- - Verifier `cron.job_run_details` apres TOUTE modification d'un job : une
--   tache planifiee qui echoue est parfaitement silencieuse.
-- - Ne JAMAIS greffer une nouveaute sur un job partage : un job = une
--   transaction, la nouveaute qui echoue emporte tout le reste.

create or replace function public.purge_expired_library_vibes()
returns void
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  delete from library_vibes
  where ephemeral and now() > reveal_at + interval '24 hours';
end;
$fn$;

revoke execute on function public.purge_expired_library_vibes()
  from public, anon, authenticated;

-- Le job d'origine, RESTAURE tel qu'il etait avant la regression.
select cron.schedule(
  'neovibe_purge',
  '*/5 * * * *',
  $job$
  delete from public.messages where expires_at < now();
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  delete from public.connections
    where status = 'partial' and partial_expires_at < now();
  delete from public.encounters where last_seen_at < now() - interval '24 hours';
  delete from public.stories where expires_at < now();
  $job$
);

-- La purge des bibliotheques, ISOLEE.
select cron.schedule(
  'neovibe_purge_library',
  '*/5 * * * *',
  $job$ select public.purge_expired_library_vibes(); $job$
);
