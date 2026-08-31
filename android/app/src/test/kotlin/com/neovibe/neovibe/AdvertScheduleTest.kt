package com.neovibe.neovibe

import com.neovibe.neovibe.ble.AdvertSchedule
import com.neovibe.neovibe.ble.BleConstants
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Ce que ces tests protegent : **le creneau entier, pas un jeton a la fois**.
 *
 * Le service emettait un seul jeton par tour de cycle, toutes les 400 ms. Avec
 * dix amis, le jeton de chacun n'etait donc en l'air que 10 % du temps :
 * quelqu'un qu'on croise trois secondes dans un couloir pouvait n'etre **jamais**
 * vu, et le defaut s'aggravait avec le nombre d'amis. Rien ne le levait.
 *
 * `tokensAt` rend tout le creneau d'un coup, ce qui permet au moteur d'emettre
 * les jetons **simultanement**. L'invariant a tenir est donc celui-ci : le
 * creneau entier doit contenir exactement ce que le curseur aurait fini par
 * emettre, dans le meme ordre et avec les memes types.
 */
class AdvertScheduleTest {

    private val slotMillis = 900_000L
    private val tokenLength = 16

    /** Un plan de [slots] creneaux et [perSlot] jetons, aux octets previsibles. */
    private fun plan(
        fromSlot: Long,
        slots: Int,
        perSlot: Int,
        types: ByteArray = ByteArray(slots * perSlot) { BleConstants.TYPE_FRIEND },
    ): AdvertSchedule {
        val tokens = ByteArray(slots * perSlot * tokenLength)
        for (i in 0 until slots * perSlot) {
            for (b in 0 until tokenLength) {
                tokens[i * tokenLength + b] = (i + b).toByte()
            }
        }
        return AdvertSchedule(fromSlot, slotMillis, slots, perSlot, tokens, tokenLength, types)
    }

    @Test
    fun `le creneau entier contient ce que le curseur aurait emis`() {
        val from = 1000L
        val p = plan(from, slots = 3, perSlot = 4)
        val now = from * slotMillis + 1234

        val (jetons, leursTypes) = p.tokensAt(now)!!
        assertEquals("un jeton par ami du creneau", 4, jetons.size)
        assertEquals(4, leursTypes.size)

        // L'invariant : rang i du creneau == ce que le curseur i aurait rendu.
        for (i in 0 until 4) {
            assertArrayEquals(
                "le rang $i doit valoir le jeton du curseur $i",
                p.tokenAt(now, i),
                jetons[i],
            )
            // ⚠️ **Compare aux types DEPOSES, plus a `typeAt`** (supprime le
            // 2026-08-29) : un test qui interroge deux methodes de la meme
            // classe les verifie l'une par l'autre, pas contre l'attendu.
            assertEquals(BleConstants.TYPE_FRIEND, leursTypes[i])
        }
    }

    @Test
    fun `deux creneaux consecutifs ne partagent aucun jeton`() {
        // Sinon le pistage d'un creneau a l'autre redeviendrait trivial.
        val from = 1000L
        val p = plan(from, slots = 2, perSlot = 2)
        val a = p.tokensAt(from * slotMillis)!!.first.map { it.toList() }
        val b = p.tokensAt((from + 1) * slotMillis)!!.first.map { it.toList() }
        assertEquals(0, a.intersect(b.toSet()).size)
    }

    @Test
    fun `hors du plan, on se TAIT plutot que de rejouer l'ancien`() {
        // Meme reponse que `tokenAt` : reemettre un jeton perime ne se voit pas,
        // ne leve rien, et laisse croire a une radio saine alors que plus
        // personne ne nous reconnait.
        val from = 1000L
        val p = plan(from, slots = 2, perSlot = 2)
        assertNull(p.tokensAt((from + 2) * slotMillis))
        assertNull(p.tokensAt((from - 1) * slotMillis))
    }

    @Test
    fun `les types suivent les jetons, ils ne se deduisent pas`() {
        // Lequel des jetons est l'identifiant public est une regle produit :
        // elle descend du Dart et ne doit jamais etre reconstituee ici.
        val from = 1000L
        val types = byteArrayOf(
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
        )
        val p = plan(from, slots = 2, perSlot = 2, types = types)
        val (_, t0) = p.tokensAt(from * slotMillis)!!
        assertEquals(BleConstants.TYPE_PUBLIC, t0[0])
        assertEquals(BleConstants.TYPE_FRIEND, t0[1])
    }

    // ------------------------------------------------------------------
    // L'HOMME MORT de l'identifiant public — 2026-08-29
    // ------------------------------------------------------------------
    //
    // Le defaut : le plan porte 75 minutes de jetons d'avance, pour que le
    // service survive seul a la mort du Dart. C'est juste pour les jetons
    // d'AMIS. L'identifiant PUBLIC, lui, ne vaut rien sans la balise que le
    // Dart republie au serveur toutes les 60 s et qui meurt 5 min apres lui :
    // l'appareil continuait donc de crier, jusqu'a 70 minutes de plus, un
    // identifiant que plus personne au monde ne pouvait traduire — et que
    // n'importe quel scanner pouvait suivre.
    //
    // Rien ne signalait ce cas : la radio etait saine, l'app etait fermee, et
    // personne ne regardait.

    @Test
    fun `sans battement, le public disparait et les amis restent`() {
        val from = 1000L
        val types = byteArrayOf(
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
        )
        val p = plan(from, slots = 2, perSlot = 2, types = types)
        val now = from * slotMillis + 42

        val avec = p.tokensAt(now, avecPublic = true)!!
        assertEquals(2, avec.first.size)

        val sans = p.tokensAt(now, avecPublic = false)!!
        assertEquals("il ne doit rester que l'ami", 1, sans.first.size)
        assertEquals(BleConstants.TYPE_FRIEND, sans.second[0])
        assertArrayEquals(
            "l'ami garde SON jeton : on filtre, on ne renumerote pas",
            avec.first[1],
            sans.first[0],
        )
    }

    @Test
    fun `croiser ses amis survit a la perte du battement`() {
        // ⚠️ **C'est la moitie qui doit continuer.** Un ami reconnait tout
        // seul, sans reseau, app fermee : son jeton a un horizon de douze heures
        // et il ne depend d'aucun serveur. Couper les deux ensemble aurait
        // supprime le croisement nocturne pour reparer une fuite de vie privee.
        val from = 1000L
        val p = plan(from, slots = 2, perSlot = 3)
        val now = from * slotMillis
        assertEquals(3, p.tokensAt(now, avecPublic = false)!!.first.size)
    }

    @Test
    fun `plus rien a crier n'est PAS un plan epuise`() {
        // Deux silences, deux causes, deux messages. `null` veut dire « le plan
        // ne couvre plus cet instant » et fait lever une panne a l'appelant ;
        // une liste vide veut dire « il n'y a rien a crier maintenant », ce qui
        // est le cas normal de quelqu'un qui ne voulait qu'etre decouvrable et
        // dont le Dart ne repond plus. Les confondre ferait annoncer une panne
        // a la place d'un silence voulu.
        val from = 1000L
        val types = ByteArray(2) { BleConstants.TYPE_PUBLIC }
        val p = plan(from, slots = 1, perSlot = 2, types = types)

        val vide = p.tokensAt(from * slotMillis, avecPublic = false)
        assertNotNull("le plan couvre cet instant : ce n'est pas null", vide)
        assertEquals(0, vide!!.first.size)

        assertNull(
            "hors du plan, en revanche, c'est bien null",
            p.tokensAt((from + 1) * slotMillis, avecPublic = false),
        )
    }

    @Test
    fun `avec battement, rien ne change par rapport a avant`() {
        // Le chemin normal doit rester exactement celui d'hier : `tokensAt(now)`
        // et `tokensAt(now, avecPublic = true)` sont le meme appel.
        val from = 1000L
        val types = byteArrayOf(
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
        )
        val p = plan(from, slots = 2, perSlot = 2, types = types)
        val now = from * slotMillis + 7
        val a = p.tokensAt(now)!!
        val b = p.tokensAt(now, avecPublic = true)!!
        assertEquals(a.first.size, b.first.size)
        for (i in a.first.indices) assertArrayEquals(a.first[i], b.first[i])
        assertArrayEquals(a.second, b.second)
    }

    @Test
    fun `un plan tronque rend null au lieu de lire hors du tampon`() {
        // Un depassement silencieux ferait crier des octets voisins - donc un
        // identifiant que personne n'attend, indiscernable d'une radio muette.
        val tokens = ByteArray(tokenLength) // un seul jeton pour deux annonces
        val p = AdvertSchedule(
            1000L, slotMillis, 1, 2, tokens, tokenLength,
            ByteArray(2) { BleConstants.TYPE_FRIEND },
        )
        assertNull(p.tokensAt(1000L * slotMillis))
    }

    // ------------------------------------------------------------------
    // friendsOnly : l'hypothese qui n'etait pas verifiee — 2026-08-31
    // ------------------------------------------------------------------

    /**
     * 🔴 **Le contre-test du defaut trouve a l'audit du 2026-08-31.**
     *
     * `friendsOnly` ne lit que les types du PREMIER creneau, puis applique sa
     * conclusion aux 48 autres. C'est juste tant que chaque creneau porte le
     * meme agencement — une hypothese que rien n'ecrivait ni ne verifiait.
     *
     * ⚠️ **Et c'est cette hypothese qui garantit qu'on n'ecrit jamais
     * l'identifiant public sur le disque** (decision de Jay, 2026-08-28) : la
     * moitie d'une regle de vie privee reposait sur une supposition.
     *
     * On refuse plutot que de deviner. Retirer la boucle de verification doit
     * faire tomber ce test.
     */
    @Test
    fun `friendsOnly REFUSE un plan dont l'agencement change d'un creneau a l'autre`() {
        // Creneau 0 : [public, ami] — creneau 1 : [ami, ami].
        val types = byteArrayOf(
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
            BleConstants.TYPE_FRIEND, BleConstants.TYPE_FRIEND,
        )
        val p = plan(fromSlot = 100, slots = 2, perSlot = 2, types = types)
        assertNull(
            "un plan qu'on ne sait pas decouper ne se persiste pas",
            p.friendsOnly(),
        )
    }

    @Test
    fun `friendsOnly accepte un plan uniforme et n'en garde que les amis`() {
        val types = byteArrayOf(
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
            BleConstants.TYPE_PUBLIC, BleConstants.TYPE_FRIEND,
        )
        val p = plan(fromSlot = 100, slots = 2, perSlot = 2, types = types)
        val amis = p.friendsOnly()
        assertNotNull(amis, )
        assertEquals("un seul jeton par creneau : celui de l'ami", 1, amis!!.cycleLength)

        // Le jeton retenu au creneau 0 doit etre le SECOND du plan d'origine.
        val attendu = p.tokensAt(100 * slotMillis, avecPublic = true)!!.first[1]
        val obtenu = amis.tokensAt(100 * slotMillis, avecPublic = true)!!.first[0]
        assertArrayEquals("c'est bien le jeton d'ami qui est persiste", attendu, obtenu)
    }
}
