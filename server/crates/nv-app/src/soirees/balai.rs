//! Le balai des soirées (ex-`private.sweep_events`, chaque minute) et celui
//! de la mémoire des rencontres (ex-`purge_meetings`, chaque nuit).
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

use super::cuisine;
use crate::acces::q;
use crate::relations::regles::CRENEAU_S;

/// Les paires d'AMIS qui se voient mutuellement depuis `moment_min_slots`
/// créneaux, jusqu'à maintenant (ex-`private.friends_together_now`).
async fn amis_ensemble(db: &mut PgConnection) -> NvResult<Vec<(Uuid, Uuid)>> {
    let sql = format!(
        "with r as (select moment_min_slots from public.event_rules),
         maintenant as (select floor(extract(epoch from now()) / $1::bigint)::bigint as creneau)
         select m.lo, m.hi from (
           select least(a.observer_id, a.seen_id) as lo, greatest(a.observer_id, a.seen_id) as hi, a.slot
             from public.sightings a
             join public.sightings b on b.observer_id = a.seen_id and b.seen_id = a.observer_id
                                    and b.slot between a.slot - 1 and a.slot + 1
            where a.observer_id < a.seen_id
              and a.slot >= (select creneau from maintenant) - (select moment_min_slots from r)
         ) m
         group by m.lo, m.hi
         having count(distinct m.slot) >= (select moment_min_slots from r)
            and max(m.slot) >= (select creneau from maintenant) - 1
            and {amis}",
        amis = q::sont_amis("m.lo", "m.hi")
    );
    Ok(sqlx::query_as::<_, (Uuid, Uuid)>(&sql).bind(CRENEAU_S).fetch_all(db).await?)
}

/// **Les moments** (ex-`private.form_moments`) : deux amis ensemble, et
/// aucun des deux dans une soirée → un moment (une soirée privée) s'ouvre
/// pour eux. L'un y est déjà : l'autre le rejoint, SEULEMENT si c'est un
/// moment (une vraie soirée garde ses règles d'entrée). Puis la vue mutuelle
/// tient lieu de preuve de présence.
async fn former_les_moments(db: &mut PgConnection) -> NvResult<()> {
    let actif = sqlx::query_scalar!(r#"select moment_enabled as "b!" from public.event_rules"#)
        .fetch_optional(&mut *db)
        .await?
        .unwrap_or(false);
    if !actif {
        return Ok(());
    }
    for (bas, haut) in amis_ensemble(db).await? {
        let soiree_de = |u: Uuid| {
            sqlx::query_scalar!("select event_id from public.event_presences where user_id = $1 and left_at is null limit 1", u)
        };
        let a = soiree_de(bas).fetch_optional(&mut *db).await?;
        let b = soiree_de(haut).fetch_optional(&mut *db).await?;
        let (soiree, qui) = match (a, b) {
            (Some(_), Some(_)) => continue,
            (Some(e), None) | (None, Some(e)) => {
                let moment = sqlx::query_scalar!(
                    r#"select exists (select 1 from public.events where id = $1 and auto_created and closed_at is null) as "b!""#,
                    e
                )
                .fetch_one(&mut *db)
                .await?;
                if !moment {
                    continue;
                }
                (e, if a.is_none() { bas } else { haut })
            }
            (None, None) => {
                let titre = sqlx::query_scalar!(
                    r#"select 'Moment du ' || to_char(now() at time zone 'Europe/Paris', 'DD/MM à HH24:MI') as "t!""#
                )
                .fetch_one(&mut *db)
                .await?;
                let conv = sqlx::query_scalar!(
                    "insert into public.conversations (conversation_type, title, created_by) values ('event', $1, $2) returning id",
                    titre,
                    bas
                )
                .fetch_one(&mut *db)
                .await?;
                let e = sqlx::query_scalar!(
                    "insert into public.events (kind, title, created_by, conversation_id, starts_at, opened_at, auto_created)
                     values ('private', $1, $2, $3, now(), now(), true) returning id",
                    titre,
                    bas,
                    conv
                )
                .fetch_one(&mut *db)
                .await?;
                cuisine::ajouter_au_moment(db, e, bas).await?;
                (e, haut)
            }
        };
        cuisine::ajouter_au_moment(db, soiree, qui).await?;
    }
    // La preuve de présence d'un moment : la vue mutuelle, rafraîchie pour
    // les paires encore ensemble.
    let paires = amis_ensemble(db).await?;
    let (bas, haut): (Vec<Uuid>, Vec<Uuid>) = paires.into_iter().unzip();
    sqlx::query!(
        "update public.event_presences p set last_ping_at = now()
           from public.events e, unnest($1::uuid[], $2::uuid[]) as t(user_low, user_high)
          where e.id = p.event_id and e.auto_created and e.closed_at is null and p.left_at is null
            and p.user_id in (t.user_low, t.user_high)
            and exists (select 1 from public.event_presences q where q.event_id = p.event_id and q.left_at is null
                         and q.user_id = case when p.user_id = t.user_low then t.user_high else t.user_low end)",
        &bas,
        &haut
    )
    .execute(db)
    .await?;
    Ok(())
}

/// **Le balai des soirées**, chaque minute, dans l'ordre d'avant :
/// 0. les moments ;
/// 1. sans preuve de présence depuis `away_after` : sorti ;
/// 2. l'heure de fin d'une soirée ouverte ou d'établissement : fermée ;
/// 3. une soirée privée (ou un moment) désertée — 80 % partis après le délai
///    de grâce : fermée ;
/// 4. `survival` après sa fermeture, la soirée et sa conversation (chat,
///    Drop) disparaissent. Les croisements et les rencontres restent.
pub async fn balayer(db: &mut PgConnection) -> NvResult<String> {
    former_les_moments(db).await?;
    let partis = sqlx::query!(
        "update public.event_presences p set left_at = now(), left_reason = 'away'
          where p.left_at is null
            and greatest(coalesce(p.last_position_at, p.joined_at), coalesce(p.last_ping_at, p.joined_at))
                < now() - (select away_after from public.event_rules)"
    )
    .execute(&mut *db)
    .await?
    .rows_affected();
    sqlx::query!(
        "delete from public.event_positions x
          where not exists (select 1 from public.event_presences p
                             where p.event_id = x.event_id and p.user_id = x.user_id and p.left_at is null)"
    )
    .execute(&mut *db)
    .await?;
    let a_l_heure = sqlx::query_scalar!(
        "select id from public.events
          where closed_at is null and kind in ('venue', 'open') and scheduled_end_at is not null and scheduled_end_at <= now()"
    )
    .fetch_all(&mut *db)
    .await?;
    for e in &a_l_heure {
        cuisine::fermer(db, *e, "schedule").await?;
    }
    let desertees = sqlx::query_scalar!(
        r#"select e.id as "id!" from public.events e, public.event_rules r
            where e.closed_at is null and e.kind = 'private' and e.opened_at is not null
              and e.opened_at < now() - r.private_close_grace
              and (select count(distinct p.user_id) from public.event_presences p where p.event_id = e.id) > 0
              and (select count(*) from public.event_presences p where p.event_id = e.id and p.left_at is null)
                  <= (1 - r.private_close_ratio) * (select count(distinct p.user_id) from public.event_presences p where p.event_id = e.id)"#
    )
    .fetch_all(&mut *db)
    .await?;
    for e in &desertees {
        cuisine::fermer(db, *e, "deserted").await?;
    }
    let parties = sqlx::query!(
        "select e.id, e.conversation_id from public.events e, public.event_rules r
          where e.closed_at is not null and e.closed_at < now() - r.survival"
    )
    .fetch_all(&mut *db)
    .await?;
    for e in &parties {
        sqlx::query!("delete from public.events where id = $1", e.id).execute(&mut *db).await?;
        sqlx::query!("delete from public.conversations where id = $1", e.conversation_id).execute(&mut *db).await?;
    }
    Ok(format!(
        "{partis} sortie(s), {} fermée(s) à l'heure, {} désertée(s), {} effacée(s)",
        a_l_heure.len(),
        desertees.len(),
        parties.len()
    ))
}

/// La mémoire des rencontres (ex-`purge_meetings`, chaque nuit à 4 h 23) :
/// au-delà de la fenêtre `meeting` (2 ans), une rencontre s'oublie.
pub async fn oublier_les_rencontres(db: &mut PgConnection) -> NvResult<String> {
    let sql = format!("delete from public.meetings where last_at < now() - {}", q::fenetre("meeting"));
    let n = sqlx::query(&sql).execute(db).await?.rows_affected();
    Ok(format!("{n} rencontre(s) oubliée(s)"))
}
