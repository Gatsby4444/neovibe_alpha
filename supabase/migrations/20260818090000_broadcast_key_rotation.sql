-- Rotation de la clé de diffusion (décision de Jay, 2026-08-18 : 7 jours).
--
-- ## Le défaut corrigé
--
-- `broadcast_key` était écrite une fois à l'installation et **jamais**
-- régénérée. Or c'est le secret qui engendre l'ID rotatif diffusé en BLE : un
-- ami qui l'a téléchargée peut nous reconnaître hors ligne, en silence, pour
-- toujours. La politique `device_keys_friends` l'empêche de la RELIRE après une
-- rupture d'amitié — elle ne reprend pas ce qu'il a déjà copié sur son
-- appareil.
--
-- Conséquence, pour une app dont la thèse est le cercle restreint : **retirer
-- un ami ne retirait rien**. Il fallait que la clé tourne.
--
-- ## Ce que cette migration ajoute
--
-- `broadcast_key_prev` : la clé d'avant la dernière rotation. Sans elle, chaque
-- rotation rendrait son auteur invisible à tous ses amis jusqu'à leur prochaine
-- synchronisation, puisqu'ils indexeraient une clé qui n'est plus diffusée. Les
-- deux sont publiées, l'index d'en face couvre les deux, et la rotation ne se
-- voit pas.
--
-- ⚠️ Une **révocation** (un ami retiré) laisse volontairement cette colonne à
-- NULL : c'est précisément ce qu'il ne faut pas conserver. Le client s'en charge
-- (`ProximitySync._revokeBroadcast`).
--
-- `rotated_at` : la date de la clé courante. Elle sert au diagnostic et
-- permettra, si besoin, de vérifier côté serveur qu'un parc tourne bien.

alter table public.device_keys
  add column if not exists broadcast_key_prev text,
  add column if not exists rotated_at timestamptz not null default now();

comment on column public.device_keys.broadcast_key is
  'Clé de diffusion courante (base64). Engendre l''ID rotatif BLE. Tourne tous les 7 jours.';
comment on column public.device_keys.broadcast_key_prev is
  'Clé précédente, pour qu''une rotation n''aveugle pas les amis pas encore synchronisés. NULL après une révocation.';
comment on column public.device_keys.rotated_at is
  'Date de la clé courante.';
