-- Les demandes de position arrivent EN DIRECT chez l'ami (2026-09-26) : le
-- temps réel de Supabase ne diffuse que les tables de sa publication. Le
-- droit de lire reste celui de la table (`location_requests_parties`) :
-- seuls le demandeur et l'ami demandé reçoivent la ligne.
alter publication supabase_realtime add table public.location_requests;
