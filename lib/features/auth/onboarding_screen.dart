import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import '../profile/avatar_service.dart';
import '../profile/profile_repository.dart';

/// Création du profil minimal : nom affiché obligatoire, photo optionnelle
/// (spec 4.1).
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController();

  /// Les octets recadrés, en attente. Comme à l'édition de profil, la photo
  /// n'est déposée qu'à la validation.
  Uint8List? _avatar;
  var _loading = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final bytes = await ref.read(avatarServiceProvider).pickAndCrop(context);
    if (bytes != null && mounted) setState(() => _avatar = bytes);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Choisis un nom affiché.')));
      return;
    }
    setState(() => _loading = true);
    final client = ref.read(supabaseProvider);
    final userId = client.auth.currentUser!.id;
    try {
      // ⚠️ La ligne de profil D'ABORD, la photo ENSUITE. `AvatarService.upload`
      // met le profil à jour : sans la ligne, il n'aurait rien à mettre à jour
      // et la photo serait déposée dans le coffre sans que rien ne la désigne.
      await ref
          .read(profileRepositoryProvider)
          .create(userId: userId, displayName: name);
      // Le MÊME chemin qu'à l'édition de profil — recadrage, chemin versionné,
      // ménage de l'ancien fichier. C'est ce que le service existe pour
      // garantir : une étape ne peut plus être oubliée d'un côté seulement.
      if (_avatar != null) {
        await ref.read(avatarServiceProvider).upload(_avatar!);
      }
      ref.invalidate(myProfileProvider);
    } catch (e) {
      if (mounted) {
        final message = e.toString().contains('profiles_username_unique')
            ? 'Ce nom d\'utilisateur est déjà pris — choisis-en un autre.'
            : 'Erreur : $e';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ton profil')),
      body: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: GestureDetector(
                onTap: _pickAvatar,
                child: CircleAvatar(
                  radius: 52,
                  backgroundImage: _avatar == null
                      ? null
                      : MemoryImage(_avatar!),
                  child: _avatar == null
                      ? const Icon(Icons.add_a_photo, size: 32)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _name,
              maxLength: 50,
              decoration: const InputDecoration(labelText: 'Nom affiché'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _loading ? null : _save,
              child: _loading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('C\'est parti'),
            ),
          ],
        ),
      ),
    );
  }
}
