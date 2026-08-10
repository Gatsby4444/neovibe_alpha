import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/widgets/avatar.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';

/// Édition du profil : PP, username (unique), tag name (optionnel, affiché en
/// conversation), bio.
class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key, required this.profile});
  final Profile profile;

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  late final _username = TextEditingController(
    text: widget.profile.displayName,
  );
  late final _tagName = TextEditingController(
    text: widget.profile.tagName ?? '',
  );
  late final _bio = TextEditingController(text: widget.profile.bio ?? '');
  File? _newAvatar;
  var _loading = false;

  @override
  void dispose() {
    _username.dispose();
    _tagName.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 85,
    );
    if (picked != null) setState(() => _newAvatar = File(picked.path));
  }

  Future<void> _save() async {
    final username = _username.text.trim();
    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le nom d\'utilisateur est requis.')),
      );
      return;
    }
    setState(() => _loading = true);
    final client = ref.read(supabaseProvider);
    final me = client.auth.currentUser!.id;
    try {
      String? avatarUrl;
      if (_newAvatar != null) {
        final path = '$me/avatar.jpg';
        await client.storage
            .from('avatars')
            .upload(
              path,
              _newAvatar!,
              fileOptions: const FileOptions(
                contentType: 'image/jpeg',
                upsert: true,
              ),
            );
        // On enregistre le CHEMIN : le bucket est privé depuis le 2026-08-10,
        // il n'y a plus d'URL publique à fabriquer — ni de cache-buster à
        // ajouter, puisque l'URL signée est régénérée à chaque session.
        avatarUrl = path;
      }
      final tagName = _tagName.text.trim();
      final bio = _bio.text.trim();
      await client
          .from('profiles')
          .update({
            'display_name': username,
            'tag_name': tagName.isEmpty ? null : tagName,
            'bio': bio.isEmpty ? null : bio,
            'avatar_url': ?avatarUrl,
          })
          .eq('id', me);
      ref.invalidate(myProfileProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        final message = e.toString().contains('profiles_username_unique')
            ? 'Ce nom d\'utilisateur est déjà pris.'
            : 'Erreur : $e';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Modifier le profil')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: GestureDetector(
              onTap: _pickAvatar,
              // Une image tout juste choisie prime sur celle du serveur.
              child: _newAvatar != null
                  ? CircleAvatar(
                      radius: 48,
                      backgroundImage: FileImage(_newAvatar!),
                    )
                  : Avatar(
                      radius: 48,
                      stored: widget.profile.avatarUrl,
                      fallback: const Icon(Icons.add_a_photo, size: 30),
                    ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _username,
            maxLength: 50,
            decoration: const InputDecoration(
              labelText: 'Nom d\'utilisateur',
              helperText: 'Unique — c\'est ton identité sur NeoVibe',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tagName,
            maxLength: 30,
            decoration: const InputDecoration(
              labelText: 'Tag name (optionnel)',
              helperText:
                  'Affiché dans les conversations ; vide = nom d\'utilisateur',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bio,
            maxLength: 500,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Biographie'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _loading ? null : _save,
            child: _loading
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}
