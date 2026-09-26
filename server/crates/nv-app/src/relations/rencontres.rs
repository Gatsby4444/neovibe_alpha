//! **La mémoire des rencontres** (`meetings`) — ex-`private.note_meeting`.
//!
//! Une rencontre se note des DEUX côtés (une ligne pour chacun), jamais
//! entre deux comptes dont l'un a bloqué l'autre. Une rencontre en soirée
//! porte la soirée et un lieu GOMMÉ (arrondi à la case de
//! `feed_rules.anchor_cell_m`, ex-`private.gomme_ancre`) ; une rencontre au
//! ping n'a pas de lieu.
use chrono::{DateTime, Utc};
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

use crate::acces;

/// Ce qui a fait se rencontrer deux comptes.
pub struct Rencontre<'a> {
    pub origine: &'a str,
    pub soiree: Option<(Uuid, Option<&'a str>)>,
    pub lieu: Option<(f64, f64)>,
    pub quand: DateTime<Utc>,
}

/// Un croisement en soirée vient de naître (ex-déclencheur
/// `on_event_crossing_born`) : la rencontre se note avec la soirée et son
/// lieu.
pub async fn croisement_en_soiree(
    db: &mut PgConnection,
    soiree: Uuid,
    bas: Uuid,
    haut: Uuid,
    titre: Option<&str>,
    quand: DateTime<Utc>,
) -> NvResult<()> {
    let e = sqlx::query!("select title, lat, lon from public.events where id = $1", soiree)
        .fetch_optional(&mut *db)
        .await?;
    let (titre_soiree, lieu) = match &e {
        Some(e) => (Some(e.title.as_str()), e.lat.zip(e.lon)),
        None => (None, None),
    };
    let titre = titre.or(titre_soiree);
    noter(db, bas, haut, Rencontre { origine: "event", soiree: Some((soiree, titre)), lieu, quand }).await
}

/// Note une rencontre entre `a` et `b`.
pub async fn noter(db: &mut PgConnection, a: Uuid, b: Uuid, r: Rencontre<'_>) -> NvResult<()> {
    if a == b || acces::is_blocked(db, a, b).await? {
        return Ok(());
    }
    let (lat, lon) = r.lieu.map(|(la, lo)| (Some(la), Some(lo))).unwrap_or((None, None));
    match r.soiree {
        Some((soiree, titre)) => {
            sqlx::query!(
                r#"with g as (
                     select case when $5::float8 is null or $6::float8 is null then null::float8
                                 else round($5::float8 / s.step_lat) * s.step_lat end as lat,
                            s.step_lat
                       from (select r.anchor_cell_m::float8 / 111320.0 as step_lat from public.feed_rules r where r.id) s
                   ), gl as (
                     select g.lat,
                            case when g.lat is null or $6::float8 is null then null::float8
                                 else round($6::float8 / (g.step_lat / greatest(cos(radians(g.lat)), 0.01)))
                                      * (g.step_lat / greatest(cos(radians(g.lat)), 0.01)) end as lng
                       from g
                   )
                   insert into public.meetings (user_id, other_id, origin, event_id, event_title, lat, lon, met_at, last_at)
                   select x.u, x.o, $3, $4, $7, gl.lat, gl.lng, $8, $8
                     from gl, (values ($1::uuid, $2::uuid), ($2::uuid, $1::uuid)) as x(u, o)
                   on conflict (user_id, other_id, event_id) where event_id is not null
                     do update set last_at = greatest(meetings.last_at, excluded.last_at)"#,
                a,
                b,
                r.origine,
                soiree,
                lat,
                lon,
                titre,
                r.quand
            )
            .execute(db)
            .await?;
        }
        None => {
            sqlx::query!(
                "insert into public.meetings (user_id, other_id, origin, met_at, last_at)
                 values ($1, $2, $3, $4, $4), ($2, $1, $3, $4, $4)",
                a,
                b,
                r.origine,
                r.quand
            )
            .execute(db)
            .await?;
        }
    }
    Ok(())
}
