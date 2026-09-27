//! **Autour de moi** — la règle partagée par le fil (Pulse, « autour de
//! moi ») et par la carte (ex-`private.vibes_autour` et
//! `private.distance_m`). Écrite une seule fois, ici.
use crate::acces::q;

/// **La distance en mètres** entre deux points (grand cercle, rayon
/// terrestre 6 371 km) — une expression SQL, calculée par la base avec ses
/// fonctions, au dernier chiffre près comme avant.
///
/// L'ancien gardien en avait DEUX copies : `private.distance_m` (le fil, la
/// carte) et `private.meters_between` (les soirées), qui ne différaient que
/// par la borne `least(1, …)` — sans effet hors des points antipodes (plus de
/// 20 000 km). Il n'y en a plus qu'une, la plus sûre des deux.
pub fn distance_m(lat1: &str, lng1: &str, lat2: &str, lng2: &str) -> String {
    format!(
        "(2 * 6371000 * asin(least(1, sqrt(power(sin(radians({lat2} - {lat1}) / 2), 2) \
         + cos(radians({lat1})) * cos(radians({lat2})) * power(sin(radians({lng2} - {lng1}) / 2), 2)))))"
    )
}

/// Les Vibes publiques et localisées à moins de `rayon` mètres de
/// (`lat`, `lng`), publiées après `depuis` — ni retirées, ni d'un compte qui
/// m'a bloqué ou que j'ai bloqué. Une sous-requête SQL qui rend
/// `(id, owner_id, kind, lat, lng, created_at)` ; aucune ligne si la
/// position manque.
///
/// La boîte englobante du rayon filtre d'abord (l'index), la distance exacte
/// ensuite.
pub fn vibes_autour(moi: &str, lat: &str, lng: &str, rayon: &str, depuis: &str) -> String {
    format!(
        "select va_li.id, va_li.owner_id, va_li.kind, va_c.anchor_lat as lat, va_c.anchor_lng as lng, va_li.created_at
           from public.library_items va_li join public.contents va_c on va_c.id = va_li.id
          where {lat} is not null and {lng} is not null
            and va_li.is_public and va_c.anchor_lat is not null
            and va_c.anchor_lat between {lat} - ({rayon}) / 111320.0 and {lat} + ({rayon}) / 111320.0
            and va_c.anchor_lng between {lng} - ({rayon}) / (111320.0 * greatest(cos(radians({lat})), 0.01))
                                    and {lng} + ({rayon}) / (111320.0 * greatest(cos(radians({lat})), 0.01))
            and {dist} <= {rayon}
            and va_li.created_at > {depuis}
            and not {revoque} and not {bloque}",
        dist = distance_m(lat, lng, "va_c.anchor_lat", "va_c.anchor_lng"),
        revoque = q::est_revoque("va_li.id"),
        bloque = q::est_bloque("va_li.owner_id", moi),
    )
}
