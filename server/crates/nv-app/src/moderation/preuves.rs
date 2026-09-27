//! **Sceller la preuve d'un signalement** (ex-déclencheur `scelle_la_preuve`).
//!
//! Un signalement fige ce qu'il vise : les fichiers (et leur clé) sont
//! retenus (`moderation_holds`) — ni leur auteur ni le balai des fichiers ne
//! peuvent plus les effacer — jusqu'à ce qu'il soit tranché. La LIBÉRATION,
//! elle, reste dans la base (`libere_la_preuve`, une fondation) : elle doit
//! voir tous les chemins, y compris la disparition d'un signalement par
//! cascade.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// Ce que vise un signalement.
pub enum Cible {
    /// Une story ou une publication (`content_reports`).
    Contenu(Uuid),
    /// Une Vibe d'un Drop (`library_vibe_reports`).
    VibeDuDrop(Uuid),
    /// Une Vibe envoyée (`card_reports`).
    VibeEnvoyee(Uuid),
    /// Une soirée : son affiche (`event_reports`).
    Soiree(Uuid),
}

/// Retient les fichiers visés par le signalement `rapport`.
pub async fn sceller(db: &mut PgConnection, rapport: Uuid, cible: Cible) -> NvResult<()> {
    match cible {
        Cible::Soiree(e) => {
            // L'affiche, en clair (faite pour être vue) : pas de clé.
            sqlx::query!(
                "insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
                 select 'event', $1, 'event_posters', e.poster_path, 0, false, null
                   from public.events e where e.id = $2 and e.poster_path is not null
                 on conflict do nothing",
                rapport,
                e
            )
            .execute(db)
            .await?;
        }
        Cible::VibeDuDrop(v) => {
            sqlx::query!(
                "insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
                 select 'drop_vibe', $1, 'library_vault', f.chemin, f.rang, f.video, k.media_key
                   from public.library_vibes v
                   left join public.library_vibe_keys k on k.vibe_id = v.id
                   cross join lateral (values (v.sealed_path, 0::smallint, v.front_is_video),
                                              (v.sealed_back_path, 1::smallint, v.back_is_video)) as f(chemin, rang, video)
                  where v.id = $2 and f.chemin is not null
                 on conflict do nothing",
                rapport,
                v
            )
            .execute(db)
            .await?;
        }
        Cible::VibeEnvoyee(c) => {
            sqlx::query!(
                "insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
                 select 'sent_vibe', $1, 'cards', f.chemin, f.rang, f.video, case when c.encrypted then k.media_key end
                   from public.cards c
                   left join public.card_media_keys k on k.card_id = c.id
                   cross join lateral (values (c.front_path, 0::smallint, c.front_is_video),
                                              (c.back_path, 1::smallint, c.back_is_video)) as f(chemin, rang, video)
                  where c.id = $2 and f.chemin is not null
                 on conflict do nothing",
                rapport,
                c
            )
            .execute(db)
            .await?;
        }
        Cible::Contenu(c) => {
            // Une story…
            sqlx::query!(
                "insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
                 select 'content', $1, 'stories', f.chemin, f.rang, f.video, case when s.encrypted then k.media_key end
                   from public.stories s
                   left join public.content_media_keys k on k.content_id = s.id
                   cross join lateral (values (s.front_path, 0::smallint, s.front_is_video),
                                              (s.back_path, 1::smallint, s.back_is_video)) as f(chemin, rang, video)
                  where s.id = $2 and f.chemin is not null
                 on conflict do nothing",
                rapport,
                c
            )
            .execute(&mut *db)
            .await?;
            // …ou une publication (ses faces).
            sqlx::query!(
                "insert into public.moderation_holds (report_kind, report_id, bucket_id, object_name, rang, is_video, media_key)
                 select 'content', $1, 'library', m.path, m.slot, m.is_video, k.media_key
                   from public.library_media m
                   left join public.content_media_keys k on k.content_id = m.item_id
                  where m.item_id = $2 and m.path is not null
                 on conflict do nothing",
                rapport,
                c
            )
            .execute(db)
            .await?;
        }
    }
    Ok(())
}
