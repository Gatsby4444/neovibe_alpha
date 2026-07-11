-- NeoVibe V1 — schéma initial
-- Toutes les entités du produit : profils, connexions, demandes BLE,
-- recommandations A→B→C, conversations/messages éphémères, Cards, bibliothèque, Waves.

-- Énumérations (extensibles — jamais de booléens pour les types produit)
create type public.connection_status as enum ('partial', 'full');
create type public.connection_origin as enum ('ble', 'recommendation');
create type public.request_status as enum ('pending', 'accepted', 'declined', 'expired');
create type public.recommendation_status as enum ('requested', 'forwarded', 'accepted', 'declined', 'expired');
create type public.conversation_type as enum ('direct', 'group', 'proximity');
create type public.message_kind as enum ('text', 'image', 'video', 'card');
create type public.card_type as enum ('standard', 'oneshot', 'one_of_one', 'hot', 'bereal');
create type public.library_visibility as enum ('connections', 'restricted');

-- Profils (1 ligne par utilisateur auth)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 50),
  avatar_url text,
  library_visibility public.library_visibility not null default 'connections',
  realtime_waves boolean not null default false, -- Waves temps réel : opt-in, jamais par défaut
  ble_token uuid not null unique default gen_random_uuid(), -- identifiant diffusé en BLE (jamais l'id du compte)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Connexions : paire ordonnée (user_low < user_high), partielle (3 jours) ou complète
create table public.connections (
  id uuid primary key default gen_random_uuid(),
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  status public.connection_status not null,
  origin public.connection_origin not null,
  partial_expires_at timestamptz,
  confirmed_low boolean not null default false,
  confirmed_high boolean not null default false,
  created_at timestamptz not null default now(),
  established_at timestamptz,
  constraint connections_ordered check (user_low < user_high),
  constraint connections_unique unique (user_low, user_high)
);

-- Demandes de connexion BLE : expirent si la proximité cesse (expires_at rafraîchi
-- par le client émetteur tant que le pair est détecté)
create table public.connection_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  status public.request_status not null default 'pending',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '90 seconds',
  constraint request_distinct_users check (sender_id <> receiver_id)
);
create index connection_requests_receiver_idx on public.connection_requests (receiver_id, status);
create index connection_requests_sender_idx on public.connection_requests (sender_id, status);

-- Recommandations A→B→C.
-- B (requester) décrit C en texte libre (target_hint) ; A (intermediary) choisit C
-- parmi SES connexions au moment de transmettre → target_id renseigné à ce moment-là.
-- (B ne voit jamais la liste des connexions de A.)
create table public.recommendations (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  intermediary_id uuid not null references public.profiles(id) on delete cascade,
  target_id uuid references public.profiles(id) on delete cascade,
  target_hint text not null check (char_length(target_hint) between 1 and 200),
  status public.recommendation_status not null default 'requested',
  created_at timestamptz not null default now(),
  forwarded_at timestamptz,
  resolved_at timestamptz,
  expires_at timestamptz not null default now() + interval '14 days',
  constraint reco_requester_not_intermediary check (requester_id <> intermediary_id),
  constraint reco_target_distinct check (target_id is null or (target_id <> requester_id and target_id <> intermediary_id))
);
create index recommendations_intermediary_idx on public.recommendations (intermediary_id, status);
create index recommendations_monthly_cap_idx on public.recommendations (intermediary_id, forwarded_at);

-- Conversations : directe (2 connectés), groupe, ou proximité (2 inconnus en portée BLE).
-- pair_key garantit l'unicité des conversations 1-à-1 ('direct:a:b' / 'prox:a:b').
create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  conversation_type public.conversation_type not null,
  title text check (title is null or char_length(title) <= 80),
  pair_key text unique,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index conversation_members_user_idx on public.conversation_members (user_id);

-- Cards : format signature recto/verso. Le type est fixé à la création.
create table public.cards (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  card_type public.card_type not null default 'standard',
  front_path text not null,
  back_path text not null,
  view_duration_seconds integer check (view_duration_seconds between 1 and 10), -- oneshot uniquement
  created_at timestamptz not null default now()
);

-- Messages éphémères (TTL 24h purgé par cron ; RLS filtre aussi les expirés)
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  kind public.message_kind not null default 'text',
  body text check (body is null or char_length(body) <= 4000),
  media_path text,
  card_id uuid references public.cards(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index messages_conversation_idx on public.messages (conversation_id, created_at);
create index messages_expiry_idx on public.messages (expires_at);

-- Accusés de lecture (direct + groupe)
create table public.message_reads (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

-- Livraison d'une Card à un destinataire (porte l'état de visionnage/destruction)
create table public.card_deliveries (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.cards(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  message_id uuid references public.messages(id) on delete set null,
  delivered_at timestamptz not null default now(),
  first_viewed_at timestamptz,
  destroyed_at timestamptz, -- oneshot : détruite après visionnage
  hot_boosted boolean not null default false, -- Hot : mise en avant privée chez le destinataire
  unique (card_id, recipient_id)
);
create index card_deliveries_recipient_idx on public.card_deliveries (recipient_id);

-- Bibliothèque personnelle : contenu NON éphémère, volontairement conservé
create table public.library_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('photo', 'video', 'card')),
  card_id uuid references public.cards(id) on delete cascade,
  media_path text,
  caption text check (caption is null or char_length(caption) <= 500),
  created_at timestamptz not null default now(),
  constraint library_item_content check (
    (kind = 'card' and card_id is not null) or (kind <> 'card' and media_path is not null)
  )
);
create index library_items_owner_idx on public.library_items (owner_id, created_at desc);

-- Liste d'accès à la bibliothèque (utilisée quand library_visibility = 'restricted')
create table public.library_access (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  grantee_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, grantee_id)
);

-- Waves ("le presque") : croisement physique manqué entre connexions.
-- Jamais de position, uniquement le fait du croisement + horodatage approximatif.
create table public.waves (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  peer_id uuid not null references public.profiles(id) on delete cascade,
  detected_at timestamptz not null default now(),
  notify_after timestamptz not null default now() + interval '45 minutes',
  notified boolean not null default false,
  constraint wave_distinct_users check (user_id <> peer_id)
);
create index waves_user_idx on public.waves (user_id, notified);
