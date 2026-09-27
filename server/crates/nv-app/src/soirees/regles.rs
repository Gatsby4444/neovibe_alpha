//! Les règles des soirées : les questions qui leur sont propres, et ce qui
//! se lit dans `event_rules` (une ligne, réglée par Jay).
//!
//! Les nombres des règles restent dans la base et se lisent dans les
//! requêtes mêmes : un calcul qui mêle un rayon entier, un facteur décimal et
//! une précision GPS garde ainsi exactement la même arithmétique qu'avant.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::{NvError, NvResult};

use crate::acces::q;
use crate::carte::autour::distance_m;

/// `private.is_present_in_event(soirée, compte)` : présent en ce moment.
pub fn present(e: &str, uid: &str) -> String {
    format!("exists (select 1 from public.event_presences pr_ where pr_.event_id = {e} and pr_.user_id = {uid} and pr_.left_at is null)")
}

/// `private.may_invite_to_event(soirée, compte)` : une soirée privée ouverte,
/// dont je suis le créateur — ou un admin, si les membres peuvent ajouter.
pub fn peut_inviter(e: &str, uid: &str) -> String {
    format!(
        "exists (select 1 from public.events pi_e join public.event_group_members pi_m on pi_m.event_id = pi_e.id and pi_m.user_id = {uid} \
         where pi_e.id = {e} and pi_e.kind = 'private' and pi_e.closed_at is null \
           and (pi_e.created_by = {uid} or (pi_m.role = 'admin' and pi_e.members_can_add)))"
    )
}

/// `private.may_remove_from_event(soirée, compte)` : idem, pour retirer.
pub fn peut_retirer(e: &str, uid: &str) -> String {
    format!(
        "exists (select 1 from public.events pt_e join public.event_group_members pt_m on pt_m.event_id = pt_e.id and pt_m.user_id = {uid} \
         where pt_e.id = {e} and pt_e.kind = 'private' and pt_e.closed_at is null \
           and (pt_e.created_by = {uid} or (pt_m.role = 'admin' and pt_e.members_can_remove)))"
    )
}

/// `private.friends_present(soirée, compte)` : mes amis présents (une
/// valeur `uuid[]`, dans l'ordre de leur arrivée).
pub fn amis_presents(e: &str, uid: &str) -> String {
    format!(
        "(select coalesce(array_agg(ap_p.user_id order by ap_p.joined_at), '{{}}') from public.event_presences ap_p \
          where ap_p.event_id = {e} and ap_p.left_at is null and ap_p.user_id <> {uid} \
            and {amis} and not {bloque})",
        amis = q::sont_amis(uid, "ap_p.user_id"),
        bloque = q::est_bloque(uid, "ap_p.user_id"),
    )
}

/// `private.assert_precise_place` : poser une soirée demande une position
/// précise (`place_max_accuracy_m`). Sans lieu, rien à vérifier.
pub async fn lieu_precis(db: &mut PgConnection, lat: Option<f64>, precision: Option<f64>) -> NvResult<()> {
    if lat.is_none() {
        return Ok(());
    }
    let max = sqlx::query_scalar!(r#"select place_max_accuracy_m as "m!" from public.event_rules limit 1"#)
        .fetch_one(db)
        .await?;
    match precision {
        Some(p) if p <= f64::from(max) => Ok(()),
        _ => {
            let arrondi = precision.map(|p| format!("{}", p.round_ties_even())).unwrap_or_else(|| "?".into());
            Err(NvError::refused(format!("Position trop imprécise pour poser une soirée (± {arrondi} m, {max} m au plus)")))
        }
    }
}

/// `private.event_size_radius` : le rayon d'une taille (bar, grand lieu,
/// plein air) ; sans taille, celui d'un bar.
pub async fn rayon_de_taille(db: &mut PgConnection, rayon: Option<i32>) -> NvResult<i32> {
    let r = sqlx::query!(r#"select size_bar_m as "bar!", size_grand_m as "grand!", size_plein_air_m as "plein_air!" from public.event_rules limit 1"#)
        .fetch_one(db)
        .await?;
    match rayon {
        None => Ok(r.bar),
        Some(m) if [r.bar, r.grand, r.plein_air].contains(&m) => Ok(m),
        Some(m) => Err(NvError::refused(format!("Taille de soirée inconnue ({m} m)"))),
    }
}

/// `private.far_from_event` : trop loin de la soirée pour y être encore ?
/// La distance au plus proche des présents récents (ou au lieu de la
/// soirée) ; au-delà de `exit_factor` fois le rayon (plus loin que l'entrée,
/// pour qu'un GPS qui hésite n'éjecte personne), ou `leave_radius_m` sans
/// lieu fixe — la précision GPS en marge, 100 m au plus. Personne à qui se
/// mesurer : pas loin.
pub async fn loin_de_la_soiree(
    db: &mut PgConnection,
    soiree: Uuid,
    moi: Uuid,
    lat: f64,
    lon: f64,
    precision: Option<f64>,
) -> NvResult<bool> {
    let sql = format!(
        "with r as (select * from public.event_rules),
         s as (
           select {d_pos} as d
             from public.event_positions x
             join public.event_presences pr on pr.event_id = x.event_id and pr.user_id = x.user_id and pr.left_at is null
            where x.event_id = $1::uuid and x.user_id <> $2::uuid and x.reported_at > now() - (select away_after from r)
           union all
           select {d_lieu} from public.events e where e.id = $1::uuid and e.lat is not null
         )
         select case when count(*) = 0 then false
                else min(d) > coalesce((select e.radius_m * r.exit_factor from public.events e, r where e.id = $1::uuid),
                                       (select leave_radius_m from r))
                              + coalesce(least($5::float8, 100), 0) end
           from s",
        d_pos = distance_m("$3::float8", "$4::float8", "x.lat", "x.lon"),
        d_lieu = distance_m("$3::float8", "$4::float8", "e.lat", "e.lon"),
    );
    Ok(sqlx::query_scalar::<_, Option<bool>>(&sql)
        .bind(soiree)
        .bind(moi)
        .bind(lat)
        .bind(lon)
        .bind(precision)
        .fetch_one(db)
        .await?
        .unwrap_or(false))
}
