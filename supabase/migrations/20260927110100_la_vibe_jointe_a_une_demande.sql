-- Une Vibe jointe à une demande d'ami peut enfin partir.
--
-- Trouvé le 2026-09-27 en traduisant le domaine des Vibes pour le serveur
-- Rust, puis REPRODUIT sur la base de dev sous l'identité de Charles :
-- `request_connection_with_vibe` (envoyer une Vibe avec une demande d'ami à
-- quelqu'un qu'on vient de CROISER — donc pas encore ami) échouait à chaque
-- fois. Elle crée la demande, puis la livraison de la Vibe… que la règle
-- des livraisons (`enforce_card_delivery_rules`) refusait :
--   « Les Cards ne peuvent être envoyées qu'à des connexions »
-- La fonction n'avait donc jamais pu servir à ce pour quoi elle existe.
--
-- Réparation, la plus étroite possible : une livraison à un non-ami est
-- permise SEULEMENT si elle accompagne la demande d'ami EN ATTENTE que
-- l'auteur de la Vibe a envoyée à ce destinataire, et qui porte CETTE Vibe.
-- Toute autre livraison à un non-ami reste refusée, comme avant.
create or replace function public.enforce_card_delivery_rules()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'private'
as $$
declare
  c record;
begin
  select * into c from cards where id = new.card_id;
  if c.owner_id <> new.recipient_id
     and not are_connected(c.owner_id, new.recipient_id)
     and not exists (
       select 1 from connection_requests r
       where r.sender_id = c.owner_id and r.receiver_id = new.recipient_id
         and r.card_id = new.card_id and r.status = 'pending' and r.expires_at > now()
     ) then
    raise exception 'Les Cards ne peuvent être envoyées qu''à des connexions';
  end if;
  if c.card_type = 'one_of_one' then
    if exists (select 1 from card_deliveries where card_id = new.card_id) then
      raise exception 'Une Card One of One ne peut avoir qu''un seul destinataire';
    end if;
  end if;
  return new;
end;
$$;
