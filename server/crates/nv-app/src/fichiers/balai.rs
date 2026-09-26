//! **Le balai des fichiers** : efface de l'entrepôt les fichiers dont le
//! délai de grâce est passé (les « pierres tombales » posées par la base
//! quand un contenu disparaît), sauf ceux que la modération retient.
//!
//! Avant, c'était l'app de chaque propriétaire qui faisait ce ménage, à son
//! ouverture : les octets d'un compte qui ne rouvrait jamais l'app restaient
//! pour toujours (RAPPELS #111). Le serveur le fait désormais lui-même.
use std::collections::BTreeMap;

use sqlx::PgConnection;

use nv_core::fichiers::Entrepot;
use nv_core::NvResult;

/// Combien de fichiers au plus par passage.
const PAR_PASSAGE: i64 = 500;

/// Un passage du balai ; rend ce qu'il a fait.
pub async fn balayer(db: &mut PgConnection, entrepot: &dyn Entrepot) -> NvResult<String> {
    let lignes = sqlx::query!(
        r#"select t.bucket_id as "bucket!", t.object_name as "name!"
             from public.storage_tombstones t
            where t.delete_after <= now()
              and not exists (select 1 from public.moderation_holds h
                               where h.bucket_id = t.bucket_id and h.object_name = t.object_name)
            order by t.delete_after
            limit $1"#,
        PAR_PASSAGE
    )
    .fetch_all(&mut *db)
    .await?;
    let mut par_coffre: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for l in lignes {
        par_coffre.entry(l.bucket).or_default().push(l.name);
    }
    let mut total = 0usize;
    for (coffre, noms) in par_coffre {
        // D'abord l'entrepôt, ensuite la ligne : si l'effacement échoue, la
        // pierre tombale reste et le prochain passage réessaie.
        entrepot.supprimer(&coffre, noms.clone()).await?;
        sqlx::query!(
            "delete from public.storage_tombstones where bucket_id = $1 and object_name = any($2)",
            coffre,
            &noms
        )
        .execute(&mut *db)
        .await?;
        total += noms.len();
    }
    Ok(format!("{total} fichier(s) effacé(s)"))
}
