import 'package:flutter/material.dart';

/// Les palettes de NeoVibe — **ce que les couleurs SONT**, et rien d'autre.
///
/// ## Pourquoi ce fichier est séparé de `theme.dart`
///
/// `theme.dart` répond à *« comment Material se sert de ces couleurs »* : quels
/// rôles remplir, quelles bordures, quelle barre système. Ici on répond à
/// *« quelles sont les couleurs »*. Ce sont deux questions, et deux rythmes de
/// changement : Jay change une palette sans qu'aucune règle de thème bouge, et
/// on corrige un défaut de thème sans toucher à une seule couleur.
///
/// C'est la règle de dissociation appliquée à l'habillage : la palette
/// **publie** ce qu'elle est, le thème **décide** de ce qu'il en fait.
///
/// ## Les quatre identités, décidées par Jay le 2026-08-29
///
/// | Identité | Ce qu'elle est |
/// |---|---|
/// | [NeoIdentity.sombre] | le neutre historique, gris strictement neutres |
/// | [NeoIdentity.clair] | idem, en clair |
/// | [NeoIdentity.aurore] | magenta · cyan · jaune en **détails**, sur blanc |
/// | [NeoIdentity.sable] | beige, blanc cassé et bruns |
///
/// ⚠️ **La règle « gris strictement neutres » (R == G == B) du 2026-08-14 ne
/// vaut QUE pour `sombre` et `clair`.** Jay l'a explicitement rouverte le
/// 2026-08-29 pour les deux nouvelles identités : *« pour ne pas retomber dans
/// un thème noir ou blanc — on les conserve, mais on ajoute un nouveau thème
/// par défaut »*. Les blancs d'Aurore sont donc froids et les beiges de Sable
/// sont chauds **à dessein** ; ce n'est pas la teinte parasite que la règle
/// d'origine interdisait, c'est l'identité elle-même.
///
/// ## Les deux nouvelles identités suivent le jour et la nuit
///
/// Chacune fournit **deux** palettes. Un thème beige à 23 h serait un phare :
/// une identité qui ne sait pas se coucher n'est pas une identité, c'est un
/// papier peint.
enum NeoIdentity {
  sombre('Sombre', 'Le neutre, en noir et gris'),
  clair('Clair', 'Le neutre, en blanc et gris'),
  aurore('Aurore', 'Magenta, cyan et jaune sur blanc froid'),
  sable('Sable', 'Beige, blanc cassé et bruns'),
  cycle('Cycle du jour', 'Le fond dégradé horaire, sur le neutre sombre');

  const NeoIdentity(this.label, this.description);

  final String label;
  final String description;

  /// Vrai si l'app pose le dégradé du cycle de 24 h DERRIÈRE tous les écrans.
  ///
  /// ⚠️ **C'est un fond, pas une palette.** Jay l'a retiré du défaut le
  /// 2026-08-29 — *« après plusieurs jours d'utilisation je m'en lasse, ça fait
  /// bazar »* — mais demandé qu'il reste disponible. Il reste donc une
  /// identité à part entière, choisissable, et non un interrupteur greffé sur
  /// les quatre autres : posé sous une identité claire, il donnerait du blanc
  /// sur du pâle.
  bool get fondDuCycle => this == cycle;

  /// Vrai si l'identité s'adapte au réglage jour/nuit du téléphone.
  ///
  /// `clair` et `sombre` sont des choix **explicites** : les suivre au système
  /// reviendrait à ne pas les avoir choisis.
  bool get suitLeSysteme => this == aurore || this == sable;

  static NeoIdentity fromKey(String? value) => switch (value) {
    'sombre' => NeoIdentity.sombre,
    'clair' => NeoIdentity.clair,
    'sable' => NeoIdentity.sable,
    'cycle' => NeoIdentity.cycle,
    // ⚠️ **Le défaut est `aurore` depuis le 2026-08-29**, sur décision de Jay.
    // Il était `neovibe` (le cycle) — voir la reprise de l'ancienne clé dans
    // `ThemeChoicePref`, qui explique pourquoi cette valeur-là est traduite en
    // `aurore` et non en `cycle`.
    _ => NeoIdentity.aurore,
  };

  /// La palette de cette identité pour la luminosité demandée.
  ///
  /// Une identité qui ne suit pas le système rend **toujours** la même
  /// palette : c'est ce qui rend `clair` clair, même en mode nuit.
  NeoPalette palette(Brightness brightness) => switch (this) {
    NeoIdentity.sombre => NeoPalettes.sombre,
    NeoIdentity.clair => NeoPalettes.clair,
    NeoIdentity.aurore =>
      brightness == Brightness.dark
          ? NeoPalettes.auroreNuit
          : NeoPalettes.auroreJour,
    NeoIdentity.sable =>
      brightness == Brightness.dark
          ? NeoPalettes.sableNuit
          : NeoPalettes.sableJour,
    // Le cycle emprunte le neutre sombre : ses surfaces sont des voiles posés
    // SUR le dégradé, donc elles ne doivent apporter aucune couleur propre.
    NeoIdentity.cycle => NeoPalettes.sombre,
  };
}

/// Une palette complète. **Tous les champs sont obligatoires** — c'est
/// volontaire.
///
/// ⚠️ Une valeur par défaut ici rendrait un oubli **silencieux** : une nouvelle
/// identité hériterait d'une couleur d'une autre, et le défaut ne se verrait
/// que sur l'écran où cette couleur sert. Le compilateur est le seul contrôle
/// qui ne s'oublie pas.
@immutable
class NeoPalette {
  const NeoPalette({
    required this.brightness,
    required this.ground,
    required this.surface,
    required this.field,
    required this.line,
    required this.outline,
    required this.ink,
    required this.inkMuted,
    required this.action,
    required this.onAction,
    required this.cool,
    required this.warm,
    required this.signature,
  });

  /// Clair ou sombre — ce que Material doit savoir pour ses propres calculs
  /// (et ce qui décide de la couleur des icônes de la barre système).
  final Brightness brightness;

  /// Le fond de l'écran.
  final Color ground;

  /// Ce qui se pose DESSUS : cartes, feuilles, barre de navigation.
  ///
  /// ⚠️ Sur les identités claires, `surface` est **plus claire** que `ground`
  /// (blanc pur sur blanc froid, blanc cassé sur beige) : c'est ce qui donne
  /// la profondeur **sans ombre portée**. Une ombre sur fond clair salit ;
  /// un écart de clarté, non.
  final Color surface;

  /// Champs de saisie, puces, pistes de curseur.
  final Color field;

  /// Séparateurs et bordures décoratives.
  final Color line;

  /// Bordure des éléments **interactifs** — toujours plus soutenue que [line].
  ///
  /// Elle porte une règle énoncée positivement : **un champ a toujours un bord
  /// visible**, quel que soit son remplissage. Sans elle, la limite d'un champ
  /// dépendrait de l'écart entre deux surfaces proches — c'est le « noir sur
  /// noir » signalé par Jay le 2026-08-10.
  final Color outline;

  /// Le texte principal.
  final Color ink;

  /// Le texte secondaire — **une couleur à part, pas une opacité**.
  ///
  /// Un texte à 62 % d'opacité sur un fond coloré prend la teinte du fond et
  /// vire au sale. Sur les palettes colorées, le gris de texte est donc choisi,
  /// pas calculé.
  final Color inkMuted;

  /// Ce qui est **actif** : bouton d'action, champ au focus, onglet courant.
  ///
  /// Une seule couleur pour une seule idée, sur les quatre identités.
  final Color action;

  /// Le texte posé SUR [action]. Jamais déduit : sur du jaune il est sombre,
  /// sur du magenta il est clair, et aucune règle simple ne couvre les deux.
  final Color onAction;

  /// L'accent **froid** — deuxième voix, pour les états calmes et les repères.
  final Color cool;

  /// L'accent **chaud** — troisième voix, pour ce qui doit accrocher l'œil
  /// une fois (une pastille, un point, un anneau). Jamais du texte.
  final Color warm;

  /// Le dégradé de signature de l'identité.
  ///
  /// ⚠️ **Il appartient à la palette, pas à l'app.** Jusqu'au 2026-08-29 un
  /// unique dégradé jaune-orange-rose-violet-bleu était posé partout ; sur une
  /// identité magenta/cyan ou beige, il aurait juré. Un dégradé de marque est
  /// une **conséquence** de la palette, pas une constante qui la traverse.
  final Gradient signature;

  /// Le dégradé court, pour les **petites** surfaces (boutons, pastilles).
  ///
  /// Sur quelques dizaines de pixels, un dégradé à cinq arrêts vire au
  /// brouillon : on n'en garde que les deux extrêmes.
  LinearGradient get signatureCourte => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [action, warm],
  );

  /// La version atténuée, pour les états désactivés et les fonds de conteneur.
  LinearGradient get signatureAttenuee => LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [action.withValues(alpha: 0.20), warm.withValues(alpha: 0.20)],
  );

  bool get isDark => brightness == Brightness.dark;
}

/// Les palettes elles-mêmes.
///
/// ⚠️ **Aucun écran ne doit écrire un hexadécimal.** C'est ce qui avait
/// dispersé le violet dans sept fichiers avant le 2026-08-14 : une couleur
/// écrite en dehors d'ici est une couleur qui ne suivra pas les changements
/// d'identité, et personne ne le verra tant qu'il n'aura pas changé de thème.
abstract final class NeoPalettes {
  // ===================================================================
  // SOMBRE — le neutre historique. R == G == B sur chaque gris.
  // ===================================================================
  static const sombre = NeoPalette(
    brightness: Brightness.dark,
    ground: Color(0xFF000000),
    surface: Color(0xFF121212),
    field: Color(0xFF1F1F1F),
    line: Color(0xFF2E2E2E),
    outline: Color(0xFF6B6B6B),
    ink: Color(0xFFFFFFFF),
    inkMuted: Color(0xFFB0B0B0),
    // ⚠️ **Défaut antérieur au 2026-08-29, trouvé par `palette_test`.**
    // La valeur était #E1306C : du blanc dessus ne donnait que 3,9:1, sous le
    // seuil de 4,5:1 du texte courant. #D62976 est le rose CENTRAL du dégradé
    // de marque (déjà utilisé par l'identité claire) et donne 4,7:1 —
    // l'écart ne se voit pas à l'œil, la lisibilité si.
    action: Color(0xFFD62976),
    onAction: Color(0xFFFFFFFF),
    cool: Color(0xFF7B2FF7),
    warm: Color(0xFFF9773C),
    signature: LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        Color(0xFFFEDA75),
        Color(0xFFFA7E1E),
        Color(0xFFD62976),
        Color(0xFF962FBF),
        Color(0xFF4F5BD5),
      ],
      stops: [0.0, 0.22, 0.52, 0.78, 1.0],
    ),
  );

  // ===================================================================
  // CLAIR — le même neutre, retourné.
  // ===================================================================
  static const clair = NeoPalette(
    brightness: Brightness.light,
    ground: Color(0xFFFFFFFF),
    surface: Color(0xFFF5F5F5),
    field: Color(0xFFEBEBEB),
    line: Color(0xFFD6D6D6),
    // ⚠️ **Défaut antérieur au 2026-08-29, trouvé par `palette_test`.**
    // La valeur était #8A8A8A, dont le commentaire affirmait « 3,4:1 sur
    // blanc ». C'était vrai — et hors sujet : sur le REMPLISSAGE d'un champ
    // (#EBEBEB) elle ne donnait que 2,7:1, sous le seuil. Le contraste avait
    // été mesuré contre la surface la plus favorable des deux.
    outline: Color(0xFF757575),
    ink: Color(0xFF000000),
    inkMuted: Color(0xFF5C5C5C),
    action: Color(0xFFD62976),
    onAction: Color(0xFFFFFFFF),
    cool: Color(0xFF7B2FF7),
    warm: Color(0xFFF9773C),
    signature: LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        Color(0xFFFEDA75),
        Color(0xFFFA7E1E),
        Color(0xFFD62976),
        Color(0xFF962FBF),
        Color(0xFF4F5BD5),
      ],
      stops: [0.0, 0.22, 0.52, 0.78, 1.0],
    ),
  );

  // ===================================================================
  // AURORE — magenta · cyan · jaune, en DÉTAILS, sur blanc froid.
  //
  // La consigne de Jay : « sous forme de détails colorés épurés et assortis à
  // de la profondeur ». Donc la couleur ne porte AUCUNE grande surface : le
  // fond est un blanc à peine froid, les cartes sont blanc pur, et la couleur
  // n'apparaît que sur ce qui agit ou signale.
  //
  // La profondeur vient de l'écart ground → surface (#F7F9FC → #FFFFFF), pas
  // d'une ombre. Sur un blanc, une ombre grise salit ; un écart de clarté
  // reste propre à toute taille.
  // ===================================================================
  static const auroreJour = NeoPalette(
    brightness: Brightness.light,
    ground: Color(0xFFF7F9FC),
    surface: Color(0xFFFFFFFF),
    field: Color(0xFFEFF3F9),
    line: Color(0xFFE0E6EF),
    // ⚠️ Mesurée contre le fond ET contre le remplissage d'un champ. La
    // première valeur essayée (#97A2B4) passait sur le fond et échouait sur le
    // champ : une bordure ne se juge pas sur la surface la plus contrastée des
    // deux. 3,9:1 sur le remplissage, 4,1:1 sur le fond.
    outline: Color(0xFF6E7A8D),
    ink: Color(0xFF0F1319),
    inkMuted: Color(0xFF5A6577),
    // Magenta soutenu : 5,6:1 sur le fond, et le blanc dessus donne 4,7:1.
    action: Color(0xFFD10480),
    onAction: Color(0xFFFFFFFF),
    // Cyan profond — assez sombre pour porter du texte sur clair (4,6:1).
    cool: Color(0xFF00808F),
    // Jaune : accroche l'œil, ne porte JAMAIS de texte (voir `onAction`).
    warm: Color(0xFFFFC02E),
    signature: LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        Color(0xFFFFC02E),
        Color(0xFFF5308C),
        Color(0xFFD10480),
        Color(0xFF00A9BD),
      ],
      stops: [0.0, 0.34, 0.62, 1.0],
    ),
  );

  /// Aurore, la nuit : l'encre passe au bleu très sombre plutôt qu'au noir —
  /// c'est ce qui garde la parenté avec le blanc froid du jour. Les trois
  /// accents remontent en luminosité, sinon un magenta de jour disparaît.
  static const auroreNuit = NeoPalette(
    brightness: Brightness.dark,
    ground: Color(0xFF0A0D14),
    surface: Color(0xFF131824),
    field: Color(0xFF1C2231),
    line: Color(0xFF2B3346),
    outline: Color(0xFF6E7A90),
    ink: Color(0xFFF3F6FB),
    inkMuted: Color(0xFF97A3B8),
    action: Color(0xFFFF4FAC),
    onAction: Color(0xFF0A0D14),
    cool: Color(0xFF3AD8E8),
    warm: Color(0xFFFFD35C),
    signature: LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        Color(0xFFFFD35C),
        Color(0xFFFF4FAC),
        Color(0xFFB44BF0),
        Color(0xFF3AD8E8),
      ],
      stops: [0.0, 0.34, 0.62, 1.0],
    ),
  );

  // ===================================================================
  // SABLE — beige, blanc cassé, bruns. Le registre « décor » de Pinterest.
  //
  // Ici l'écart ground → surface est INVERSÉ par rapport à l'habitude : le
  // fond est beige et les cartes sont plus CLAIRES (blanc cassé). C'est ce qui
  // fait qu'une carte a l'air posée sur du papier, et non découpée dedans.
  // ===================================================================
  static const sableJour = NeoPalette(
    brightness: Brightness.light,
    ground: Color(0xFFF2ECE2),
    surface: Color(0xFFFBF7F0),
    field: Color(0xFFEAE1D3),
    line: Color(0xFFDACDBA),
    // Même mesure que pour Aurore : 3,9:1 sur le remplissage d'un champ.
    outline: Color(0xFF7E6C57),
    ink: Color(0xFF2C241D),
    inkMuted: Color(0xFF6D6053),
    // Brun profond : le blanc dessus donne 7,1:1.
    action: Color(0xFF7A4E2E),
    onAction: Color(0xFFFDFBF7),
    // Camel — les surfaces calmes, les états au repos.
    cool: Color(0xFFB08968),
    // Terre cuite — le point qui accroche.
    warm: Color(0xFFA9553F),
    signature: LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        Color(0xFFE3C9A6),
        Color(0xFFB08968),
        Color(0xFFA9553F),
        Color(0xFF7A4E2E),
      ],
      stops: [0.0, 0.32, 0.68, 1.0],
    ),
  );

  /// Sable, la nuit : un brun expresso, jamais du noir. Passer au noir ferait
  /// perdre l'identité au moment précis où l'app est le plus utilisée.
  static const sableNuit = NeoPalette(
    brightness: Brightness.dark,
    ground: Color(0xFF15100C),
    surface: Color(0xFF1F1812),
    field: Color(0xFF2A211A),
    line: Color(0xFF3B2F25),
    outline: Color(0xFF8A7561),
    ink: Color(0xFFF4EBDD),
    inkMuted: Color(0xFFB3A38F),
    action: Color(0xFFD9955F),
    onAction: Color(0xFF15100C),
    cool: Color(0xFFC9A987),
    warm: Color(0xFFE07C5A),
    signature: LinearGradient(
      begin: Alignment.bottomLeft,
      end: Alignment.topRight,
      colors: [
        Color(0xFFE3C9A6),
        Color(0xFFD9955F),
        Color(0xFFE07C5A),
        Color(0xFF8A5A3B),
      ],
      stops: [0.0, 0.32, 0.68, 1.0],
    ),
  );

  /// Toutes les palettes, pour les vérifications d'ensemble.
  ///
  /// ⚠️ Une palette absente de cette liste échapperait à **tous** les tests de
  /// contraste. La liste est donc construite à partir de l'énumération des
  /// identités, pas écrite à la main : ajouter une identité sans l'éprouver
  /// devient impossible.
  static List<(String, NeoPalette)> get toutes => [
    for (final id in NeoIdentity.values)
      if (id == NeoIdentity.cycle)
        // Il emprunte la palette de `sombre`, déjà éprouvée juste au-dessus.
        // L'inclure ferait passer deux fois le même test et laisserait croire
        // à une couverture plus large qu'elle n'est.
        ...[]
      else if (id.suitLeSysteme) ...[
        ('${id.name} (jour)', id.palette(Brightness.light)),
        ('${id.name} (nuit)', id.palette(Brightness.dark)),
      ] else
        (id.name, id.palette(Brightness.light)),
  ];
}
