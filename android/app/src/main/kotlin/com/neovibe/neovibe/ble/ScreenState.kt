package com.neovibe.neovibe.ble

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.PowerManager

/**
 * **L'ecran est-il allume, et depuis assez longtemps eteint pour lever le pied ?**
 *
 * Une source pour [BleEngine.modeDeScan], sur le modele de [AudioLink] : elle
 * constate et previent, elle ne decide de rien. Ce que le moteur en fait —
 * ecouter en continu ecran allume, un quart du temps ecran eteint — est ecrit
 * chez lui.
 *
 * ## ⚠️ Pourquoi un DELAI avant de dire « eteint » — carnet du 2026-09-21
 *
 * Le carnet du service montre l'ecran allume/eteint **six fois en 36 s**
 * (13:09:23 → 13:09:59). Or changer de rythme d'ecoute, c'est arreter et
 * relancer le scan, et **Android bannit un processus au-dela de cinq
 * demarrages par tranche de 30 s** (`SCAN_FAILED_SCANNING_TOO_FREQUENTLY`,
 * gere dans le moteur : la detection s'arrete 35 s et un bandeau le dit).
 * Suivre l'ecran a la lettre aurait donc coupe la detection precisement
 * quand l'utilisateur sort son telephone.
 *
 * D'ou la regle : **« eteint » ne se dit qu'apres [DELAI_EXTINCTION_MS]
 * d'extinction continue** ; « allume » se dit tout de suite (on ne revient
 * au continu que si on l'avait quitte, donc au plus une fois par minute).
 *
 * ## Ce qu'on lit, et pourquoi pas [EnergyWatcher]
 *
 * [EnergyWatcher] ecoute les memes signaux, mais c'est un **instrument** : il
 * ecrit au carnet et ne doit rien commander (sa note d'en-tete le dit). Deux
 * lecteurs du meme signal valent mieux qu'un instrument qui se met a decider.
 */
class ScreenState(
    private val context: Context,
    private val main: Handler,
    private val onChange: () -> Unit,
) {
    companion object {
        const val DELAI_EXTINCTION_MS = 60_000L
    }

    /** Ce que l'on dit au moteur. Vrai tant que l'ecran n'est pas eteint depuis [DELAI_EXTINCTION_MS]. */
    private var considereAllume = true

    private var enregistre = false

    private val bascule = Runnable {
        if (!considereAllume) return@Runnable
        considereAllume = false
        onChange()
    }

    private val recepteur = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    main.removeCallbacks(bascule)
                    main.postDelayed(bascule, DELAI_EXTINCTION_MS)
                }
                Intent.ACTION_SCREEN_ON -> {
                    main.removeCallbacks(bascule)
                    if (!considereAllume) {
                        considereAllume = true
                        onChange()
                    }
                }
            }
        }
    }

    fun attach() {
        if (enregistre) return
        val filtre = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        context.registerReceiver(recepteur, filtre)
        enregistre = true
        // L'etat de depart est lu, pas suppose : un service relance par
        // Android au milieu de la nuit demarre ecran eteint.
        val pm = context.getSystemService(PowerManager::class.java)
        if (pm?.isInteractive == false) main.postDelayed(bascule, DELAI_EXTINCTION_MS)
    }

    fun detach() {
        main.removeCallbacks(bascule)
        if (!enregistre) return
        runCatching { context.unregisterReceiver(recepteur) }
        enregistre = false
    }

    /** Vrai = ecouter en continu ; faux = l'ecran est eteint depuis au moins une minute. */
    fun allume(): Boolean = considereAllume
}
