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

  /// Vrai si le média scellé était **déjà** sur l'appareil. C'est ce qui
  /// sépare les deux cibles : un contenu froid n'est pas comparable à un
  /// contenu préchargé, et les confondre donnerait une moyenne qui ne veut
  /// rien dire.
  bool cached = false;

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
