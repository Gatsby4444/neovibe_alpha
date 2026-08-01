-- ============================================================
-- Croisements : rétention 24 h (consigne Jay 2026-08-02)
-- ============================================================
-- `public.encounters` mémorise le graphe des croisements physiques, alimenté
-- par `report_encounter` (certificat co-signé, deux signatures Ed25519
-- vérifiées côté serveur). Il n'avait aucune purge : les lignes
-- s'accumulaient indéfiniment.
--
-- Décision de Jay : ces données ne servent qu'à AUTORISER l'accès à du
-- contenu entre comptes non amis (stories ping à venir) — un usage par nature
-- borné dans le temps. On les supprime donc au bout de 24 h.
--
-- ⚠️ Conséquence pour le chantier STREAKS de proximité (RAPPELS, chantier #1) :
-- une paire qui cesse de se croiser perd sa ligne en 24 h. Un streak ne pourra
-- donc PAS se calculer en relisant l'historique de cette table — il lui faudra
-- son propre compteur persistant (dernier jour compté + longueur courante),
-- mis à jour à chaque croisement. Consigné dans RAPPELS.md.
--
-- Le cron `neovibe_purge` est réécrit à l'identique (relevé sur la base le
-- 2026-08-02) avec la seule ligne `encounters` en plus : `cron.schedule`
-- remplace le job de même nom, tout ce qui n'est pas recopié serait perdu.

select cron.schedule(
  'neovibe_purge',
  '*/5 * * * *',
  $$
  delete from public.messages where expires_at < now();
  update public.connection_requests set status = 'expired'
    where status = 'pending' and expires_at < now();
  update public.recommendations set status = 'expired'
    where status in ('requested', 'forwarded') and expires_at < now();
  delete from public.connections
    where status = 'partial' and partial_expires_at < now();
  delete from public.encounters where last_seen_at < now() - interval '24 hours';
  $$
);
