//! **Les questions d'accès** — « l'un a-t-il bloqué l'autre ? », « peut-il
//! voir ce profil, cette publication, ce fichier ? ».
//!
//! Chaque question est la traduction d'une fonction de l'ancien gardien SQL
//! (nommée dans son commentaire) et n'est écrite **qu'une fois, ici, en
//! Rust**. Elles s'emboîtent comme dans l'ancien gardien : une question
//! composée appelle les questions simples.
//!
//! Chaque question est une fonction qui rend une **expression SQL
//! booléenne** ; ses arguments sont des expressions (un paramètre `$1::uuid`,
//! une colonne `x.owner_id`), jamais une valeur venue de l'app — les
//! valeurs sont toujours passées en paramètres liés. Ainsi une liste entière
//! se filtre en UNE requête, et une question simple s'évalue avec [`vrai`].
//!
//! ⚠️ Chaque question nomme ses tables avec un alias qui lui est propre
//! (`bl_`, `ap_`…) : une expression reçue en argument (`ap_.owner_id`) ne peut
//! pas être capturée par un alias intérieur.
use sqlx::PgConnection;
use uuid::Uuid;

use nv_core::NvResult;

/// Les questions, sous forme d'expressions SQL composables.
pub mod q {
    /// `private.is_blocked(a, b)` : l'un des deux a bloqué l'autre.
    pub fn est_bloque(a: &str, b: &str) -> String {
        format!(
            "exists (select 1 from public.blocks bl_ where (bl_.blocker_id = {a} and bl_.blocked_id = {b}) \
             or (bl_.blocker_id = {b} and bl_.blocked_id = {a}))"
        )
    }

    /// `private.a_bloque(qui, cible)` : `qui` a bloqué `cible`.
    pub fn a_bloque(qui: &str, cible: &str) -> String {
        format!("exists (select 1 from public.blocks ab_ where ab_.blocker_id = {qui} and ab_.blocked_id = {cible})")
    }

    /// `private.has_any_connection(a, b)` : un lien existe, quel que soit
    /// son statut.
    pub fn a_un_lien(a: &str, b: &str) -> String {
        format!(
            "exists (select 1 from public.connections hl_ where hl_.user_low = least({a}, {b}) \
             and hl_.user_high = greatest({a}, {b}))"
        )
    }

    /// `private.are_connected(a, b)` : amis (lien établi, `full`).
    pub fn sont_amis(a: &str, b: &str) -> String {
        format!(
            "exists (select 1 from public.connections ac_ where ac_.user_low = least({a}, {b}) \
             and ac_.user_high = greatest({a}, {b}) and ac_.status = 'full')"
        )
    }

    /// `private.friendship_tier(a, b)` : le palier d'amitié (une valeur, pas
    /// une question ; `null` s'ils ne sont pas amis).
    pub fn palier(a: &str, b: &str) -> String {
        format!(
            "(select pa_.tier from public.connections pa_ where pa_.user_low = least({a}, {b}) \
             and pa_.user_high = greatest({a}, {b}) and pa_.status = 'full')"
        )
    }

    /// `private.can_view_profile(lecteur, cible)`.
    ///
    /// ⚠️ `a_bloque(cible, lecteur)` et non `est_bloque` : la cible s'est
    /// retirée de la vue du lecteur ; l'inverse ne se déduit pas. Celui qu'on
    /// a bloqué reste consultable (pour pouvoir le débloquer).
    pub fn peut_voir_profil(v: &str, t: &str) -> String {
        format!(
            "({v} = {t} or (not {pas_bloque_par_cible} and ({lien} \
             or exists (select 1 from public.encounters pv_e where pv_e.user_low = least({v}, {t}) and pv_e.user_high = greatest({v}, {t})) \
             or exists (select 1 from public.conversation_members pv_m1 join public.conversation_members pv_m2 using (conversation_id) \
                        where pv_m1.user_id = {v} and pv_m2.user_id = {t}) \
             or exists (select 1 from public.connection_requests pv_r where (pv_r.sender_id = {v} and pv_r.receiver_id = {t}) \
                        or (pv_r.sender_id = {t} and pv_r.receiver_id = {v})) \
             or exists (select 1 from public.recommendations pv_c where (pv_c.intermediary_id = {v} and (pv_c.requester_id = {t} or pv_c.target_id = {t})) \
                        or (pv_c.requester_id = {v} and pv_c.intermediary_id = {t}) \
                        or (pv_c.target_id = {v} and pv_c.intermediary_id = {t}) \
                        or (pv_c.requester_id = {v} and pv_c.target_id = {t} and pv_c.status = 'accepted') \
                        or (pv_c.target_id = {v} and pv_c.requester_id = {t} and pv_c.status in ('forwarded', 'accepted'))) \
             or {j_ai_bloque})))",
            pas_bloque_par_cible = a_bloque(t, v),
            lien = a_un_lien(v, t),
            j_ai_bloque = a_bloque(v, t),
        )
    }

    /// `private.can_view_library(propriétaire, lecteur)`.
    pub fn peut_voir_bibliotheque(owner: &str, viewer: &str) -> String {
        format!(
            "({owner} = {viewer} or (not {bloque} and exists (select 1 from public.profiles vb_ where vb_.id = {owner} \
             and ((vb_.library_visibility = 'connections' and {amis}) \
                  or (vb_.library_visibility = 'restricted' and exists (select 1 from public.library_access vb_la \
                      where vb_la.owner_id = {owner} and vb_la.grantee_id = {viewer}))))))",
            bloque = est_bloque(owner, viewer),
            amis = sont_amis(owner, viewer),
        )
    }

    /// `private.fenetre_croisement(origine)` : combien de temps un
    /// croisement compte, selon son origine (`ping`, `event`, `meeting`).
    pub fn fenetre(origine: &'static str) -> String {
        format!("(select cw_.fenetre from public.crossing_windows cw_ where cw_.origin = '{origine}')")
    }

    /// `private.crossed_within_window(a, b)` : croisés récemment (ping ou
    /// soirée), chacun dans sa fenêtre.
    pub fn croises_recemment(a: &str, b: &str) -> String {
        format!(
            "(exists (select 1 from public.ping_pairs cr_pp where cr_pp.user_low = least({a}, {b}) and cr_pp.user_high = greatest({a}, {b}) \
               and cr_pp.last_seen_at > now() - {fp}) \
             or exists (select 1 from public.event_crossings cr_ec where cr_ec.user_low = least({a}, {b}) and cr_ec.user_high = greatest({a}, {b}) \
               and cr_ec.last_at > now() - {fe}))",
            fp = fenetre("ping"),
            fe = fenetre("event"),
        )
    }

    /// `private.feed_added_to(contenu, compte)` : un ami (non bloqué) l'a
    /// ajouté à mon fil.
    pub fn ajoute_au_fil(c: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.feed_adds fa_ where fa_.content_id = {c} and fa_.recipient_id = {uid} \
             and not {bloque})",
            bloque = est_bloque("fa_.adder_id", uid)
        )
    }

    /// `private.is_revoked(contenu)`.
    pub fn est_revoque(c: &str) -> String {
        format!("exists (select 1 from public.contents rv_ where rv_.id = {c} and rv_.revoked_at is not null)")
    }

    /// `private.publication_audience(publication, compte)`.
    pub fn audience_publication(item: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.library_items ap_ where ap_.id = {item} and not {revoque} and (ap_.owner_id = {uid} \
             or (not {bloque} and ({biblio} \
                 or (ap_.is_public and {profil}) \
                 or (ap_.is_public and {croises}) \
                 or (ap_.is_public and exists (select 1 from public.contents ap_c where ap_c.id = ap_.id and ap_c.anchor_lat is not null)) \
                 or {fil} \
                 or exists (select 1 from public.content_grants ap_g where ap_g.content_id = ap_.id and ap_g.grantee_id = {uid} \
                            and not {bloque_relais})))))",
            revoque = est_revoque("ap_.id"),
            bloque = est_bloque("ap_.owner_id", uid),
            biblio = peut_voir_bibliotheque("ap_.owner_id", uid),
            profil = peut_voir_profil(uid, "ap_.owner_id"),
            croises = croises_recemment("ap_.owner_id", uid),
            fil = ajoute_au_fil("ap_.id", uid),
            bloque_relais = est_bloque("ap_g.granted_by", uid),
        )
    }

    /// `private.can_view_stories(propriétaire, lecteur)`.
    pub fn peut_voir_stories(owner: &str, viewer: &str) -> String {
        format!(
            "({owner} = {viewer} or (not {bloque} and ({amis} or exists (select 1 from public.profiles vs_ where vs_.id = {owner} \
             and vs_.stories_public and exists (select 1 from public.encounters vs_e \
               where ((vs_e.user_low = {owner} and vs_e.user_high = {viewer}) or (vs_e.user_low = {viewer} and vs_e.user_high = {owner})) \
               and vs_e.last_seen_at > now() - interval '24 hours')))))",
            bloque = est_bloque(owner, viewer),
            amis = sont_amis(owner, viewer),
        )
    }

    /// `private.story_audience(story, compte)`.
    pub fn audience_story(story: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.stories as_ where as_.id = {story} and as_.expires_at > now() and not {revoque} \
             and (as_.owner_id = {uid} or (not {bloque} \
                  and (as_.min_tier = 'friend' or {palier} >= as_.min_tier) \
                  and ({stories} or exists (select 1 from public.content_grants as_g where as_g.content_id = as_.id \
                       and as_g.grantee_id = {uid} and not {bloque_relais})))))",
            revoque = est_revoque("as_.id"),
            bloque = est_bloque("as_.owner_id", uid),
            palier = palier("as_.owner_id", uid),
            stories = peut_voir_stories("as_.owner_id", uid),
            bloque_relais = est_bloque("as_g.granted_by", uid),
        )
    }

    /// `private.can_view_card_file(chemin, compte)`.
    pub fn peut_voir_fichier_carte(path: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.cards vc_ where (vc_.front_path = {path} or vc_.back_path = {path}) \
             and (vc_.owner_id = {uid} or exists (select 1 from public.card_deliveries vc_d where vc_d.card_id = vc_.id \
                  and vc_d.recipient_id = {uid} and vc_d.destroyed_at is null)))"
        )
    }

    /// `private.can_view_publication_file(chemin, compte)`.
    pub fn peut_voir_fichier_publication(path: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.library_media vp_ where (vp_.path = {path} or vp_.poster_path = {path}) and {aud})",
            aud = audience_publication("vp_.item_id", uid)
        )
    }

    /// `private.can_view_story_file(chemin, compte)`.
    pub fn peut_voir_fichier_story(path: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.stories vfs_ where (vfs_.front_path = {path} or vfs_.back_path = {path}) and {aud})",
            aud = audience_story("vfs_.id", uid)
        )
    }

    /// `private.is_event_member(soirée, compte)`.
    pub fn membre_evenement(e: &str, uid: &str) -> String {
        format!("exists (select 1 from public.event_group_members me_ where me_.event_id = {e} and me_.user_id = {uid})")
    }

    /// `private.can_see_event(soirée, compte)`.
    pub fn peut_voir_evenement(e: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.events ve_ where ve_.id = {e} and {uid} is not null and case ve_.kind \
             when 'private' then {membre} or ve_.created_by = {uid} when 'open' then true when 'venue' then true else false end)",
            membre = membre_evenement("ve_.id", uid)
        )
    }

    /// `private.concerned_by_event(soirée, compte)` : membre, présent, ou
    /// gérant du lieu.
    pub fn concerne_evenement(e: &str, uid: &str) -> String {
        format!(
            "({membre} or exists (select 1 from public.event_presences ce_p where ce_p.event_id = {e} and ce_p.user_id = {uid}) \
             or exists (select 1 from public.events ce_e where ce_e.id = {e} and {lieu}))",
            membre = membre_evenement(e, uid),
            lieu = gere_lieu("ce_e.venue_id", uid)
        )
    }

    /// `private.relation_kind(moi, autre)` : ce que l'autre est pour moi —
    /// `friend`, `event` (co-présent d'une soirée ouverte, ou membre d'un
    /// même groupe de soirée privée ouverte), ou rien. Une VALEUR (texte),
    /// `null` s'il n'est rien — ou s'il m'a bloqué.
    pub fn relation(moi: &str, autre: &str) -> String {
        format!(
            "(case when {moi} is null or {autre} is null or {moi} = {autre} then null                when {bloque} then null                when {amis} then 'friend'                when exists (select 1 from public.event_presences rk_a join public.event_presences rk_b on rk_b.event_id = rk_a.event_id                             join public.events rk_e on rk_e.id = rk_a.event_id                             where rk_a.user_id = {moi} and rk_b.user_id = {autre} and rk_a.left_at is null and rk_b.left_at is null                               and rk_e.closed_at is null) then 'event'                when exists (select 1 from public.event_group_members rk_ga join public.event_group_members rk_gb on rk_gb.event_id = rk_ga.event_id                             join public.events rk_ge on rk_ge.id = rk_ga.event_id                             where rk_ga.user_id = {moi} and rk_gb.user_id = {autre} and rk_ge.kind = 'private' and rk_ge.closed_at is null) then 'event'                else null end)",
            bloque = a_bloque(autre, moi),
            amis = sont_amis(moi, autre),
        )
    }

    /// `private.can_write_in_conversation(conversation, compte)` : une soirée
    /// terminée ferme son chat ; un groupe reste ouvert ; ailleurs, un blocage
    /// ferme ; un canal de proximité ne vit que 3 minutes après le dernier
    /// ping mutuel. `null` si la conversation n'existe pas.
    pub fn peut_ecrire_conversation(conv: &str, uid: &str) -> String {
        format!(
            "(select case \
               when we_c.conversation_type = 'event' then not exists (select 1 from public.events we_e \
                    where we_e.conversation_id = we_c.id and we_e.closed_at is not null) \
               when we_c.conversation_type = 'group' then true \
               when exists (select 1 from public.conversation_members we_a where we_a.conversation_id = we_c.id \
                    and we_a.user_id <> {uid} and {bloque}) then false \
               when we_c.conversation_type <> 'proximity' then true \
               else exists (select 1 from public.conversation_members we_b join public.ping_pairs we_pp \
                    on (we_pp.user_low = least({uid}, we_b.user_id) and we_pp.user_high = greatest({uid}, we_b.user_id)) \
                    where we_b.conversation_id = we_c.id and we_b.user_id <> {uid} \
                      and we_pp.last_seen_at > now() - interval '3 minutes') \
             end from public.conversations we_c where we_c.id = {conv})",
            bloque = est_bloque(uid, "we_a.user_id")
        )
    }

    /// `private.owns_card(carte, compte)`.
    pub fn possede_carte(c: &str, uid: &str) -> String {
        format!("exists (select 1 from public.cards oc_ where oc_.id = {c} and oc_.owner_id = {uid})")
    }

    /// `private.manages_venue(lieu, compte)`.
    pub fn gere_lieu(v: &str, uid: &str) -> String {
        format!("exists (select 1 from public.venue_managers gl_ where gl_.venue_id = {v} and gl_.user_id = {uid})")
    }

    /// `private.may_manage_event(soirée, compte)`.
    pub fn gere_evenement(e: &str, uid: &str) -> String {
        format!(
            "exists (select 1 from public.events ge_ where ge_.id = {e} and case ge_.kind when 'venue' then {lieu} \
             when 'private' then ge_.created_by = {uid} when 'open' then ge_.created_by = {uid} else false end)",
            lieu = gere_lieu("ge_.venue_id", uid)
        )
    }

    /// `private.may_manage_event_open(soirée, compte)` : l'organisateur,
    /// pendant que la soirée est ouverte.
    pub fn gere_evenement_ouvert(e: &str, uid: &str) -> String {
        format!(
            "({e} is not null and {gere} and exists (select 1 from public.events geo_ where geo_.id = {e} and geo_.closed_at is null))",
            gere = gere_evenement(e, uid)
        )
    }

    /// `private.is_conversation_member(conversation, compte)`.
    pub fn membre_conversation(c: &str, uid: &str) -> String {
        format!("exists (select 1 from public.conversation_members mc_ where mc_.conversation_id = {c} and mc_.user_id = {uid})")
    }

    /// `private.is_admin(compte)`.
    pub fn est_admin(uid: &str) -> String {
        format!("exists (select 1 from public.admins ad_ where ad_.user_id = {uid})")
    }

    /// `private.is_held(coffre, nom)` : un fichier retenu par la modération
    /// (la preuve d'un signalement) — on ne l'efface pas.
    pub fn retenu(bucket: &str, name: &str) -> String {
        format!("exists (select 1 from public.moderation_holds mh_ where mh_.bucket_id = {bucket} and mh_.object_name = {name})")
    }
}

/// Une valeur liée à une question.
#[derive(Debug, Clone)]
pub enum P {
    U(Uuid),
    T(String),
}

/// Évalue une question (une expression SQL booléenne) ; `null` compte pour
/// « non », comme dans une règle d'accès.
pub async fn vrai(db: &mut PgConnection, expr: &str, params: &[P]) -> NvResult<bool> {
    let sql = format!("select coalesce({expr}, false)");
    let mut req = sqlx::query_scalar::<_, bool>(&sql);
    for p in params {
        req = match p {
            P::U(u) => req.bind(*u),
            P::T(t) => req.bind(t.clone()),
        };
    }
    Ok(req.fetch_one(db).await?)
}

/// **La suspension** (ex-`private.assert_not_suspended` et déclencheur
/// `refuse_si_suspendu`) : un compte suspendu ne crée plus rien — ni
/// contenu, ni soirée, ni relation. Chaque porte qui crée appelle CETTE
/// vérification ; elle n'est écrite qu'ici.
pub async fn refuser_si_suspendu(db: &mut PgConnection, moi: Uuid) -> NvResult<()> {
    let suspendu = sqlx::query_scalar!(
        r#"select exists (select 1 from public.profiles
                           where id = $1 and suspended_at is not null) as "b!""#,
        moi
    )
    .fetch_one(db)
    .await?;
    if suspendu {
        return Err(nv_core::NvError::refused("Ton compte est suspendu"));
    }
    Ok(())
}

/// `private.a_bloque(qui, cible)`.
pub async fn a_bloque(db: &mut PgConnection, qui: Uuid, cible: Uuid) -> NvResult<bool> {
    vrai(db, &q::a_bloque("$1::uuid", "$2::uuid"), &[P::U(qui), P::U(cible)]).await
}

/// `private.is_blocked(a, b)`.
pub async fn is_blocked(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<bool> {
    vrai(db, &q::est_bloque("$1::uuid", "$2::uuid"), &[P::U(a), P::U(b)]).await
}

/// `private.are_connected(a, b)`.
pub async fn sont_amis(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<bool> {
    vrai(db, &q::sont_amis("$1::uuid", "$2::uuid"), &[P::U(a), P::U(b)]).await
}

/// `private.has_any_connection(a, b)`.
pub async fn has_any_connection(db: &mut PgConnection, a: Uuid, b: Uuid) -> NvResult<bool> {
    vrai(db, &q::a_un_lien("$1::uuid", "$2::uuid"), &[P::U(a), P::U(b)]).await
}

/// `private.is_conversation_member(conversation, compte)`.
pub async fn membre_conversation(db: &mut PgConnection, conv: Uuid, uid: Uuid) -> NvResult<bool> {
    vrai(db, &q::membre_conversation("$1::uuid", "$2::uuid"), &[P::U(conv), P::U(uid)]).await
}

/// `private.is_admin(compte)`.
pub async fn est_admin(db: &mut PgConnection, uid: Uuid) -> NvResult<bool> {
    vrai(db, &q::est_admin("$1::uuid"), &[P::U(uid)]).await
}

/// `private.can_view_profile(lecteur, cible)`.
pub async fn can_view_profile(db: &mut PgConnection, viewer: Uuid, target: Uuid) -> NvResult<bool> {
    vrai(db, &q::peut_voir_profil("$1::uuid", "$2::uuid"), &[P::U(viewer), P::U(target)]).await
}

/// Parmi `cibles`, les profils que `viewer` peut voir (la même question,
/// pour une liste entière, en une requête).
pub async fn profils_visibles(db: &mut PgConnection, viewer: Uuid, cibles: &[Uuid]) -> NvResult<Vec<Uuid>> {
    let sql = format!(
        "select t.id from unnest($2::uuid[]) as t(id) where {}",
        q::peut_voir_profil("$1::uuid", "t.id")
    );
    Ok(sqlx::query_scalar::<_, Uuid>(&sql).bind(viewer).bind(cibles).fetch_all(db).await?)
}

#[cfg(test)]
mod tests {
    use super::q;

    /// Aucune question n'emploie l'alias d'une autre : une expression reçue
    /// en argument ne peut pas être capturée (voir l'en-tête du module).
    #[test]
    fn les_questions_s_emboitent_sans_capture() {
        let e = q::audience_publication("$1::uuid", "$2::uuid");
        assert!(e.contains("public.library_items ap_"));
        assert!(e.contains("ap_g.granted_by"));
        let s = q::audience_story("x.id", "$1::uuid");
        assert!(s.contains("as_g.granted_by"));
    }
}
