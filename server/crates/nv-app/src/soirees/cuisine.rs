//! Les écritures des soirées que plusieurs portes partagent : fermer une
//! soirée, faire entrer quelqu'un dans un « moment », oublier une affiche.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

use crate::acces::q;
use crate::fichiers::regles::premier_dossier;
use crate::relations::rencontres;

/// **Fermer une soirée** (ex-`private.close_event`) — par son hôte, à
/// l'horaire, ou quand elle s'est vidée. Une soirée déjà fermée ne change
/// pas.
///
/// Les présents ensemble assez longtemps (`crossing_min_overlap`, toutes
/// présences cumulées) deviennent des croisements — et chaque croisement qui
/// naît devient une rencontre (ex-déclencheur `on_event_crossing_born`).
/// Puis chacun sort, et les positions s'effacent.
pub async fn fermer(db: &mut PgConnection, soiree: Uuid, raison: &str) -> NvResult<()> {
    let e = sqlx::query!("select title, closed_at from public.events where id = $1 for update", soiree)
        .fetch_optional(&mut *db)
        .await?;
    let Some(e) = e.filter(|e| e.closed_at.is_none()) else { return Ok(()) };
    sqlx::query!(
        "update public.events set closed_at = now(), close_reason = $2,
                library_reveal_at = coalesce(library_reveal_at, opened_at, now())
          where id = $1",
        soiree,
        raison
    )
    .execute(&mut *db)
    .await?;
    let sql = format!(
        "insert into public.event_crossings (event_id, event_title, user_low, user_high, first_at, last_at, source)
         select $1::uuid, $2::text, o.user_low, o.user_high, o.first_at, o.last_at, 'presence'
           from (select least(a.user_id, b.user_id) as user_low, greatest(a.user_id, b.user_id) as user_high,
                        min(greatest(a.joined_at, b.joined_at)) as first_at,
                        max(least(coalesce(a.left_at, now()), coalesce(b.left_at, now()))) as last_at,
                        sum(least(coalesce(a.left_at, now()), coalesce(b.left_at, now())) - greatest(a.joined_at, b.joined_at)) as overlap
                   from public.event_presences a
                   join public.event_presences b on b.event_id = a.event_id and b.user_id > a.user_id
                  where a.event_id = $1::uuid
                    and least(coalesce(a.left_at, now()), coalesce(b.left_at, now())) > greatest(a.joined_at, b.joined_at)
                  group by 1, 2) o
          where o.overlap >= (select crossing_min_overlap from public.event_rules)
            and not {bloque}
         on conflict (event_id, user_low, user_high) do update
           set last_at = greatest(event_crossings.last_at, excluded.last_at)
         returning user_low, user_high, first_at, event_title, (xmax = 0) as nee",
        bloque = q::est_bloque("o.user_low", "o.user_high")
    );
    // (bas, haut, première fois, titre, vient de naître)
    type Croisement = (Uuid, Uuid, chrono::DateTime<chrono::Utc>, Option<String>, bool);
    let nes: Vec<Croisement> = sqlx::query_as(&sql).bind(soiree).bind(&e.title).fetch_all(&mut *db).await?;
    for (bas, haut, premier, titre, nee) in nes {
        if nee {
            rencontres::croisement_en_soiree(db, soiree, bas, haut, titre.as_deref(), premier).await?;
        }
    }
    sqlx::query!(
        "update public.event_presences set left_at = now(), left_reason = 'closed' where event_id = $1 and left_at is null",
        soiree
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!("delete from public.event_positions where event_id = $1", soiree).execute(&mut *db).await?;
    Ok(())
}

/// **Entrer dans un moment** (ex-`private.add_to_moment`) : du groupe, de la
/// conversation, et présent — en sortant de toute autre soirée (une seule à
/// la fois).
pub async fn ajouter_au_moment(db: &mut PgConnection, soiree: Uuid, qui: Uuid) -> NvResult<()> {
    let conv = sqlx::query_scalar!("select conversation_id from public.events where id = $1", soiree)
        .fetch_optional(&mut *db)
        .await?;
    sqlx::query!(
        "insert into public.event_group_members (event_id, user_id, role, added_by) values ($1, $2, 'admin', $2) on conflict do nothing",
        soiree,
        qui
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "insert into public.conversation_members (conversation_id, user_id) values ($1, $2) on conflict do nothing",
        conv,
        qui
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "update public.event_presences set left_at = now(), left_reason = 'manual' where user_id = $1 and left_at is null and event_id <> $2",
        qui,
        soiree
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "insert into public.event_presences (event_id, user_id, last_ping_at)
         select $1, $2, now()
          where not exists (select 1 from public.event_presences where event_id = $1 and user_id = $2 and left_at is null)",
        soiree,
        qui
    )
    .execute(db)
    .await?;
    Ok(())
}

/// **Oublier une affiche** (ex-`private.oublie_l_affiche`) : son fichier
/// sera effacé dans 7 jours (une pierre tombale, que le balai des fichiers
/// honore).
pub async fn oublier_l_affiche(db: &mut PgConnection, chemin: &str) -> NvResult<()> {
    let auteur = premier_dossier(chemin).and_then(|d| Uuid::parse_str(d).ok());
    sqlx::query!(
        "insert into public.storage_tombstones (bucket_id, object_name, owner_id, delete_after)
         values ('event_posters', $1, $2, now() + interval '7 days')
         on conflict (bucket_id, object_name) do nothing",
        chemin,
        auteur
    )
    .execute(db)
    .await?;
    Ok(())
}
