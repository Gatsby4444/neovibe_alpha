//! **Les paliers d'amitié** (docs/paliers-d-amitie.md) — ex-`refresh_tier`,
//! `refresh_all_tiers`, `days_met`, `tier_for_days`, `days_to_next_tier`,
//! `friendship_streak`.
//!
//! Le palier d'un lien se déduit des JOURS où les deux se sont vus
//! (`meeting_days`) dans les 30 derniers jours : 5 jours = proche, 15 =
//! intime.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

use super::regles::{palier_pour, FENETRE_PALIERS_JOURS, JOURS_INTIME, JOURS_PROCHE, TOLERANCE_SERIE_JOURS};

/// `private.days_met(a, b)` : les jours de rencontre récents.
pub async fn jours_ensemble(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<i32> {
    Ok(sqlx::query_scalar!(
        r#"select count(*)::int as "n!" from public.meeting_days m
            where m.user_low = least($1::uuid, $2::uuid) and m.user_high = greatest($1::uuid, $2::uuid)
              and m.day > current_date - $3::int"#,
        a,
        b,
        FENETRE_PALIERS_JOURS
    )
    .fetch_one(db)
    .await?)
}

/// `private.refresh_tier(a, b)` : recalcule le palier d'un lien.
pub async fn recalculer(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<()> {
    let jours = jours_ensemble(db, a, b).await?;
    sqlx::query!(
        "update public.connections
            set tier = $3::text::public.friendship_tier, tier_days = $4, tier_refreshed_at = now()
          where user_low = least($1::uuid, $2::uuid) and user_high = greatest($1::uuid, $2::uuid)",
        a,
        b,
        palier_pour(jours),
        jours
    )
    .execute(db)
    .await?;
    Ok(())
}

/// `private.refresh_all_tiers()` : le balai de nuit ; rend combien de liens.
pub async fn recalculer_tous(db: &mut PgConnection) -> NvResult<String> {
    let n = sqlx::query!(
        r#"with calc as (
             select c.user_low, c.user_high,
                    (select count(*)::int from public.meeting_days m
                      where m.user_low = c.user_low and m.user_high = c.user_high
                        and m.day > current_date - $1::int) as d
               from public.connections c
           )
           update public.connections c
              set tier = (case when calc.d >= $2 then 'inner' when calc.d >= $3 then 'close' else 'friend' end)::public.friendship_tier,
                  tier_days = calc.d,
                  tier_refreshed_at = now()
             from calc
            where c.user_low = calc.user_low and c.user_high = calc.user_high"#,
        FENETRE_PALIERS_JOURS,
        JOURS_INTIME,
        JOURS_PROCHE
    )
    .execute(db)
    .await?
    .rows_affected();
    Ok(format!("{n} lien(s) recalculé(s)"))
}

/// L'expression SQL de `private.days_to_next_tier(d)`.
pub fn jours_avant_suivant(d: &str) -> String {
    format!("(case when {d} >= {JOURS_INTIME} then null when {d} >= {JOURS_PROCHE} then {JOURS_INTIME} - {d} else {JOURS_PROCHE} - {d} end)")
}

/// L'expression SQL de `private.friendship_streak(a, b)` : la série de
/// jours où les deux se sont vus, avec une tolérance de 2 jours.
pub fn serie(a: &str, b: &str) -> String {
    format!(
        "(with sr_jours as (select m.day, coalesce(lag(m.day) over (order by m.day desc), current_date) as plus_recent \
            from public.meeting_days m where m.user_low = least({a}, {b}) and m.user_high = greatest({a}, {b}) \
            and m.day <= current_date), \
          sr_ecarts as (select (plus_recent - day) as ecart, row_number() over (order by day desc) as rang from sr_jours), \
          sr_coupure as (select min(rang) as rang from sr_ecarts where ecart > {tol} + 1) \
         select coalesce((select rang - 1 from sr_coupure), (select count(*)::int from sr_ecarts), 0))",
        tol = TOLERANCE_SERIE_JOURS
    )
}
