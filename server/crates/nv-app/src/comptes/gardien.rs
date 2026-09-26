//! Les règles des comptes et des profils.

/// Un nom d'utilisateur a la bonne forme : 3 à 20 caractères parmi
/// `a-z`, `0-9`, `.` et `_` (l'ancienne expression `^[a-z0-9._]{3,20}$`).
pub fn username_bien_forme(nom: &str) -> bool {
    let n = nom.chars().count();
    (3..=20).contains(&n)
        && nom.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '_')
}

#[cfg(test)]
mod tests {
    use super::username_bien_forme;

    #[test]
    fn la_forme_d_un_nom() {
        assert!(username_bien_forme("charles"));
        assert!(username_bien_forme("a.b_9"));
        assert!(!username_bien_forme("ab"));
        assert!(!username_bien_forme("Charles"));
        assert!(!username_bien_forme("jean-luc"));
        assert!(!username_bien_forme("é_x"));
        assert!(!username_bien_forme(&"a".repeat(21)));
        assert!(username_bien_forme(&"a".repeat(20)));
    }
}
