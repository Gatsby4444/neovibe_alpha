//! Les constantes et les petites règles du ping et des paliers — autrefois
//! des fonctions SQL « immuables » (`private.slot_seconds()`…), maintenant
//! des constantes du programme.

/// `private.ping_cell_size()` : la taille d'un carreau (en degrés).
pub const TAILLE_CARREAU: f64 = 0.01;
/// `private.ping_beacon_ttl()` : une balise vit 5 minutes.
pub const VIE_BALISE: &str = "interval '5 minutes'";
/// `private.slot_seconds()` : un créneau de ping dure 15 minutes.
pub const CRENEAU_S: i64 = 900;
/// `private.fenetre_rencontre()` : 10 minutes pour se demander en ami après
/// un ping mutuel.
pub const FENETRE_RENCONTRE: &str = "interval '10 minutes'";
/// `private.meeting_window_days()` : les jours de rencontre comptent 30 jours.
pub const FENETRE_PALIERS_JOURS: i32 = 30;
/// `private.tier_close_days()` : 5 jours pour « proche ».
pub const JOURS_PROCHE: i32 = 5;
/// `private.tier_inner_days()` : 15 jours pour « intime ».
pub const JOURS_INTIME: i32 = 15;
/// `private.streak_tolerance_days()` : 2 jours sans se voir ne cassent pas une série.
pub const TOLERANCE_SERIE_JOURS: i32 = 2;
/// Le plafond mensuel des mises en relation d'un intermédiaire.
pub const PLAFOND_RECOMMANDATIONS_MOIS: i64 = 10;

/// Le créneau courant (secondes depuis 1970 / 900).
pub fn creneau(epoch_s: i64) -> i64 {
    epoch_s.div_euclid(CRENEAU_S)
}

/// `private.ping_plausible(…)` : deux carreaux voisins (ou le même).
pub fn plausible(a: (i32, i32), b: (i32, i32)) -> bool {
    (a.0 - b.0).abs() <= 1 && (a.1 - b.1).abs() <= 1
}

/// Le carreau d'une coordonnée.
pub fn carreau(deg: f64) -> i32 {
    (deg / TAILLE_CARREAU).floor() as i32
}

/// `private.tier_for_days(d)`.
pub fn palier_pour(jours: i32) -> &'static str {
    if jours >= JOURS_INTIME {
        "inner"
    } else if jours >= JOURS_PROCHE {
        "close"
    } else {
        "friend"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_petites_regles() {
        assert_eq!(creneau(1800), 2);
        assert_eq!(creneau(899), 0);
        assert!(plausible((10, 10), (11, 9)));
        assert!(!plausible((10, 10), (12, 10)));
        assert_eq!(carreau(50.6368), 5063);
        assert_eq!(carreau(-0.001), -1);
        assert_eq!(palier_pour(0), "friend");
        assert_eq!(palier_pour(5), "close");
        assert_eq!(palier_pour(15), "inner");
    }
}
