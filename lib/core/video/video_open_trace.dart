/// Les étapes d'ouverture d'une vidéo, dans l'ordre où elles se produisent.
///
/// Découper ainsi n'est pas cosmétique : chacune se corrige par un chantier
/// **différent**, et sans le découpage on ne saurait pas lequel engager.
enum VideoOpenStep {
  /// L'écran réclame la face. C'est l'origine des temps — la seule que
  /// l'utilisateur perçoive.
  demande,

  /// Le fichier scellé est disponible localement. Mesure le cache ou le
  /// téléchargement, selon qu'il était déjà là.
  scelle,

  /// La clé est en main (appareil, lot de bibliothèque, ou aller-retour
  /// serveur).
  cle,

  /// Le lecteur a annoncé la taille et la durée du média.
  lecteur,

  /// **La première image est à l'écran.** C'est le seul repère qui compte pour
  /// juger « instantané » ; tous les autres servent à savoir qui l'a retardée.
  premiereImage,
}

/// Ce que l'appareil possédait **avant** l'ouverture.
///
/// ### Pourquoi trois états et pas un booléen
///
/// Jusqu'au 2026-08-13, la mesure ne connaissait que « en cache » ou « à
/// froid », et tranchait en Dart : *le fichier de cache existe-t-il ?* La
/// réponse était systématiquement fausse pour les vidéos partiellement vues —
/// le cache par blocs crée le fichier à **sa taille définitive dès le premier
/// bloc**, et pose son entrée d'index à l'ouverture. Une vidéo regardée deux
/// secondes puis fermée comptait donc comme « déjà sur l'appareil », alors que
/// la quasi-totalité de ses blocs restait à télécharger.
///
/// Résultat mesuré chez Jay le 2026-08-13 : un seau « en cache » de médiane
/// 761 ms avec une pire mesure à **16 s** — impossible pour une lecture
/// réellement locale, où il n'y a plus ni réseau ni déchiffrement Dart. Les
/// deux populations étaient mélangées, et le chiffre ne pouvait rien décider.
///
/// [partiel] est précisément la population qui les séparait. La réponse vient
/// désormais du natif, seul à connaître la carte des blocs.
enum MediaAvailability {
  /// Tous les blocs sont là : l'ouverture ne doit **rien** au réseau.
  complet,

  /// Déjà vu, mais incomplet. Les blocs manquants coûteront le réseau, et cette
  /// mesure ne dit rien de la cible « préchargé ».
  partiel,

  /// Jamais vu : l'ouverture inclut au moins l'amorçage.
  froid,
}

extension MediaAvailabilityLabel on MediaAvailability {
  String get label => switch (this) {
    MediaAvailability.complet => 'Complet sur l\'appareil',
    MediaAvailability.partiel => 'Partiel (déjà vu, incomplet)',
    MediaAvailability.froid => 'À froid (jamais vu)',
  };

  /// Le nom employé par le natif. Un intrus retombe sur [froid] : mieux vaut
  /// une mesure pessimiste qu'une mesure flatteuse.
  static MediaAvailability parse(String? value) => switch (value) {
    'complete' => MediaAvailability.complet,
    'partial' => MediaAvailability.partiel,
    _ => MediaAvailability.froid,
  };
}

extension VideoOpenStepLabel on VideoOpenStep {
  String get label => switch (this) {
    VideoOpenStep.demande => 'demande',
    VideoOpenStep.scelle => 'média local',
    VideoOpenStep.cle => 'clé',
    VideoOpenStep.lecteur => 'lecteur prêt',
    VideoOpenStep.premiereImage => 'première image',
  };
}

/// Une ouverture de vidéo mesurée, du geste de l'utilisateur à la première
/// image.
///
/// ### Pourquoi ça existe
///
/// La cible fixée par Jay le 2026-08-12 est un **chiffre** : moins de 300 ms
/// sur un contenu préchargé, moins d'une seconde sur un contenu froid. On ne
/// tient pas un chiffre qu'on ne mesure pas — et la leçon de la v0.9.55 est
/// exactement celle-là : *22 tests vérifiaient que les bons octets sortaient,
/// aucun ne demandait en combien de temps.* Un format juste et inutilisable
/// passe tous les tests.
///
/// Les mesures sont gardées **en mémoire seulement**, et lisibles dans
/// Réglages → Développeur. Rien n'est écrit sur le disque, rien n'est envoyé :
/// c'est un instrument de développement, à retirer avec la section Développeur
/// avant la prod (voir `RAPPELS.md`).
class VideoOpenTrace {
  VideoOpenTrace._(this.id) : _start = DateTime.now() {
    _marks[VideoOpenStep.demande] = Duration.zero;
  }

  /// Les ouvertures en cours, par identifiant de face. Une trace est retirée
  /// dès qu'elle aboutit — et le dictionnaire est plafonné, sinon une vidéo
  /// jamais affichée (écran fermé trop tôt) fuirait à chaque fois.
  static final _active = <String, VideoOpenTrace>{};

  /// Les dernières ouvertures terminées, la plus récente d'abord.
  static final _records = <VideoOpenTrace>[];

  static const _maxActive = 16;
  static const _maxRecords = 30;

  /// Vrai quand l'instrument tourne. Coupé, tout devient sans effet.
  ///
  /// **Actif en release** délibérément : Jay teste des APK de release, une
  /// mesure qui ne marcherait qu'en debug ne mesurerait pas ce qu'il voit. À
  /// passer à `false` — ou à supprimer avec la section Développeur — avant la
  /// prod (voir `RAPPELS.md`).
  static var enabled = true;

  final String id;
  final DateTime _start;
  final _marks = <VideoOpenStep, Duration>{};

  /// Ce que l'appareil possédait avant l'ouverture — **renseigné par le
  /// natif**, qui seul connaît la carte des blocs.
  ///
  /// Reste à [MediaAvailability.froid] tant que le natif n'a pas répondu :
  /// une mesure non classée ne doit jamais atterrir dans le seau le plus
  /// favorable, sous peine de flatter exactement le chiffre qu'on surveille.
  var availability = MediaAvailability.froid;

  /// Coûts **non séquentiels**, en millisecondes, par libellé.
  ///
  /// ### Pourquoi ils ne sont pas des jalons
  ///
  /// [VideoOpenStep] décrit une **suite** : chaque étape commence où la
  /// précédente finit. Deux travaux menés en parallèle n'y entrent pas — et
  /// les y forcer produit exactement le contresens du 2026-08-13 : l'URL
  /// signée et la clé partant ensemble, les deux jalons tombaient au même
  /// instant, `média local` valait `max(URL, clé)` et `clé` valait 0 **par
  /// construction**. On a cru y lire « la clé ne coûte rien » ; ce n'était pas
  /// une mesure, c'était la forme de l'instrument.
  ///
  /// Ce dictionnaire recueille ce qui ne s'aligne pas sur une frise : les deux
  /// coûts parallèles, et le détail interne du natif à l'intérieur d'un jalon.
  final detail = <String, int>{};

  /// Consigne un coût mesuré à part. Sans effet quand l'instrument est coupé.
  void note(String label, int ms) {
    if (!enabled) return;
    detail[label] = ms;
  }

  /// La face a été ouverte **d'avance**, sans que l'utilisateur ne l'ait
  /// demandée : le verso d'une Vibe, préparé pendant qu'on regarde le recto.
  ///
  /// ### Pourquoi ce drapeau décide de tout
  ///
  /// Sans lui, le chronomètre part au préchargement et s'arrête quand
  /// l'utilisateur regarde enfin — il mesure alors **le temps qu'il a passé à
  /// réfléchir**, pas une attente. Relevé du 2026-08-13 : deux faces arrière à
  /// **10 712 ms** et **2 154 ms** d'« attente avant natif », qui portaient la
  /// médiane à froid de ~853 ms à 1 002 ms.
  ///
  /// ⚠️ **C'est bloquant pour le préchargement** (`RAPPELS` #15) : une fois
  /// l'étape 4 en place, *tout* contenu sera préchargé. Sans ce drapeau,
  /// l'instrument annoncerait que le préchargement a tout ralenti — alors
  /// qu'il aurait tout accéléré.
  var prefetched = false;

  /// Quand la face a réellement été portée à l'écran. Nul tant qu'elle ne
  /// l'a pas été.
  Duration? displayedAt;

  /// Ce que l'utilisateur a **réellement** attendu.
  ///
  /// Pour une face demandée à l'écran, c'est le total : il inclut à juste
  /// titre le téléchargement et l'aller-retour de clé. Pour une face
  /// **préchargée**, l'attente ne commence qu'à l'affichage — tout ce qui
  /// précède s'est passé pendant que l'utilisateur regardait autre chose.
  Duration? get perceived {
    final end = _marks[VideoOpenStep.premiereImage];
    if (end == null || !prefetched) return end;
    final from = displayedAt;
    return from == null ? end : end - from;
  }

  /// Signale que la face [id] est ouverte **d'avance**. Appelé par l'écran qui
  /// la demande — lui seul sait ce qu'il montre.
  static void markPrefetched(String contentId, {required bool front}) {
    if (!enabled) return;
    _active['${contentId}_${front ? 'f' : 'b'}']?.prefetched = true;
  }

  /// Millisecondes écoulées depuis le début de l'ouverture.
  int get elapsedMs => DateTime.now().difference(_start).inMilliseconds;

  Duration? get total => _marks[VideoOpenStep.premiereImage];

  Duration? at(VideoOpenStep step) => _marks[step];

  /// Le temps passé DANS cette étape, c'est-à-dire depuis la précédente
  /// renseignée.
  Duration? spentOn(VideoOpenStep step) {
    final end = _marks[step];
    if (end == null) return null;
    Duration previous = Duration.zero;
    for (final s in VideoOpenStep.values) {
      if (s == step) break;
      previous = _marks[s] ?? previous;
    }
    return end - previous;
  }

  /// Ouvre une trace pour la face [id]. Une trace déjà ouverte pour le même
  /// identifiant est remplacée : c'est un réaffichage, et c'est lui qu'on veut
  /// mesurer.
  static VideoOpenTrace start(String id) {
    final trace = VideoOpenTrace._(id);
    if (!enabled) return trace;
    _active[id] = trace;
    if (_active.length > _maxActive) {
      _active.remove(_active.keys.first);
    }
    return trace;
  }

  /// La trace en cours pour [id], s'il y en a une. Nul est un cas normal :
  /// tous les chemins d'affichage ne sont pas instrumentés, et aucun ne doit
  /// dépendre de la mesure pour fonctionner.
  static VideoOpenTrace? of(String? id) => id == null ? null : _active[id];

  static List<VideoOpenTrace> get records => List.unmodifiable(_records);

  static void clear() {
    _active.clear();
    _records.clear();
  }

  void mark(VideoOpenStep step) {
    if (!enabled) return;
    _marks[step] = DateTime.now().difference(_start);
    if (step != VideoOpenStep.premiereImage) return;
    // Terminée : elle quitte les ouvertures en cours et rejoint l'historique.
    _active.remove(id);
    _records.insert(0, this);
    if (_records.length > _maxRecords) _records.removeLast();
  }
}
