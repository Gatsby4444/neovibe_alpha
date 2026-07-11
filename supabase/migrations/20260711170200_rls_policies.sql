-- NeoVibe V1 — politiques RLS
-- Principe : aucun annuaire global. Chaque lecture passe par une relation légitime
-- (connexion, conversation partagée, demande en cours, coprésence BLE prouvée via RPC).

alter table public.profiles enable row level security;
alter table public.connections enable row level security;
alter table public.connection_requests enable row level security;
alter table public.recommendations enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reads enable row level security;
alter table public.cards enable row level security;
alter table public.card_deliveries enable row level security;
alter table public.library_items enable row level security;
alter table public.library_access enable row level security;
alter table public.waves enable row level security;

-- ---------- profiles ----------
create policy "profiles_select" on public.profiles for select
  using (public.can_view_profile((select auth.uid()), id));

create policy "profiles_insert_own" on public.profiles for insert
  with check (id = (select auth.uid()));

create policy "profiles_update_own" on public.profiles for update
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ---------- connections ----------
create policy "connections_select_own" on public.connections for select
  using ((select auth.uid()) in (user_low, user_high));

-- Créées uniquement par les fonctions security definer (BLE, recommandation, partielle).
-- Suppression = se déconnecter de quelqu'un : autorisée aux deux membres.
create policy "connections_delete_own" on public.connections for delete
  using ((select auth.uid()) in (user_low, user_high));

-- ---------- connection_requests ----------
create policy "requests_select_own" on public.connection_requests for select
  using ((select auth.uid()) in (sender_id, receiver_id));

create policy "requests_insert_sender" on public.connection_requests for insert
  with check (
    sender_id = (select auth.uid())
    and not public.are_connected(sender_id, receiver_id)
  );

-- L'émetteur rafraîchit expires_at tant que la proximité BLE persiste
create policy "requests_update_sender" on public.connection_requests for update
  using (sender_id = (select auth.uid()) and status = 'pending')
  with check (sender_id = (select auth.uid()));

-- ---------- recommendations ----------
create policy "reco_select_requester" on public.recommendations for select
  using (requester_id = (select auth.uid()));

create policy "reco_select_intermediary" on public.recommendations for select
  using (intermediary_id = (select auth.uid()));

create policy "reco_select_target" on public.recommendations for select
  using (target_id = (select auth.uid()) and status in ('forwarded', 'accepted'));

create policy "reco_insert_requester" on public.recommendations for insert
  with check (
    requester_id = (select auth.uid())
    and target_id is null
    and status = 'requested'
    and public.are_connected(requester_id, intermediary_id)
  );

-- ---------- conversations ----------
create policy "conversations_select_member" on public.conversations for select
  using (public.is_conversation_member(id, (select auth.uid())));

-- Groupes créés directement par le client ; direct/proximité passent par les RPC
create policy "conversations_insert_group" on public.conversations for insert
  with check (
    conversation_type = 'group'
    and created_by = (select auth.uid())
    and pair_key is null
  );

create policy "conversations_update_group_member" on public.conversations for update
  using (
    conversation_type = 'group'
    and public.is_conversation_member(id, (select auth.uid()))
  )
  with check (conversation_type = 'group');

-- ---------- conversation_members ----------
create policy "members_select_shared" on public.conversation_members for select
  using (public.is_conversation_member(conversation_id, (select auth.uid())));

-- Bootstrap : le créateur d'un groupe s'ajoute lui-même
create policy "members_insert_self_creator" on public.conversation_members for insert
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.conversations c
      where c.id = conversation_id
        and c.created_by = (select auth.uid())
        and c.conversation_type = 'group'
    )
  );

-- Un membre d'un groupe peut ajouter SES connexions uniquement
create policy "members_insert_by_member" on public.conversation_members for insert
  with check (
    public.is_conversation_member(conversation_id, (select auth.uid()))
    and public.are_connected((select auth.uid()), user_id)
    and exists (
      select 1 from public.conversations c
      where c.id = conversation_id and c.conversation_type = 'group'
    )
  );

-- Retrait : soi-même (quitter) ou par un membre existant (spec 4.7, gestion basique)
create policy "members_delete_by_member" on public.conversation_members for delete
  using (
    user_id = (select auth.uid())
    or public.is_conversation_member(conversation_id, (select auth.uid()))
  );

-- ---------- messages ----------
-- L'éphémère est garanti à la lecture (expires_at) en plus de la purge cron
create policy "messages_select_member_unexpired" on public.messages for select
  using (
    public.is_conversation_member(conversation_id, (select auth.uid()))
    and expires_at > now()
  );

create policy "messages_insert_member" on public.messages for insert
  with check (
    sender_id = (select auth.uid())
    and public.is_conversation_member(conversation_id, (select auth.uid()))
    and expires_at <= now() + interval '24 hours'
  );

-- ---------- message_reads ----------
create policy "reads_select_member" on public.message_reads for select
  using (
    exists (
      select 1 from public.messages m
      where m.id = message_id
        and public.is_conversation_member(m.conversation_id, (select auth.uid()))
    )
  );

create policy "reads_insert_own" on public.message_reads for insert
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.messages m
      where m.id = message_id
        and m.sender_id <> (select auth.uid())
        and public.is_conversation_member(m.conversation_id, (select auth.uid()))
    )
  );

-- ---------- cards ----------
create policy "cards_select_owner" on public.cards for select
  using (owner_id = (select auth.uid()));

-- Destinataire : uniquement si la livraison n'est pas détruite (Oneshot)
create policy "cards_select_recipient" on public.cards for select
  using (
    exists (
      select 1 from public.card_deliveries d
      where d.card_id = id
        and d.recipient_id = (select auth.uid())
        and d.destroyed_at is null
    )
  );

-- Visible via la bibliothèque du propriétaire (selon ses règles d'accès)
create policy "cards_select_library" on public.cards for select
  using (
    exists (
      select 1 from public.library_items li
      where li.card_id = id
        and public.can_view_library(li.owner_id, (select auth.uid()))
    )
  );

create policy "cards_insert_own" on public.cards for insert
  with check (owner_id = (select auth.uid()));

create policy "cards_delete_own" on public.cards for delete
  using (owner_id = (select auth.uid()));

-- ---------- card_deliveries ----------
create policy "deliveries_select_parties" on public.card_deliveries for select
  using (
    recipient_id = (select auth.uid())
    or exists (select 1 from public.cards c where c.id = card_id and c.owner_id = (select auth.uid()))
  );

create policy "deliveries_insert_card_owner" on public.card_deliveries for insert
  with check (
    exists (select 1 from public.cards c where c.id = card_id and c.owner_id = (select auth.uid()))
  );

-- ---------- library ----------
create policy "library_select_visible" on public.library_items for select
  using (public.can_view_library(owner_id, (select auth.uid())));

create policy "library_insert_own" on public.library_items for insert
  with check (owner_id = (select auth.uid()));

create policy "library_update_own" on public.library_items for update
  using (owner_id = (select auth.uid()));

create policy "library_delete_own" on public.library_items for delete
  using (owner_id = (select auth.uid()));

create policy "library_access_select" on public.library_access for select
  using ((select auth.uid()) in (owner_id, grantee_id));

create policy "library_access_manage" on public.library_access for insert
  with check (owner_id = (select auth.uid()) and public.are_connected(owner_id, grantee_id));

create policy "library_access_delete" on public.library_access for delete
  using (owner_id = (select auth.uid()));

-- ---------- waves ----------
create policy "waves_select_own" on public.waves for select
  using (user_id = (select auth.uid()));

create policy "waves_insert_own" on public.waves for insert
  with check (
    user_id = (select auth.uid())
    and public.are_connected(user_id, peer_id)
  );

create policy "waves_update_own" on public.waves for update
  using (user_id = (select auth.uid()));
