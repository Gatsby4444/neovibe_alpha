-- Refonte des types de Cards — demande de Jay, 2026-08-10.
--
-- 1. La Mono disparaît en tant que TYPE : une Card classique peut désormais
--    n'avoir qu'une face (bouton « Passer » à la prise du verso). Le nombre de
--    faces devient une propriété de la Card, plus un type à part.
-- 2. La Hot est supprimée définitivement.
-- 3. Le One of One n'est plus choisi à la capture : il est appliqué
--    automatiquement à l'envoi (un destinataire, aucune publication). Le type
--    reste donc parfaitement valide en base — seul son chemin de création
--    change, côté client.
--
-- Les valeurs 'mono' et 'hot' NE SONT PAS retirées de l'énumération
-- `public.card_type` : PostgreSQL ne sait pas supprimer une valeur d'enum, et
-- la recréer imposerait de réécrire toutes les colonnes, fonctions et
-- politiques qui la référencent. Elles deviennent simplement des valeurs
-- mortes, que plus aucun client ne produit. Les branches serveur qui les
-- testent encore (destruction des Hot, cron de purge) restent en place et ne
-- se déclenchent plus jamais faute de ligne correspondante.

-- --- Contrainte de faces -----------------------------------------------
-- Avant : le verso n'était optionnel que pour une Mono.
-- Après : il l'est pour une Card classique et une One of One (qui hérite du
-- nombre de faces de la Card capturée). Le Oneshot et le BeReal gardent leurs
-- deux faces obligatoires — c'est la définition même de ces formats.
-- 'mono' reste tolérée dans la contrainte : un APK antérieur encore installé
-- sur un appareil de test continuerait sinon d'échouer à l'insertion.
alter table public.cards drop constraint if exists cards_back_required;

alter table public.cards
  add constraint cards_back_required
  check (
    back_path is not null
    or card_type in ('standard', 'one_of_one', 'mono')
  );

-- --- Conversion des lignes existantes ----------------------------------
-- Les Mono deviennent des Cards classiques à une face : c'est exactement ce
-- que le nouveau format sait exprimer, aucune donnée n'est perdue.
update public.cards set card_type = 'standard' where card_type = 'mono';

-- Les Hot deviennent des Cards classiques. Leur mécanique (vue unique, 10 s)
-- est portée par `max_views` / `view_duration_seconds`, qui restent tels
-- quels : la Card garde ses limites, elle perd seulement sa destruction
-- automatique et son style rouge.
update public.cards set card_type = 'standard' where card_type = 'hot';
