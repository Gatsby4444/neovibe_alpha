# Règles de conservation pour R8 (le compresseur du build release).
#
# ## Pourquoi ce fichier existe (2026-09-19, test de Jay sur la v0.9.220)
#
# La file de publication écrit et relit `job.json` par Gson, qui lit les
# classes PAR LEUR NOM (réflexion). En release, R8 renomme tout : `PublishJob`
# devenait `x7.g`, et le dépôt échouait avec « Abstract classes can't be
# instantiated… Class name: x7.g ». Invisible en debug et sur la JVM.
#
# Ce que la réflexion lit doit garder son nom et ses champs : tout le paquet
# `publish` (PublishJob, PublishMedia, TranscodeSpec, PublishFile, Release,
# Session), et les types génériques que Gson résout (TypeToken).
-keep class com.neovibe.neovibe.publish.** { *; }
-keepclassmembers class com.neovibe.neovibe.publish.** { *; }

# Règles recommandées par Gson lui-même.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
