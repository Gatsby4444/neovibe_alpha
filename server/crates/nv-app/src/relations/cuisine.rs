//! Les lectures et écritures des relations et de la proximité.
use chrono::{DateTime, Utc};
use serde_json::Value;
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

use super::regles::{carreau, FENETRE_RENCONTRE, VIE_BALISE};

// ─── Le ping ────────────────────────────────────────────────────────────────

/// Dépose (ou remplace) ma balise.
pub async fn deposer_balise(db: &mut PgConnection, moi: Uuid, lat: f64, lon: f64, acc: Option<f64>, jeton: &str, creneau: i64) -> NvResult<()> {
    sqlx::query!(
        "insert into public.ping_beacons (user_id, cell_lat, cell_lon, lat, lon, acc, token, slot)
         values ($1, $2, $3, $4, $5, greatest(0, coalesce($6::float8, 0)), $7, $8)
         on conflict (user_id) do update
           set cell_lat = excluded.cell_lat, cell_lon = excluded.cell_lon, lat = excluded.lat, lon = excluded.lon,
               acc = excluded.acc, token = excluded.token, slot = excluded.slot, updated_at = now()",
        moi,
        carreau(lat),
        carreau(lon),
        lat,
        lon,
        acc,
        jeton,
        creneau
    )
    .execute(db)
    .await?;
    Ok(())
}

pub async fn retirer_balise(db: &mut PgConnection, moi: Uuid) -> NvResult<()> {
    sqlx::query!("delete from public.ping_beacons where user_id = $1", moi).execute(db).await?;
    Ok(())
}

/// Le carreau de ma balise encore vivante.
pub async fn mon_carreau(db: &mut PgConnection, moi: Uuid) -> NvResult<Option<(i32, i32)>> {
    let sql = format!(
        "select b.cell_lat, b.cell_lon from public.ping_beacons b where b.user_id = $1 and b.updated_at > now() - {VIE_BALISE}"
    );
    Ok(sqlx::query_as::<_, (i32, i32)>(&sql).bind(moi).fetch_optional(db).await?)
}

/// La personne derrière un jeton entendu (le SERVEUR résout, jamais l'app).
pub async fn porteur_du_jeton(db: &mut PgConnection, jeton: &str, creneau: i64) -> NvResult<Option<(Uuid, i32, i32)>> {
    Ok(sqlx::query!(
        "select b.user_id, b.cell_lat, b.cell_lon from public.ping_beacons b
          where b.token = $1 and b.slot between $2::bigint - 1 and $2::bigint + 1 limit 1",
        jeton,
        creneau
    )
    .fetch_optional(db)
    .await?
    .map(|r| (r.user_id, r.cell_lat, r.cell_lon)))
}

/// Note que j'ai entendu `sujet` ; rend 1 si c'est nouveau.
pub async fn noter_confirmation(db: &mut PgConnection, moi: Uuid, sujet: Uuid, creneau: i64) -> NvResult<i32> {
    Ok(sqlx::query!(
        "insert into public.ping_confirmations (observer_id, subject_id, slot) values ($1, $2, $3)
         on conflict (observer_id, subject_id, slot) do nothing",
        moi,
        sujet,
        creneau
    )
    .execute(db)
    .await?
    .rows_affected() as i32)
}

/// `sujet` m'a-t-il entendu aussi (le miroir) ?
pub async fn miroir(db: &mut PgConnection, moi: Uuid, sujet: Uuid, creneau: i64) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.ping_confirmations m
                           where m.observer_id = $2 and m.subject_id = $1 and m.slot between $3::bigint - 1 and $3::bigint + 1) as "b!""#,
        moi,
        sujet,
        creneau
    )
    .fetch_one(db)
    .await?)
}

/// La paire naît (ou se revoit) ; rend `Some(première vue)` si elle vient de NAÎTRE.
pub async fn paire_vue(db: &mut PgConnection, bas: Uuid, haut: Uuid) -> NvResult<Option<DateTime<Utc>>> {
    let r = sqlx::query!(
        r#"insert into public.ping_pairs (user_low, user_high) values ($1, $2)
           on conflict (user_low, user_high) do update set last_seen_at = now()
           returning first_seen_at, (xmax = 0) as "nee!""#,
        bas,
        haut
    )
    .fetch_one(db)
    .await?;
    Ok(if r.nee { Some(r.first_seen_at) } else { None })
}

/// Ceux avec qui j'ai une paire récente et qui ne sont pas (encore) des amis.
pub async fn autour_de_moi(db: &mut PgConnection, moi: Uuid, pas_amis_ni_bloques: &str) -> NvResult<Value> {
    let sql = format!(
        "select coalesce(json_agg(t order by t.last_seen_at desc), '[]'::json) from (
           select p.id as user_id, p.display_name, p.pseudo_shown as tag_name, p.avatar_url, pp.last_seen_at, b.token,
                  case when p.special_mention_public then p.special_mention end as special_mention
             from public.ping_pairs pp
             join public.profiles p on p.id = case when pp.user_low = $1 then pp.user_high else pp.user_low end
             left join public.ping_beacons b on b.user_id = p.id and b.updated_at > now() - {VIE_BALISE}
            where (pp.user_low = $1 or pp.user_high = $1)
              and pp.last_seen_at > now() - {FENETRE_RENCONTRE}
              and {pas_amis_ni_bloques}) t"
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(moi).fetch_one(db).await?)
}

/// Combien de balises vivantes plausibles autour de la mienne.
pub async fn voisins(db: &mut PgConnection, moi: Uuid, carreau: (i32, i32), pas_bloque: &str) -> NvResult<i64> {
    let sql = format!(
        "select count(*) from public.ping_beacons b
          where b.user_id <> $1 and b.updated_at > now() - {VIE_BALISE}
            and abs($2 - b.cell_lat) <= 1 and abs($3 - b.cell_lon) <= 1
            and not {pas_bloque}"
    );
    Ok(sqlx::query_scalar::<_, i64>(&sql).bind(moi).bind(carreau.0).bind(carreau.1).fetch_one(db).await?)
}

// ─── Les croisements ───────────────────────────────────────────────────────

pub async fn noter_vu(db: &mut PgConnection, moi: Uuid, pair: Uuid, creneau: i64, bande: Option<&str>) -> NvResult<i32> {
    Ok(sqlx::query!(
        "insert into public.sightings (observer_id, seen_id, slot, band) values ($1, $2, $3, $4)
         on conflict (observer_id, seen_id, slot) do nothing",
        moi,
        pair,
        creneau,
        bande
    )
    .execute(db)
    .await?
    .rows_affected() as i32)
}

pub async fn vu_en_retour(db: &mut PgConnection, moi: Uuid, pair: Uuid, creneau: i64) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.sightings m
                           where m.observer_id = $2 and m.seen_id = $1 and m.slot between $3::bigint - 1 and $3::bigint + 1) as "b!""#,
        moi,
        pair,
        creneau
    )
    .fetch_one(db)
    .await?)
}

/// Le croisement mutuel entre deux amis ; rend vrai si un NOUVEAU jour de
/// rencontre s'est inscrit.
pub async fn croisement_amis(db: &mut PgConnection, bas: Uuid, haut: Uuid) -> NvResult<bool> {
    sqlx::query!(
        "insert into public.encounters (user_low, user_high, first_seen_at, last_seen_at, proof)
         values ($1, $2, now(), now(), 'mutual_sighting')
         on conflict (user_low, user_high) do update
           set last_seen_at = greatest(excluded.last_seen_at, encounters.last_seen_at),
               proof = case when encounters.proof = 'certificate' then 'certificate' else excluded.proof end",
        bas,
        haut
    )
    .execute(&mut *db)
    .await?;
    Ok(sqlx::query!(
        "insert into public.meeting_days (user_low, user_high, day) values ($1, $2, (now() at time zone 'utc')::date)
         on conflict do nothing",
        bas,
        haut
    )
    .execute(db)
    .await?
    .rows_affected()
        > 0)
}

/// Une soirée ouverte où nous sommes présents tous les deux.
pub async fn soiree_commune(db: &mut PgConnection, moi: Uuid, pair: Uuid) -> NvResult<Option<(Uuid, String)>> {
    Ok(sqlx::query!(
        "select e.id, e.title from public.events e
           join public.event_presences a on a.event_id = e.id and a.user_id = $1 and a.left_at is null
           join public.event_presences b on b.event_id = e.id and b.user_id = $2 and b.left_at is null
          where e.closed_at is null limit 1",
        moi,
        pair
    )
    .fetch_optional(db)
    .await?
    .map(|r| (r.id, r.title)))
}

pub async fn noter_vu_en_soiree(db: &mut PgConnection, soiree: Uuid, moi: Uuid, pair: Uuid, creneau: i64) -> NvResult<i32> {
    let n = sqlx::query!(
        "insert into public.event_sightings (event_id, observer_id, seen_id, slot) values ($1, $2, $3, $4) on conflict do nothing",
        soiree,
        moi,
        pair,
        creneau
    )
    .execute(&mut *db)
    .await?
    .rows_affected() as i32;
    // Entendre un co-participant, c'est être là : la preuve « ping ».
    sqlx::query!(
        "update public.event_presences set last_ping_at = now() where event_id = $1 and user_id = $2 and left_at is null",
        soiree,
        moi
    )
    .execute(db)
    .await?;
    Ok(n)
}

pub async fn vu_en_retour_en_soiree(db: &mut PgConnection, soiree: Uuid, moi: Uuid, pair: Uuid, creneau: i64) -> NvResult<bool> {
    Ok(sqlx::query_scalar!(
        r#"select exists (select 1 from public.event_sightings m where m.event_id = $1 and m.observer_id = $3
                           and m.seen_id = $2 and m.slot between $4::bigint - 1 and $4::bigint + 1) as "b!""#,
        soiree,
        moi,
        pair,
        creneau
    )
    .fetch_one(db)
    .await?)
}

/// Le croisement en soirée ; rend `Some(première vue)` s'il vient de NAÎTRE.
pub async fn croisement_en_soiree(db: &mut PgConnection, soiree: Uuid, titre: &str, bas: Uuid, haut: Uuid) -> NvResult<Option<DateTime<Utc>>> {
    let r = sqlx::query!(
        r#"insert into public.event_crossings (event_id, event_title, user_low, user_high, first_at, last_at, source)
           values ($1, $2, $3, $4, now(), now(), 'ping')
           on conflict (event_id, user_low, user_high) do update set last_at = now()
           returning first_at, (xmax = 0) as "nee!""#,
        soiree,
        titre,
        bas,
        haut
    )
    .fetch_one(db)
    .await?;
    Ok(if r.nee { Some(r.first_at) } else { None })
}

// ─── Les liens ──────────────────────────────────────────────────────────────

/// Ce qui dérivait d'un lien disparaît avec lui (ex-déclencheur
/// `oublie_ce_qui_derivait_du_lien`) : les croisements et les vues.
pub async fn oublier_le_lien(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<()> {
    sqlx::query!(
        "delete from public.encounters e where e.user_low = least($1::uuid, $2::uuid) and e.user_high = greatest($1::uuid, $2::uuid)",
        a,
        b
    )
    .execute(&mut *db)
    .await?;
    sqlx::query!(
        "delete from public.sightings s where (s.observer_id = $1 and s.seen_id = $2) or (s.observer_id = $2 and s.seen_id = $1)",
        a,
        b
    )
    .execute(db)
    .await?;
    Ok(())
}

/// Établit le lien d'amitié (ou le rétablit) ; rend son identifiant.
pub async fn etablir_lien(db: &mut PgConnection, a: Uuid, b: Uuid, origine: &str) -> NvResult<Uuid> {
    Ok(sqlx::query_scalar!(
        "insert into public.connections (user_low, user_high, status, origin, established_at)
         values (least($1::uuid, $2::uuid), greatest($1::uuid, $2::uuid), 'full', $3::text::public.connection_origin, now())
         on conflict (user_low, user_high) do update
           set status = 'full', established_at = coalesce(connections.established_at, now())
         returning id",
        a,
        b,
        origine
    )
    .fetch_one(db)
    .await?)
}
