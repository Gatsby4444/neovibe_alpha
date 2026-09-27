//! **L'administration** (docs/serveur-rust.md, annexe A.9) : réservée aux
//! comptes de `admins` — chaque geste est refusé à tout autre, et
//! journalisé (`moderation_actions`), y compris regarder une preuve.
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::args::{parse, NoArgs};
use nv_core::{ops, Ctx, NvError, NvResult};

use crate::acces::{self, q};
use crate::soirees::cuisine;

ops![
    am_i_admin => am_i_admin,
    admin_stats => admin_stats,
    admin_reports => admin_reports,
    admin_report_evidence => admin_report_evidence,
    admin_resolve_report => admin_resolve_report,
    admin_delete_content => admin_delete_content,
    admin_suspend_user => admin_suspend_user,
    admin_unsuspend_user => admin_unsuspend_user,
    admin_users => admin_users,
    admin_events => admin_events,
    admin_close_event => admin_close_event,
    admin_remove_event_poster => admin_remove_event_poster,
    admin_actions => admin_actions,
];

/// `private.assert_admin` : l'administrateur appelant, ou un refus.
async fn admin(ctx: &mut Ctx) -> NvResult<Uuid> {
    match ctx.actor.maybe_uid() {
        Some(m) if acces::est_admin(ctx.db(), m).await? => Ok(m),
        _ => Err(NvError::refused("Réservé à l'administration")),
    }
}

/// Une ligne du journal de modération (ex-`private.log_action`).
struct Geste<'a> {
    action: &'a str,
    compte: Option<Uuid>,
    contenu: Option<Uuid>,
    soiree: Option<Uuid>,
    genre: Option<&'a str>,
    rapport: Option<Uuid>,
    raison: Option<&'a str>,
}

async fn journaliser(db: &mut PgConnection, admin: Uuid, g: Geste<'_>) -> NvResult<()> {
    sqlx::query!(
        "insert into public.moderation_actions (admin_id, action, target_user, target_content, target_event, report_kind, report_id, reason)
         values ($1, $2, $3, $4, $5, $6, $7, $8)",
        admin,
        g.action,
        g.compte,
        g.contenu,
        g.soiree,
        g.genre,
        g.rapport,
        g.raison
    )
    .execute(db)
    .await?;
    Ok(())
}

/// `am_i_admin` : suis-je administrateur ?
async fn am_i_admin(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    parse::<NoArgs>(args)?;
    Ok(json!(match ctx.actor.maybe_uid() {
        Some(m) => acces::est_admin(ctx.db(), m).await?,
        None => false,
    }))
}

/// `admin_stats` : les chiffres du tableau de bord.
async fn admin_stats(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    admin(ctx).await?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select json_agg(t) as "j!" from (select
             (select count(*)::integer from public.profiles) as users,
             (select count(*)::integer from public.profiles where suspended_at is not null) as suspended,
             (select count(*)::integer from public.content_reports where status = 'open')
               + (select count(*)::integer from public.profile_reports where status = 'open') as open_reports,
             (select count(*)::integer from public.events where closed_at is null) as open_events,
             (select count(*)::integer from public.contents) as contents,
             (select count(*)::integer from public.moderation_actions where created_at > now() - interval '24 hours') as actions_24h) t"#
    )
    .fetch_one(ctx.db())
    .await?)
}

fn ouverts() -> Option<String> {
    Some("open".into())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rapports {
    #[serde(default = "ouverts")]
    p_status: Option<String>,
}

/// `admin_reports` : tous les signalements (d'un statut, ou tous), les plus
/// récents d'abord.
async fn admin_reports(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    admin(ctx).await?;
    let a: Rapports = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t order by t.created_at desc), '[]'::json) as "j!" from (
             select 'content' as kind, r.id, r.reason, r.details, r.status, r.created_at, r.reporter_id, rp.display_name as reporter_name,
                    c.owner_id as target_user, op.display_name as target_name, op.suspended_at is not null as target_suspended,
                    r.content_id, c.context::text as content_context, c.owner_id as content_owner
               from public.content_reports r
               join public.profiles rp on rp.id = r.reporter_id
               left join public.contents c on c.id = r.content_id
               left join public.profiles op on op.id = c.owner_id
              where $1::text is null or r.status = $1
             union all
             select 'profile', r.id, r.reason, r.details, r.status, r.created_at, r.reporter_id, rp.display_name,
                    r.target_id, tp.display_name, tp.suspended_at is not null, null, null, null
               from public.profile_reports r
               join public.profiles rp on rp.id = r.reporter_id
               join public.profiles tp on tp.id = r.target_id
              where $1::text is null or r.status = $1
             union all
             select 'drop_vibe', r.id, r.reason, r.details, r.status, r.created_at, r.reporter_id, rp.display_name,
                    r.author_id, ap.display_name, ap.suspended_at is not null,
                    r.vibe_id, case when r.vibe_id is null then null else 'drop' end, r.author_id
               from public.library_vibe_reports r
               join public.profiles rp on rp.id = r.reporter_id
               join public.profiles ap on ap.id = r.author_id
              where $1::text is null or r.status = $1
             union all
             select 'sent_vibe', r.id, r.reason, r.details, r.status, r.created_at, r.reporter_id, rp.display_name,
                    r.author_id, ap.display_name, ap.suspended_at is not null,
                    r.card_id, case when r.card_id is null then null else 'envoyée' end, r.author_id
               from public.card_reports r
               join public.profiles rp on rp.id = r.reporter_id
               join public.profiles ap on ap.id = r.author_id
              where $1::text is null or r.status = $1
             union all
             select 'event', r.id, r.reason, r.details, r.status, r.created_at, r.reporter_id, rp.display_name,
                    r.author_id, ap.display_name, ap.suspended_at is not null,
                    r.event_id, case when r.event_id is null then null else 'événement' end, r.author_id
               from public.event_reports r
               join public.profiles rp on rp.id = r.reporter_id
               join public.profiles ap on ap.id = r.author_id
              where $1::text is null or r.status = $1) t"#,
        a.p_status
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Preuve {
    p_kind: Option<String>,
    p_report: Uuid,
}

/// `admin_report_evidence` : les fichiers retenus d'un signalement (et
/// leurs clés). Regarder une preuve est un acte de modération : il se
/// journalise.
async fn admin_report_evidence(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: Preuve = parse(args)?;
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: "view_evidence",
            compte: None,
            contenu: None,
            soiree: None,
            genre: a.p_kind.as_deref(),
            rapport: Some(a.p_report),
            raison: None,
        },
    )
    .await?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t order by t.rang), '[]'::json) as "j!" from (
             select h.bucket_id, h.object_name, h.rang, h.is_video, h.media_key
               from public.moderation_holds h where h.report_kind = $1 and h.report_id = $2) t"#,
        a.p_kind,
        a.p_report
    )
    .fetch_one(ctx.db())
    .await?)
}

fn non() -> Option<bool> {
    Some(false)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Trancher {
    p_kind: Option<String>,
    p_report: Uuid,
    #[serde(default = "non")]
    p_dismiss: Option<bool>,
    #[serde(default)]
    p_note: Option<String>,
}

/// `admin_resolve_report` : trancher un signalement (ou l'écarter). La
/// preuve est libérée par la base (`libere_la_preuve`, une fondation).
async fn admin_resolve_report(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: Trancher = parse(args)?;
    let ecarte = a.p_dismiss == Some(true);
    let statut = if ecarte { "dismissed" } else { "resolved" };
    // (compte visé, contenu visé), s'il existe.
    let vise: Option<(Option<Uuid>, Option<Uuid>)> = match a.p_kind.as_deref() {
        Some("content") => sqlx::query_scalar!(
            "update public.content_reports set status = $2, resolved_at = now(), resolved_by = $3 where id = $1 returning content_id",
            a.p_report,
            statut,
            moi
        )
        .fetch_optional(ctx.db())
        .await?
        .map(|c| (None, Some(c))),
        Some("profile") => sqlx::query_scalar!(
            "update public.profile_reports set status = $2, resolved_at = now(), resolved_by = $3 where id = $1 returning target_id",
            a.p_report,
            statut,
            moi
        )
        .fetch_optional(ctx.db())
        .await?
        .map(|u| (Some(u), None)),
        Some("drop_vibe") => sqlx::query_scalar!(
            "update public.library_vibe_reports set status = $2, resolved_at = now(), resolved_by = $3 where id = $1 returning author_id",
            a.p_report,
            statut,
            moi
        )
        .fetch_optional(ctx.db())
        .await?
        .map(|u| (Some(u), None)),
        Some("sent_vibe") => sqlx::query_scalar!(
            "update public.card_reports set status = $2, resolved_at = now(), resolved_by = $3 where id = $1 returning author_id",
            a.p_report,
            statut,
            moi
        )
        .fetch_optional(ctx.db())
        .await?
        .map(|u| (Some(u), None)),
        Some("event") => sqlx::query_scalar!(
            "update public.event_reports set status = $2, resolved_at = now(), resolved_by = $3 where id = $1 returning author_id",
            a.p_report,
            statut,
            moi
        )
        .fetch_optional(ctx.db())
        .await?
        .map(|u| (Some(u), None)),
        _ => return Err(NvError::refused("kind : content, profile, drop_vibe, sent_vibe ou event")),
    };
    let Some((compte, contenu)) = vise else { return Err(NvError::refused("Signalement introuvable")) };
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: if ecarte { "dismiss_report" } else { "resolve_report" },
            compte,
            contenu,
            soiree: None,
            genre: a.p_kind.as_deref(),
            rapport: Some(a.p_report),
            raison: a.p_note.as_deref(),
        },
    )
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UnContenu {
    p_content: Uuid,
    p_reason: Option<String>,
}

/// `admin_delete_content` : retirer un contenu (et trancher ses
/// signalements).
async fn admin_delete_content(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: UnContenu = parse(args)?;
    let auteur = sqlx::query_scalar!("select owner_id from public.contents where id = $1", a.p_content)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Contenu introuvable"))?;
    sqlx::query!("delete from public.contents where id = $1", a.p_content).execute(ctx.db()).await?;
    sqlx::query!(
        "update public.content_reports set status = 'resolved', resolved_at = now(), resolved_by = $2 where content_id = $1 and status = 'open'",
        a.p_content,
        moi
    )
    .execute(ctx.db())
    .await?;
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: "delete_content",
            compte: Some(auteur),
            contenu: Some(a.p_content),
            soiree: None,
            genre: None,
            rapport: None,
            raison: a.p_reason.as_deref(),
        },
    )
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Suspendre {
    p_user: Uuid,
    p_reason: Option<String>,
}

/// `admin_suspend_user` : suspendre un compte (jamais le sien ni celui d'un
/// administrateur) ; il sort de toute soirée.
async fn admin_suspend_user(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: Suspendre = parse(args)?;
    if a.p_user == moi {
        return Err(NvError::refused("On ne se suspend pas soi-même"));
    }
    if acces::est_admin(ctx.db(), a.p_user).await? {
        return Err(NvError::refused("Un administrateur se retire d'abord de la liste"));
    }
    let n = sqlx::query!(
        "update public.profiles set suspended_at = now(), suspended_reason = $2 where id = $1",
        a.p_user,
        a.p_reason
    )
    .execute(ctx.db())
    .await?
    .rows_affected();
    if n == 0 {
        return Err(NvError::refused("Compte introuvable"));
    }
    sqlx::query!(
        "update public.event_presences set left_at = now(), left_reason = 'manual' where user_id = $1 and left_at is null",
        a.p_user
    )
    .execute(ctx.db())
    .await?;
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: "suspend_user",
            compte: Some(a.p_user),
            contenu: None,
            soiree: None,
            genre: None,
            rapport: None,
            raison: a.p_reason.as_deref(),
        },
    )
    .await?;
    Ok(Value::Null)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Lever {
    p_user: Uuid,
    #[serde(default)]
    p_note: Option<String>,
}

/// `admin_unsuspend_user` : lever une suspension.
async fn admin_unsuspend_user(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: Lever = parse(args)?;
    let n = sqlx::query!("update public.profiles set suspended_at = null, suspended_reason = null where id = $1", a.p_user)
        .execute(ctx.db())
        .await?
        .rows_affected();
    if n == 0 {
        return Err(NvError::refused("Compte introuvable"));
    }
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: "unsuspend_user",
            compte: Some(a.p_user),
            contenu: None,
            soiree: None,
            genre: None,
            rapport: None,
            raison: a.p_note.as_deref(),
        },
    )
    .await?;
    Ok(Value::Null)
}

fn cinquante() -> Option<i32> {
    Some(50)
}

/// `greatest(1, least(limite, 500))` — `least` ignore un `null`.
fn limite(l: Option<i32>) -> i64 {
    i64::from(l.map_or(500, |l| l.min(500)).max(1))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Comptes {
    #[serde(default)]
    p_query: Option<String>,
    #[serde(default = "cinquante")]
    p_limit: Option<i32>,
}

/// `admin_users` : les comptes (recherche dans le nom et le pseudo), les
/// plus récents d'abord.
async fn admin_users(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    admin(ctx).await?;
    let a: Comptes = parse(args)?;
    let sql = format!(
        "select coalesce(json_agg(t order by t.created_at desc), '[]'::json) from (
           select p.id, p.display_name, p.tag_name, p.created_at, p.suspended_at, p.suspended_reason,
                  (select count(*)::integer from public.profile_reports r where r.target_id = p.id) as reports,
                  {} as is_admin
             from public.profiles p
            where $1::text is null or p.display_name ilike '%' || $1 || '%' or p.tag_name ilike '%' || $1 || '%'
            order by p.created_at desc
            limit $2) t",
        q::est_admin("p.id")
    );
    Ok(sqlx::query_scalar::<_, Value>(&sql).bind(a.p_query).bind(limite(a.p_limit)).fetch_one(ctx.db()).await?)
}

/// `admin_events` : les soirées ouvertes, les plus récemment ouvertes
/// d'abord.
async fn admin_events(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    admin(ctx).await?;
    parse::<NoArgs>(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t order by t.opened_at desc nulls last), '[]'::json) as "j!" from (
             select e.id, e.kind, e.title, e.auto_created, e.created_by, p.display_name as creator_name, e.opened_at, e.scheduled_end_at,
                    (select count(*)::integer from public.event_presences x where x.event_id = e.id and x.left_at is null) as present_count,
                    (select count(*)::integer from public.library_vibes v where v.conversation_id = e.conversation_id) as vibe_count
               from public.events e left join public.profiles p on p.id = e.created_by
              where e.closed_at is null) t"#
    )
    .fetch_one(ctx.db())
    .await?)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UneSoiree {
    p_event: Uuid,
    p_reason: Option<String>,
}

/// `admin_close_event` : fermer une soirée.
async fn admin_close_event(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: UneSoiree = parse(args)?;
    cuisine::fermer(ctx.db(), a.p_event, "admin").await?;
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: "close_event",
            compte: None,
            contenu: None,
            soiree: Some(a.p_event),
            genre: None,
            rapport: None,
            raison: a.p_reason.as_deref(),
        },
    )
    .await?;
    Ok(Value::Null)
}

/// `admin_remove_event_poster` : retirer l'affiche ET la description d'une
/// soirée (son « profil » public).
async fn admin_remove_event_poster(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    let moi = admin(ctx).await?;
    let a: UneSoiree = parse(args)?;
    let affiche = sqlx::query_scalar!("select poster_path from public.events where id = $1", a.p_event)
        .fetch_optional(ctx.db())
        .await?
        .ok_or_else(|| NvError::refused("Soirée introuvable"))?;
    sqlx::query!("update public.events set poster_path = null, description = null where id = $1", a.p_event)
        .execute(ctx.db())
        .await?;
    if let Some(vieille) = affiche {
        cuisine::oublier_l_affiche(ctx.db(), &vieille).await?;
    }
    journaliser(
        ctx.db(),
        moi,
        Geste {
            action: "remove_poster",
            compte: None,
            contenu: None,
            soiree: Some(a.p_event),
            genre: None,
            rapport: None,
            raison: a.p_reason.as_deref(),
        },
    )
    .await?;
    Ok(Value::Null)
}

fn cent() -> Option<i32> {
    Some(100)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    #[serde(default = "cent")]
    p_limit: Option<i32>,
}

/// `admin_actions` : le journal de modération, le plus récent d'abord.
async fn admin_actions(ctx: &mut Ctx, args: Value) -> NvResult<Value> {
    admin(ctx).await?;
    let a: Journal = parse(args)?;
    Ok(sqlx::query_scalar!(
        r#"select coalesce(json_agg(t order by t.created_at desc), '[]'::json) as "j!" from (
             select a.id, ap.display_name as admin_name, a.action, a.target_user, tp.display_name as target_name,
                    a.target_content, a.target_event, a.reason, a.created_at
               from public.moderation_actions a
               join public.profiles ap on ap.id = a.admin_id
               left join public.profiles tp on tp.id = a.target_user
              order by a.created_at desc
              limit $1) t"#,
        limite(a.p_limit)
    )
    .fetch_one(ctx.db())
    .await?)
}
