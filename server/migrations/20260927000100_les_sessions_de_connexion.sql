-- Les sessions de connexion du serveur Rust (étape 1 — les comptes).
--
-- Une SESSION = un téléphone connecté à un compte. Elle porte une suite de
-- jetons de renouvellement : chacun ne sert qu'une fois, et en donne un
-- nouveau. Un jeton RÉUTILISÉ au-delà de 10 secondes (le délai de grâce de
-- Supabase, `security_refresh_token_reuse_interval`) est le signe d'un vol :
-- toute la session est révoquée.
--
-- Les jetons ne sont jamais stockés en clair : seulement leur empreinte
-- SHA-256. Une fuite de cette table ne permet pas de se connecter.
create table if not exists nv.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  refreshed_at timestamptz,
  revoked_at timestamptz,
  user_agent text
);
create index if not exists sessions_user_idx on nv.sessions (user_id);

create table if not exists nv.refresh_tokens (
  hash text primary key,
  session_id uuid not null references nv.sessions (id) on delete cascade,
  created_at timestamptz not null default now(),
  used_at timestamptz
);
create index if not exists refresh_tokens_session_idx on nv.refresh_tokens (session_id);
