import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/motion.dart';
import '../../core/palette.dart';
import '../../core/theme.dart';
import '../../core/typography.dart';
import '../../core/widgets/ambience.dart';
import '../cards/native_camera.dart';
import '../../core/supabase_providers.dart';
import '../auth/auth_screen.dart';
import 'arrival_flow.dart';
import 'arrival_permissions.dart';
import '../../core/widgets/stage.dart';

/// **L'arrivée en soirée — l'interface de test (Développeur › Outils).**
///
/// Sept étapes, une idée par écran : l'accroche, le prénom, le selfie
/// (obligatoire, photo de profil temporaire), le compte, les autorisations,
/// la recherche de la soirée, et « tu es dedans ».
///
/// ⚠️ **La soirée se passe la nuit** : le parcours est toujours en identité
/// sombre, quel que soit le thème choisi — c'est une scène, pas un écran de
/// réglages. Voir [ArrivalFlow] pour ce qui est réel et ce qui est simulé.
class ArrivalScreen extends ConsumerStatefulWidget {
  const ArrivalScreen({super.key, this.mode = ArrivalMode.test});

  /// Test (Développeur, n'écrit rien) ou réel (l'inscription) — voir
  /// [ArrivalMode].
  final ArrivalMode mode;

  @override
  ConsumerState<ArrivalScreen> createState() => _ArrivalScreenState();
}

class _ArrivalScreenState extends ConsumerState<ArrivalScreen> {
  @override
  void initState() {
    super.initState();
    final flow = ref.read(arrivalFlowProvider(widget.mode).notifier);
    if (widget.mode == ArrivalMode.test) {
      // Le test repart de zéro à chaque ouverture.
      Future.microtask(flow.startTest);
    } else if (ref.read(currentUserIdProvider) != null) {
      // Déjà connecté mais sans profil : on part du prénom, sans compte.
      Future.microtask(() => flow.begin(hasAccount: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ModeScope(
      mode: widget.mode,
      child: Theme(
        data: NeoTheme.of(NeoIdentity.sombre, Brightness.dark),
        child: const AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle.light,
          child: _ArrivalStage(),
        ),
      ),
    );
  }
}

/// Le mode du parcours, transmis à toutes ses étapes : chacune lit SA mémoire
/// (`arrivalFlowProvider(mode)`), jamais celle de l'autre mode.
class _ModeScope extends InheritedWidget {
  const _ModeScope({required this.mode, required super.child});

  final ArrivalMode mode;

  @override
  bool updateShouldNotify(_ModeScope old) => old.mode != mode;
}

extension on BuildContext {
  // Lu SANS abonnement : le mode ne change jamais pendant la vie de l'écran,
  // et c'est ce qui permet de le lire aussi dans les `initState`.
  ArrivalMode get arrivalMode =>
      getInheritedWidgetOfExactType<_ModeScope>()?.mode ?? ArrivalMode.test;

  bool get isRealArrival => arrivalMode == ArrivalMode.real;
}

class _ArrivalStage extends ConsumerWidget {
  const _ArrivalStage();

  /// Les étapes qui comptent dans la barre de progression.
  static List<ArrivalStep> _counted(bool real, bool hasAccount) => [
    ArrivalStep.name,
    ArrivalStep.selfie,
    if (!(real && hasAccount)) ArrivalStep.account,
    ArrivalStep.permissions,
    if (!real) ArrivalStep.radar,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = context.arrivalMode;
    final real = mode == ArrivalMode.real;
    final step = ref.watch(arrivalFlowProvider(mode).select((s) => s.step));
    final hasAccount = ref.watch(
      arrivalFlowProvider(mode).select((s) => s.hasAccount),
    );
    final flow = ref.read(arrivalFlowProvider(mode).notifier);
    final counted = _counted(real, hasAccount);
    final progress = counted.indexOf(step);

    void leave() {
      if (flow.back()) return;
      if (real) {
        // Le parcours réel EST la racine de l'app : « retour » en sort.
        SystemNavigator.pop();
      } else {
        flow.reset();
        Navigator.of(context).pop();
      }
    }

    final showBack = !(real && step == ArrivalStep.threshold);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        leave();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: NeoAmbience(
          intensity: step == ArrivalStep.inside ? NeoAmbience.soiree : 1,
          child: SafeArea(
            child: Column(
              children: [
                SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      if (showBack)
                        IconButton(
                          icon: Icon(
                            step == ArrivalStep.threshold
                                ? Icons.close_rounded
                                : Icons.arrow_back_rounded,
                          ),
                          onPressed: leave,
                        )
                      else
                        const SizedBox(width: 48),
                      Expanded(
                        child: AnimatedOpacity(
                          duration: NeoMotion.normal,
                          opacity: progress >= 0 ? 1 : 0,
                          child: StageProgress(
                            current: progress < 0 ? 0 : progress,
                            total: counted.length,
                          ),
                        ),
                      ),
                      const SizedBox(width: NeoSpace.lg),
                      if (!real) ...[
                        const StageChip('TEST'),
                        const SizedBox(width: NeoSpace.lg),
                      ] else
                        const SizedBox(width: 48),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: NeoMotion.ample,
                    switchInCurve: NeoMotion.enter,
                    switchOutCurve: NeoMotion.exit,
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        ).animate(a),
                        child: child,
                      ),
                    ),
                    child: KeyedSubtree(
                      key: ValueKey(step),
                      child: switch (step) {
                        ArrivalStep.threshold => const _Threshold(),
                        ArrivalStep.name => const _NameStep(),
                        ArrivalStep.selfie => const _SelfieStep(),
                        ArrivalStep.account => const _AccountStep(),
                        ArrivalStep.permissions => const _PermissionsStep(),
                        ArrivalStep.radar => const _RadarStep(),
                        ArrivalStep.inside => const _InsideStep(),
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Le cadre commun d'une étape : le contenu au centre, le geste en bas.
class _StepFrame extends StatelessWidget {
  const _StepFrame({required this.children, required this.action});

  final List<Widget> children;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NeoSpace.xxl - 4,
        NeoSpace.lg,
        NeoSpace.xxl - 4,
        NeoSpace.xl,
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
              ),
            ),
          ),
          action,
        ],
      ),
    );
  }
}

class _Lead extends StatelessWidget {
  const _Lead(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: context.palette.inkMuted,
      fontSize: 16,
      height: 1.4,
    ),
  );
}

/// Le selfie dans un rond, ou l'initiale s'il n'y en a pas encore.
class _Me extends ConsumerWidget {
  const _Me({required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(arrivalFlowProvider(context.arrivalMode));
    return StageHalo(
      size: size,
      child: s.selfie != null
          ? Image.file(s.selfie!, fit: BoxFit.cover)
          : HaloInitial(s.initial, size: size),
    );
  }
}

// ─── 0. L'accroche ────────────────────────────────────────────────────────

class _Threshold extends ConsumerWidget {
  const _Threshold();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.read(arrivalFlowProvider(context.arrivalMode).notifier);
    final real = context.isRealArrival;
    return _StepFrame(
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowButton(
            label: 'J\'entre',
            icon: Icons.arrow_forward_rounded,
            onPressed: () => real
                ? flow.begin(hasAccount: false)
                : flow.goTo(ArrivalStep.name),
          ),
          if (real)
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
              child: const Text('J\'ai déjà un compte'),
            ),
        ],
      ),
      children: const [
        StageHalo(size: 190, child: HaloInitial('', size: 190)),
        SizedBox(height: NeoSpace.section + 8),
        StageTitle('Ce soir,\nça se passe ici.', gradient: true),
        SizedBox(height: NeoSpace.lg),
        _Lead(
          'NeoVibe ne marche que quand tu es vraiment là.\n'
          'Les gens, les photos, les défis : tout vient de la soirée.',
        ),
      ],
    );
  }
}

// ─── 1. Le prénom ─────────────────────────────────────────────────────────

class _NameStep extends ConsumerStatefulWidget {
  const _NameStep();

  @override
  ConsumerState<_NameStep> createState() => _NameStepState();
}

class _NameStepState extends ConsumerState<_NameStep> {
  late final _controller = TextEditingController(
    text: ref.read(arrivalFlowProvider(context.arrivalMode)).firstName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_controller.text.trim().isEmpty) return;
    ref
        .read(arrivalFlowProvider(context.arrivalMode).notifier)
        .goTo(ArrivalStep.selfie);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final name = ref.watch(
      arrivalFlowProvider(context.arrivalMode).select((s) => s.firstName),
    );
    return _StepFrame(
      action: GlowButton(
        label: 'C\'est moi',
        onPressed: name.isEmpty ? null : _next,
      ),
      children: [
        const _Me(size: 132),
        const SizedBox(height: NeoSpace.section),
        const StageTitle('C\'est quoi\nton prénom ?'),
        const SizedBox(height: NeoSpace.xxl),
        TextField(
          controller: _controller,
          autofocus: true,
          maxLength: 30,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.next,
          onChanged: ref
              .read(arrivalFlowProvider(context.arrivalMode).notifier)
              .setName,
          onSubmitted: (_) => _next(),
          style: TextStyle(
            fontFamily: NeoType.display,
            fontWeight: FontWeight.w500,
            fontSize: 30,
            color: p.ink,
          ),
          cursorColor: p.action,
          decoration: InputDecoration(
            counterText: '',
            hintText: 'Ton prénom',
            hintStyle: TextStyle(color: p.outline),
            filled: false,
            border: InputBorder.none,
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: p.line, width: 2),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: p.action, width: 2),
            ),
          ),
        ),
        const SizedBox(height: NeoSpace.md),
        if (ref.watch(
              arrivalFlowProvider(context.arrivalMode).select((s) => s.error),
            )
            case final error?)
          _ErrorLine(error)
        else
          const _Lead('C\'est ce que verront les gens de la soirée.'),
      ],
    );
  }
}

// ─── 2. Le selfie ─────────────────────────────────────────────────────────

class _SelfieStep extends ConsumerStatefulWidget {
  const _SelfieStep();

  @override
  ConsumerState<_SelfieStep> createState() => _SelfieStepState();
}

enum _CamState { opening, live, refused, failed }

class _SelfieStepState extends ConsumerState<_SelfieStep> {
  final _camera = NativeCameraController();
  var _cam = _CamState.opening;
  var _shooting = false;
  var _flash = false;

  @override
  void initState() {
    super.initState();
    _camera.addListener(_onCamera);
    if (ref.read(arrivalFlowProvider(context.arrivalMode)).selfie == null) {
      unawaited(_open());
    }
  }

  void _onCamera() {
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    setState(() => _cam = _CamState.opening);
    final ok = await ref.read(arrivalPermissionsProvider).requestCamera();
    if (!mounted) return;
    if (!ok) {
      setState(() => _cam = _CamState.refused);
      return;
    }
    try {
      await _camera.open(back: false, audio: false);
      if (mounted) setState(() => _cam = _CamState.live);
    } catch (_) {
      if (mounted) setState(() => _cam = _CamState.failed);
    }
  }

  Future<void> _shoot() async {
    if (_shooting || _cam != _CamState.live) return;
    setState(() {
      _shooting = true;
      _flash = true;
    });
    unawaited(HapticFeedback.mediumImpact());
    try {
      final File photo = await _camera.takePicture();
      if (!mounted) return;
      ref
          .read(arrivalFlowProvider(context.arrivalMode).notifier)
          .setSelfie(photo);
      await _camera.close();
    } catch (_) {
      if (mounted) setState(() => _cam = _CamState.failed);
    } finally {
      if (mounted) {
        setState(() => _shooting = false);
        Future<void>.delayed(const Duration(milliseconds: 180), () {
          if (mounted) setState(() => _flash = false);
        });
      }
    }
  }

  Future<void> _retake() async {
    ref.read(arrivalFlowProvider(context.arrivalMode).notifier).clearSelfie();
    await _open();
  }

  @override
  void dispose() {
    _camera.removeListener(_onCamera);
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = ref.watch(arrivalFlowProvider(context.arrivalMode));
    final taken = s.selfie != null;
    const size = 250.0;

    final Widget inside;
    if (taken) {
      inside = Image.file(s.selfie!, fit: BoxFit.cover);
    } else if (_cam == _CamState.live && _camera.textureId != null) {
      inside = NativeCameraPreview(
        textureId: _camera.textureId!,
        info: _camera.previews['main'],
        mirror: true,
      );
    } else if (_cam == _CamState.refused || _cam == _CamState.failed) {
      inside = Icon(Icons.no_photography_rounded, size: 56, color: p.outline);
    } else {
      inside = const Center(child: CircularProgressIndicator());
    }

    final Widget action;
    if (taken) {
      action = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowButton(
            label: 'Je garde',
            busy: s.busy,
            onPressed: () => ref
                .read(arrivalFlowProvider(context.arrivalMode).notifier)
                .keepSelfie(),
          ),
          if (s.error != null) _ErrorLine(s.error!),
          TextButton(
            onPressed: s.busy ? null : _retake,
            child: const Text('Reprendre'),
          ),
        ],
      );
    } else if (_cam == _CamState.refused) {
      action = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlowButton(label: 'Autoriser la caméra', onPressed: _open),
          TextButton(
            onPressed: ref.read(arrivalPermissionsProvider).openSettings,
            child: const Text('Ouvrir les réglages'),
          ),
        ],
      );
    } else if (_cam == _CamState.failed) {
      action = GlowButton(label: 'Réessayer', onPressed: _open);
    } else {
      action = _Shutter(
        onPressed: _cam == _CamState.live && !_shooting ? _shoot : null,
      );
    }

    return _StepFrame(
      action: action,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            StageHalo(
              size: size,
              breathing: taken,
              ringSpeed: taken ? 0.4 : 1.6,
              child: inside,
            ),
            IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: _flash ? 1 : 0,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.ink,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: NeoSpace.section),
        StageTitle(
          taken
              ? 'Salut ${s.firstName} 👋'
              : _cam == _CamState.refused
              ? 'Il nous faut ta tête'
              : 'Ta tête de ce soir',
        ),
        const SizedBox(height: NeoSpace.md),
        _Lead(
          _cam == _CamState.refused && !taken
              ? 'Le selfie est obligatoire : c\'est comme ça que les gens '
                    'de la soirée te reconnaissent.'
              : 'Ce sera ta photo de profil pour l\'instant.\n'
                    'Tu la changeras quand tu veux.',
        ),
      ],
    );
  }
}

/// Le déclencheur : un rond blanc, cerclé du dégradé.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GestureDetector(
      onTap: onPressed,
      child: AnimatedOpacity(
        duration: NeoMotion.fast,
        opacity: onPressed == null ? 0.4 : 1,
        child: Container(
          width: 82,
          height: 82,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: p.signatureCourte,
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: p.ink,
              border: Border.all(color: p.ground, width: 3),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── 3. Le compte ─────────────────────────────────────────────────────────

class _AccountStep extends ConsumerStatefulWidget {
  const _AccountStep();

  @override
  ConsumerState<_AccountStep> createState() => _AccountStepState();
}

class _AccountStepState extends ConsumerState<_AccountStep> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  var _hidden = true;

  @override
  void initState() {
    super.initState();
    _email.addListener(_changed);
    _password.addListener(_changed);
  }

  void _changed() => setState(() {});

  bool get _valid =>
      _email.text.contains('@') &&
      _email.text.contains('.') &&
      _password.text.length >= 6;

  Future<void> _create() => ref
      .read(arrivalFlowProvider(context.arrivalMode).notifier)
      .createAccount(email: _email.text.trim(), password: _password.text);

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  InputDecoration _field(NeoPalette p, String label, {Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        suffixIcon: suffix,
        filled: true,
        fillColor: p.field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(NeoRadius.md),
          borderSide: BorderSide(color: p.action, width: 1.6),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final real = context.isRealArrival;
    final s = ref.watch(arrivalFlowProvider(context.arrivalMode));
    return _StepFrame(
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.error != null) _ErrorLine(s.error!),
          GlowButton(
            label: 'Créer mon compte',
            busy: s.busy,
            onPressed: _valid ? _create : null,
          ),
          if (!real)
            TextButton(
              onPressed: s.busy ? null : _create,
              child: const Text('Passer (test)'),
            ),
        ],
      ),
      children: [
        const _Me(size: 96),
        const SizedBox(height: NeoSpace.xxl),
        const StageTitle('Dernière chose\npour toi'),
        const SizedBox(height: NeoSpace.md),
        const _Lead('Pas de mail à aller confirmer : tu entres tout de suite.'),
        const SizedBox(height: NeoSpace.xxl),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          textInputAction: TextInputAction.next,
          decoration: _field(p, 'Email'),
        ),
        const SizedBox(height: NeoSpace.md),
        TextField(
          controller: _password,
          obscureText: _hidden,
          onSubmitted: (_) => _valid ? _create() : null,
          decoration: _field(
            p,
            'Mot de passe (6 caractères min.)',
            suffix: IconButton(
              icon: Icon(
                _hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              onPressed: () => setState(() => _hidden = !_hidden),
            ),
          ),
        ),
        if (!real) ...[
          const SizedBox(height: NeoSpace.lg),
          const StageChip('TEST — aucun compte n\'est créé'),
        ],
      ],
    );
  }
}

// ─── 4. Les autorisations ─────────────────────────────────────────────────

class _PermissionsStep extends ConsumerStatefulWidget {
  const _PermissionsStep();

  @override
  ConsumerState<_PermissionsStep> createState() => _PermissionsStepState();
}

class _PermissionsStepState extends ConsumerState<_PermissionsStep> {
  /// Chaque carte n'est demandée qu'une fois par passage : après, elle dit
  /// ce qui a été répondu, et la suivante s'allume.
  final _asked = <int>{};
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(arrivalFlowProvider(context.arrivalMode).notifier).readGrants(),
    );
  }

  Future<void> _ask(int index) async {
    setState(() => _busy = true);
    final flow = ref.read(arrivalFlowProvider(context.arrivalMode).notifier);
    try {
      switch (index) {
        case 0:
          await flow.askLocation();
        case 1:
          await flow.askBluetooth();
        case 2:
          await flow.askNotifications();
      }
    } finally {
      if (mounted) {
        setState(() {
          _asked.add(index);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(arrivalFlowProvider(context.arrivalMode));
    final grants = [s.location, s.bluetooth, s.notifications];
    // La carte active : la première ni accordée, ni déjà demandée.
    var active = -1;
    for (var i = 0; i < grants.length; i++) {
      if (grants[i] != ArrivalGrant.yes && !_asked.contains(i)) {
        active = i;
        break;
      }
    }
    final loaded = grants.every((g) => g != null);
    final done = loaded && active == -1;

    return _StepFrame(
      action: done
          ? GlowButton(
              label: 'Trouver ma soirée',
              icon: Icons.radar_rounded,
              onPressed: () {
                final flow = ref.read(
                  arrivalFlowProvider(context.arrivalMode).notifier,
                );
                if (context.isRealArrival) {
                  flow.finish();
                } else {
                  flow.goTo(ArrivalStep.radar);
                }
              },
            )
          : GlowButton(
              label: 'Autoriser',
              busy: _busy || !loaded,
              onPressed: active >= 0 ? () => _ask(active) : null,
            ),
      children: [
        const StageTitle('Trois oui,\net tu es dedans.'),
        const SizedBox(height: NeoSpace.xxl),
        _PermissionCard(
          icon: Icons.place_rounded,
          title: 'Ta position',
          reason:
              'Pour trouver la soirée où tu es. Choisis « précise » : '
              'l\'approximative se trompe de 2 km.',
          grant: s.location,
          active: active == 0,
          asked: _asked.contains(0),
        ),
        const SizedBox(height: NeoSpace.md),
        _PermissionCard(
          icon: Icons.bluetooth_searching_rounded,
          title: 'Les appareils à proximité',
          reason:
              'Pour savoir qui est vraiment là, à quelques mètres de toi. '
              'Ni ton nom ni ton compte ne sont diffusés.',
          grant: s.bluetooth,
          active: active == 1,
          asked: _asked.contains(1),
        ),
        const SizedBox(height: NeoSpace.md),
        _PermissionCard(
          icon: Icons.notifications_active_rounded,
          title: 'Les notifications',
          reason:
              'Pour savoir quand tes amis arrivent, et quand la soirée '
              'lance un défi.',
          grant: s.notifications,
          active: active == 2,
          asked: _asked.contains(2),
        ),
      ],
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.reason,
    required this.grant,
    required this.active,
    required this.asked,
  });

  final IconData icon;
  final String title;
  final String reason;
  final ArrivalGrant? grant;
  final bool active;
  final bool asked;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ok = grant == ArrivalGrant.yes;
    final partial = grant == ArrivalGrant.partial;
    final String? verdict = switch (grant) {
      ArrivalGrant.yes => null,
      ArrivalGrant.partial when asked =>
        'Position approximative : ça ne trouvera pas le bar.',
      ArrivalGrant.no when asked => 'Refusé — tu pourras l\'activer plus tard.',
      _ => null,
    };
    return AnimatedContainer(
      duration: NeoMotion.normal,
      curve: NeoMotion.enter,
      padding: const EdgeInsets.all(NeoSpace.lg),
      decoration: BoxDecoration(
        color: active ? p.field : p.surface,
        borderRadius: BorderRadius.circular(NeoRadius.lg),
        border: Border.all(
          color: active ? p.action.withValues(alpha: 0.8) : p.line,
          width: active ? 1.6 : 1,
        ),
      ),
      child: AnimatedOpacity(
        duration: NeoMotion.normal,
        opacity: active || ok || asked ? 1 : 0.5,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: NeoMotion.normal,
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ok ? p.signatureCourte : null,
                color: ok ? null : p.line,
              ),
              child: Icon(
                ok ? Icons.check_rounded : icon,
                color: ok ? p.onAction : (partial ? p.warm : p.ink),
              ),
            ),
            const SizedBox(width: NeoSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: NeoType.display,
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                      color: p.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    reason,
                    style: TextStyle(color: p.inkMuted, fontSize: 13.5),
                  ),
                  if (verdict != null) ...[
                    const SizedBox(height: NeoSpace.xs),
                    Text(
                      verdict,
                      style: TextStyle(
                        color: p.warm,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 5. Le radar ──────────────────────────────────────────────────────────

class _RadarStep extends ConsumerStatefulWidget {
  const _RadarStep();

  @override
  ConsumerState<_RadarStep> createState() => _RadarStepState();
}

class _RadarStepState extends ConsumerState<_RadarStep> {
  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(arrivalFlowProvider(context.arrivalMode).notifier).findVenue(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = ref.watch(arrivalFlowProvider(context.arrivalMode));
    final venue = s.searching ? null : s.venue;

    return _StepFrame(
      action: AnimatedSwitcher(
        duration: NeoMotion.ample,
        transitionBuilder: (child, a) => ScaleTransition(
          scale: CurvedAnimation(parent: a, curve: NeoMotion.spring),
          child: FadeTransition(opacity: a, child: child),
        ),
        child: venue == null
            ? const SizedBox(height: 58, key: ValueKey('wait'))
            : GlowButton(
                key: const ValueKey('join'),
                label: 'Rejoindre la soirée',
                icon: Icons.celebration_rounded,
                onPressed: () {
                  unawaited(HapticFeedback.heavyImpact());
                  ref
                      .read(arrivalFlowProvider(context.arrivalMode).notifier)
                      .goTo(ArrivalStep.inside);
                },
              ),
      ),
      children: [
        SizedBox(
          height: 300,
          child: Center(
            child: SonarRings(
              active: venue == null,
              child: const _Me(size: 120),
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: NeoMotion.ample,
          child: venue == null
              ? const Column(
                  key: ValueKey('searching'),
                  children: [
                    StageTitle('On cherche\nta soirée…'),
                    SizedBox(height: NeoSpace.md),
                    _Lead('Avec ta position, et les téléphones autour de toi.'),
                  ],
                )
              : Column(
                  key: const ValueKey('found'),
                  children: [
                    Text(
                      'Tu es au',
                      style: TextStyle(color: p.inkMuted, fontSize: 16),
                    ),
                    const SizedBox(height: NeoSpace.xs),
                    StageTitle(venue.place, gradient: true),
                    const SizedBox(height: NeoSpace.sm),
                    Text(
                      '${venue.title} · ${venue.presentCount} présents',
                      style: TextStyle(color: p.ink, fontSize: 16),
                    ),
                    if (venue.isDemo) ...[
                      const SizedBox(height: NeoSpace.md),
                      const StageChip('DÉMO — aucune soirée trouvée autour'),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

// ─── 6. Dedans ────────────────────────────────────────────────────────────

class _InsideStep extends ConsumerStatefulWidget {
  const _InsideStep();

  @override
  ConsumerState<_InsideStep> createState() => _InsideStepState();
}

class _InsideStepState extends ConsumerState<_InsideStep>
    with SingleTickerProviderStateMixin {
  static const _parts = 5;

  late final _enter = AnimationController(
    vsync: this,
    duration: NeoBuildIn.durationFor(_parts) * 2,
  )..forward();

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Widget _in(int i, Widget child) =>
      NeoBuildIn(animation: _enter, index: i, total: _parts, child: child);

  Future<void> _addVibe() async {
    final replay = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: context.palette.surface,
      builder: (context) => const _EndOfTest(),
    );
    if (!mounted || replay == null) return;
    if (replay) {
      ref.read(arrivalFlowProvider(context.arrivalMode).notifier).startTest();
    } else {
      ref.read(arrivalFlowProvider(context.arrivalMode).notifier).reset();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = ref.watch(arrivalFlowProvider(context.arrivalMode));
    final venue = s.venue ?? ArrivalVenue.demo;
    final others = (venue.presentCount - 1).clamp(0, 9999);

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(
            NeoSpace.xl,
            NeoSpace.sm,
            NeoSpace.xl,
            120,
          ),
          children: [
            _in(
              0,
              Column(
                children: [
                  const StageTitle('Tu es dedans.', gradient: true),
                  const SizedBox(height: NeoSpace.xs),
                  Text(
                    '${venue.place} · ${venue.title}',
                    style: TextStyle(color: p.inkMuted, fontSize: 15),
                  ),
                  if (venue.isDemo) ...[
                    const SizedBox(height: NeoSpace.sm),
                    const StageChip('DÉMO'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: NeoSpace.xxl),
            _in(1, _Presents(me: s.selfie, others: others)),
            const SizedBox(height: NeoSpace.xxl),
            _in(
              2,
              const _SectionTitle(
                'Le Drop de la soirée',
                'Ce que les présents vivent ce soir. Il disparaît demain.',
              ),
            ),
            const SizedBox(height: NeoSpace.md),
            _in(3, _DropGrid(onAdd: _addVibe)),
            const SizedBox(height: NeoSpace.xxl),
            _in(
              4,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle(
                    'Les défis',
                    'À relever sur place, à prouver par une Vibe.',
                  ),
                  const SizedBox(height: NeoSpace.md),
                  Wrap(
                    spacing: NeoSpace.sm,
                    runSpacing: NeoSpace.sm,
                    children: [
                      for (final c in ArrivalDemo.challenges)
                        ActionChip(
                          avatar: Icon(Icons.bolt_rounded, color: p.warm),
                          label: Text(c),
                          onPressed: _addVibe,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          left: NeoSpace.xl,
          right: NeoSpace.xl,
          bottom: NeoSpace.xl,
          child: GlowButton(
            label: 'Ajoute ta Vibe au Drop',
            icon: Icons.photo_camera_rounded,
            onPressed: _addVibe,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, this.subtitle);

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontFamily: NeoType.display,
            fontWeight: FontWeight.w600,
            fontSize: 22,
            color: p.ink,
          ),
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: p.inkMuted, fontSize: 13.5)),
      ],
    );
  }
}

/// Les présents : moi d'abord, cerclé, puis une rangée qui se chevauche.
class _Presents extends StatelessWidget {
  const _Presents({required this.me, required this.others});

  final File? me;
  final int others;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const size = 46.0;
    const shown = 6;
    final faces = ArrivalDemo.presents.take(shown).toList();
    return Container(
      padding: const EdgeInsets.all(NeoSpace.lg),
      decoration: BoxDecoration(
        color: p.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(NeoRadius.lg),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          SizedBox(
            width: size + (faces.length) * (size * 0.55),
            height: size,
            child: Stack(
              children: [
                for (var i = faces.length - 1; i >= 0; i--)
                  Positioned(
                    left: size * 0.55 * (i + 1),
                    child: _Face(
                      letter: faces[i].characters.first,
                      gradient: demoTileGradient(p, i),
                      size: size,
                    ),
                  ),
                StageHalo(
                  size: size,
                  breathing: false,
                  ringSpeed: 0.5,
                  child: me == null
                      ? const SizedBox.shrink()
                      : Image.file(me!, fit: BoxFit.cover),
                ),
              ],
            ),
          ),
          const SizedBox(width: NeoSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Toi + $others',
                  style: TextStyle(
                    fontFamily: NeoType.display,
                    fontWeight: FontWeight.w600,
                    fontSize: 18,
                    color: p.ink,
                  ),
                ),
                Text(
                  'présents ce soir',
                  style: TextStyle(color: p.inkMuted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({
    required this.letter,
    required this.gradient,
    required this.size,
  });

  final String letter;
  final Gradient gradient;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: gradient,
        border: Border.all(color: p.surface, width: 2.5),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontFamily: NeoType.display,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.4,
          color: p.onAction,
        ),
      ),
    );
  }
}

/// Le Drop : ma place d'abord (vide, qui appelle), puis les Vibes des autres.
class _DropGrid extends StatelessWidget {
  const _DropGrid({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: NeoSpace.sm,
      crossAxisSpacing: NeoSpace.sm,
      childAspectRatio: 9 / 16,
      children: [
        InkWell(
          onTap: onAdd,
          borderRadius: BorderRadius.circular(NeoRadius.md),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(NeoRadius.md),
              border: Border.all(color: p.action, width: 1.6),
              color: p.action.withValues(alpha: 0.08),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, color: p.action, size: 34),
                const SizedBox(height: NeoSpace.xs),
                Text(
                  'Ta Vibe\nici',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: NeoType.display,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
        for (var i = 0; i < ArrivalDemo.drop.length; i++)
          _DropTile(index: i, vibe: ArrivalDemo.drop[i]),
      ],
    );
  }
}

class _DropTile extends StatelessWidget {
  const _DropTile({required this.index, required this.vibe});

  final int index;
  final ({String author, int minutes, String caption}) vibe;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(NeoRadius.md),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(gradient: demoTileGradient(p, index)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  p.ground.withValues(alpha: 0),
                  p.ground.withValues(alpha: 0.7),
                ],
                stops: const [0.45, 1],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(NeoSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  vibe.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${vibe.author} · ${vibe.minutes} min',
                  style: TextStyle(color: p.inkMuted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// La fin du test : ce qui s'ouvrirait, et de quoi recommencer.
class _EndOfTest extends StatelessWidget {
  const _EndOfTest();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          NeoSpace.xl,
          NeoSpace.xl,
          NeoSpace.xl,
          NeoSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StageTitle('Fin du test'),
            const SizedBox(height: NeoSpace.md),
            Text(
              'Ici s\'ouvrirait la caméra, en mode Drop : ta première Vibe '
              'de la soirée. C\'est le moment où quelqu\'un a accroché.',
              textAlign: TextAlign.center,
              style: TextStyle(color: p.inkMuted, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: NeoSpace.xl),
            GlowButton(
              label: 'Rejouer le test',
              icon: Icons.replay_rounded,
              onPressed: () => Navigator.of(context).pop(true),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Quitter'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ce que le serveur a refusé, dit en une phrase, juste au-dessus du geste.
class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: NeoSpace.md),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: context.palette.warm,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
