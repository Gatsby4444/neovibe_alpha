package com.neovibe.neovibe.ble

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat

/**
 * **Le reveil qui sonne meme quand l'appareil dort.**
 *
 * ## 🔴 Le defaut que cette classe supprime — releve le 2026-08-30
 *
 * Le plan d'emission porte douze heures de jetons d'avance : le natif sait
 * **quoi** crier sans le Dart. Mais la main qui **tourne la page** etait un
 * `Handler.postDelayed` ([ProximityService.cycleTick]), et un `Handler` dort
 * avec le processeur.
 *
 * Or en mode parallele les jeux d'annonces sont **deja en l'air** : la puce
 * Bluetooth continue de rayonner toute seule, sans processeur. Endormi,
 * l'appareil criait donc le jeton d'un creneau revolu, **en continu et sans
 * lever la moindre erreur**.
 *
 * Releve du test de nuit du 2026-08-30 (02:13 → 12:04, `dev_reports`) : la
 * tablette a entendu **110 694** jetons prives du telephone et n'en a reconnu
 * **aucun** ; les deux appareils ne se sont pas vus de 02:45 a 07:00, et la
 * tablette est restee aveugle jusqu'a 09:30.
 *
 * ⚠️ **C'est le « point H » du 2026-08-19 revenu a un autre etage.** Le
 * correctif d'alors avait supprime la dependance du natif au **Dart** ; il n'a
 * rien fait pour sa dependance au **processeur**. Une cause supprimee a un
 * etage peut se reformer a l'etage du dessous : ce qui compte n'est pas
 * « le Dart est-il vivant ? » mais *« qui, exactement, appelle `emitNext` ? »*.
 *
 * ## ⚠️ Pourquoi `setAndAllowWhileIdle` et NON `setExactAndAllowWhileIdle`
 *
 * La version exacte exige `SCHEDULE_EXACT_ALARM`, qu'Android 13 refuse par
 * defaut et que Google Play reserve aux reveils et aux agendas. Une app sociale
 * qui la demande se fait refuser la mise en ligne.
 *
 * Et nous n'avons **pas besoin** d'exactitude : la fenetre de reconnaissance
 * accepte le creneau courant **a un pres** ([RecognitionTable.match]), soit un
 * quart d'heure de retard absorbe sans consequence. La version inexacte suffit,
 * ne demande aucune permission, et se reveille bien en Doze — c'est le defaut
 * juste, pas l'option supplementaire.
 *
 * ⚠️ **Le quota de Doze est de un reveil par ~9 minutes et par app.** Notre
 * creneau vaut 15 minutes : on passe. Reduire la duree du creneau sous
 * 9 minutes rendrait ce reveil silencieusement insuffisant — a relire ici avant
 * d'y toucher.
 *
 * ## 🔴 Une sonnerie avalee ne doit pas tuer les suivantes — nuit du 2026-09-14
 *
 * L'alarme est posee **a coup unique** et ne se repose que dans sa propre
 * sonnerie ([recepteur]). Le carnet de la nuit du 2026-09-14 (`dev_reports`
 * `8eb6d161…`) montre ce que ca coute : l'alarme armee a 02:09 pour 02:15
 * **n'a jamais ete delivree** — pas differee, perdue, y compris entre 07:30 et
 * 08:30 alors que le processus tournait et que les minuteurs Dart etaient a
 * l'heure. Vingt-six frontieres de creneau sans sonnerie, jusqu'a ce qu'un
 * depot de plan a 08:30 la rearme par hasard ; ensuite, 7 sonneries sur 7.
 *
 * Qui a avale la sonnerie (Doze, MIUI) n'est pas notre affaire ; **qu'une
 * seule sonnerie perdue suffise a arreter toutes les suivantes, sans rien
 * signaler, l'est**. [veille] est la reponse : toute main qui passe par le
 * service (la page qui tourne, un plan depose) verifie si l'echeance visee
 * est depassee d'un creneau entier et, si oui, repose l'alarme et **l'ecrit**.
 *
 * ## ⚠️ Ce que cette classe ne fait pas
 *
 * Elle ne sait pas ce qu'est un jeton, un ami ni un plan. Elle sonne aux
 * frontieres de creneau, c'est tout. Le reveil et ce qu'on en fait sont deux
 * choses, et elles se testent separement.
 */
class SlotAlarm(
    private val context: Context,
    /**
     * Appele a chaque sonnerie, avec le retard en millisecondes (0 si aucune
     * echeance n'etait visee). C'est par la que le service ecrit la sonnerie
     * **sur le disque** : [reveils] et [retardMaxMillis] meurent avec le
     * processus, et c'est precisement la nuit qu'il meurt (2026-09-13).
     */
    private val onReveil: (Long) -> Unit = {},
    /**
     * Appele quand [veille] constate une sonnerie **perdue** (echeance
     * depassee d'un creneau entier, jamais delivree) et la repose, avec le
     * retard constate. Meme destination que [onReveil] : le disque.
     */
    private val onPerdu: (Long) -> Unit = {},
    private val onSlot: () -> Unit,
) {
    private val manager = context.getSystemService(AlarmManager::class.java)

    /** Duree d'un creneau. Zero = le reveil est desarme. */
    private var slotMillis = 0L

    /** L'instant pour lequel la sonnerie est posee. Zero = aucune. */
    private var vise = 0L

    private var enregistre = false

    /**
     * Combien de fois le reveil a sonne.
     *
     * ⚠️ **C'est la mesure qui dit si ce fichier sert a quelque chose.** Une
     * nuit de dix heures doit en compter une quarantaine ; un compte proche de
     * zero signifie que le systeme n'a pas honore l'alarme, et le defaut n'est
     * alors pas la ou on croit.
     */
    var reveils = 0
        private set

    /**
     * Le plus grand retard observe entre la sonnerie visee et la sonnerie
     * reelle.
     *
     * ⚠️ **Une valeur instantanee n'aurait rien mesure** : on ne lit un
     * diagnostic qu'apres avoir reveille l'appareil, c'est-a-dire au seul
     * moment ou tout va bien. Une trace haute survit au reveil.
     */
    var retardMaxMillis = 0L
        private set

    private val recepteur = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            reveils++
            var retard = 0L
            if (vise != 0L) {
                retard = System.currentTimeMillis() - vise
                if (retard > retardMaxMillis) retardMaxMillis = retard
            }
            onReveil(retard)
            onSlot()
            // On se repose pour le creneau suivant. Une alarme `AlarmManager`
            // ne se repete pas d'elle-meme quand elle est inexacte.
            if (slotMillis > 0L) arm(slotMillis)
        }
    }

    /**
     * Arme le reveil pour la **prochaine** frontiere de creneau.
     *
     * Appeler plusieurs fois est sans effet de bord : le `PendingIntent` est
     * unique, donc la nouvelle echeance remplace l'ancienne.
     */
    fun arm(slotMillis: Long) {
        if (slotMillis <= 0L) return
        this.slotMillis = slotMillis
        enregistreSiBesoin()

        val prochain = prochaineFrontiere(System.currentTimeMillis(), slotMillis)
        vise = prochain

        val m = manager ?: return
        // Une pile qui refuse l'alarme ne doit pas emporter la radio avec elle :
        // le `Handler` reste en place et fait le travail tant que l'appareil est
        // eveille. On perd la nuit, pas la journee.
        runCatching {
            m.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, prochain, pending())
        }
    }

    /**
     * Repose l'alarme si sa sonnerie a ete avalee.
     *
     * A appeler a chaque passage de main dans le service (voir la note
     * « une sonnerie avalee » en tete de fichier). Sans effet quand le reveil
     * est desarme, quand aucune echeance n'est visee, ou quand la sonnerie
     * est seulement **en retard** — jusqu'a 10,7 min observees le 2026-09-14,
     * ce qui est absorbe par la fenetre de reconnaissance. Perdue = un creneau
     * entier apres l'echeance ([estPerdue]) : a ce moment-la, la frontiere
     * suivante est deja passee et la sonnerie n'a plus rien a tourner.
     *
     * ⚠️ Reposer avec le meme `PendingIntent` **remplace** l'ancienne alarme :
     * si elle finissait par arriver, elle ne sonnerait pas en double.
     */
    fun veille(nowMillis: Long = System.currentTimeMillis()) {
        if (slotMillis <= 0L || vise == 0L) return
        if (!estPerdue(nowMillis, vise, slotMillis)) return
        onPerdu(nowMillis - vise)
        arm(slotMillis)
    }

    /** Desarme, et rend le recepteur au systeme. */
    fun cancel() {
        runCatching { manager?.cancel(pending()) }
        if (enregistre) {
            runCatching { context.unregisterReceiver(recepteur) }
            enregistre = false
        }
        slotMillis = 0L
        vise = 0L
    }

    private fun enregistreSiBesoin() {
        if (enregistre) return
        // ⚠️ **Enregistre a l'execution, pas au manifeste.** Ce reveil n'a de
        // sens que tant que le service vit : declare au manifeste, il
        // relancerait le service apres un arret voulu par l'utilisateur.
        ContextCompat.registerReceiver(
            context,
            recepteur,
            IntentFilter(ACTION),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        enregistre = true
    }

    private fun pending(): PendingIntent = PendingIntent.getBroadcast(
        context,
        0,
        // `setPackage` : sans lui, Android 14 refuse un intent implicite.
        Intent(ACTION).setPackage(context.packageName),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    companion object {
        private const val ACTION = "com.neovibe.proximity.SLOT"

        /** Deux secondes apres la frontiere. Voir [prochaineFrontiere]. */
        const val MARGE = 2_000L

        /**
         * A quel instant sonner pour se trouver **dans** le creneau suivant.
         *
         * ⚠️ **La marge n'est pas de la prudence, elle est la raison d'etre de
         * ce calcul.** Sonner pile a la frontiere laisse `now / slotMillis` sur
         * l'ANCIEN creneau des que l'alarme part une milliseconde trop tot :
         * [ProximityService.emitNext] reecrirait alors le jeton qu'on vient de
         * quitter, et il faudrait attendre un creneau entier pour se rattraper.
         * Le defaut serait un quart d'heure d'invisibilite **par creneau**, et
         * il ne leverait rien.
         *
         * ⚠️ **Seule partie de cette classe qui puisse se tromper en silence**,
         * donc la seule qui soit pure — et eprouvee (`SlotAlarmTest`). Le reste
         * ne fait que parler a Android.
         */
        fun prochaineFrontiere(nowMillis: Long, slotMillis: Long): Long =
            ((nowMillis / slotMillis) + 1) * slotMillis + MARGE

        /**
         * Une sonnerie visee pour [viseMillis] est **perdue** quand un creneau
         * entier s'est ecoule depuis sans qu'elle arrive. En deca, elle est
         * seulement en retard, et un retard est normal en veille.
         *
         * Pure, pour la meme raison que [prochaineFrontiere] : c'est la seule
         * ligne qui puisse se tromper en silence — trop tot, on reposerait une
         * alarme qui allait sonner ; trop tard, on retrouve la nuit du
         * 2026-09-14.
         */
        fun estPerdue(nowMillis: Long, viseMillis: Long, slotMillis: Long): Boolean =
            viseMillis != 0L && nowMillis - viseMillis > slotMillis
    }
}
