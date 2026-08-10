import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/supabase_providers.dart';

/// Création du profil minimal : nom affiché obligatoire, photo optionnelle
/// (spec 4.1).
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController();
  File? _avatar;
  var _loading = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked != null) setState(() => _avatar = File(picked.path));
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
      String? avatarUrl;
      if (_avatar != null) {
        final path = '$userId/avatar.jpg';
        await client.storage
            .from('avatars')
            .upload(
              path,
              _avatar!,
              fileOptions: const FileOptions(
                contentType: 'image/jpeg',
                upsert: true,
              ),
            );
        // On enregistre le CHEMIN, pas une URL : le bucket est privé depuis le
        // 2026-08-10, il n'existe plus d'URL publique. L'affichage demande une
        // URL signée au moment de montrer l'image (`avatarUrlProvider`).
        avatarUrl = path;
      }
      await client.from('profiles').insert({
        'id': userId,
        'display_name': name,
        'avatar_url': ?avatarUrl,
      });
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
                  backgroundImage: _avatar == null ? null : FileImage(_avatar!),
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
