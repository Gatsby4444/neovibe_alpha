/// Ce que le serveur a refusé, **en français et sans le bruit du transport**.
///
/// ## Pourquoi ce fichier existe
///
/// Jay a vu s'afficher, en plein écran Ping, le 2026-08-26 :
///
/// ```
/// PostgrestException(message: Déjà connectés : utilisez la messagerie
/// directe, code: P0001, details: Bad Request, hint: null)
/// ```
///
/// Le texte utile — celui que la fonction SQL a écrit **pour l'utilisateur** —
/// y est noyé dans quatre champs qui ne le concernent pas. Un message technique
/// n'est pas un message : il ne dit pas quoi faire, et il fait passer un refus
/// prévu pour une panne.
///
/// ⚠️ **Transverse, donc dans `core/`.** Cette fonction a d'abord été écrite
/// dans le fichier d'écran du Ping. Toute autre erreur serveur de l'app l'aurait
/// alors réécrite à son tour, avec ses propres bornes — et deux formatages qui
/// divergent, c'est deux messages différents pour le même refus.
///
/// ⚠️ **On ne masque pas ce qu'on ne reconnaît pas.** Si le format change, on
/// rend la chaîne entière plutôt qu'un vide : un message illisible reste
/// infiniment préférable à un message absent.
String messageServeur(Object erreur) {
  final texte = erreur.toString();
  const marqueur = 'message: ';
  final debut = texte.indexOf(marqueur);
  if (debut == -1) return texte;
  final reste = texte.substring(debut + marqueur.length);
  final fin = reste.indexOf(', code:');
  return fin == -1 ? reste : reste.substring(0, fin);
}
