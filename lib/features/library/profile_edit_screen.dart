import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../core/typography.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/avatar.dart';
import '../profile/avatar_service.dart';
import '../../core/models/profile.dart';
import '../../core/supabase_providers.dart';
import '../profile/profile_repository.dart';

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
  late final _mention = TextEditingController(
    text: widget.profile.specialMention ?? '',
  );
  late var _mentionPublique = widget.profile.specialMentionPublic;

  /// Les octets recadrés en attente d'enregistrement. La photo n'est déposée
  /// qu'à la validation : renoncer à l'écran ne doit rien avoir changé.
  Uint8List? _newAvatar;

  /// L'utilisateur a demandé le retrait de sa photo.
  var _removeAvatar = false;

  var _loading = false;

  @override
  void dispose() {
    _username.dispose();
    _tagName.dispose();
    _bio.dispose();
    _mention.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final bytes = await ref.read(avatarServiceProvider).pickAndCrop(context);
    if (bytes != null && mounted) {
      setState(() {
        _newAvatar = bytes;
        _removeAvatar = false;
      });
    }
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
    try {
      // La photo est déposée (ou retirée) par le service, qui possède toute la
      // séquence : chemin versionné, suppression de l'ancien fichier, mise à
      // jour du profil. L'écran ne fait que dire CE QU'IL VEUT.
      final avatar = ref.read(avatarServiceProvider);
      if (_newAvatar != null) {
        await avatar.upload(_newAvatar!);
      } else if (_removeAvatar) {
        await avatar.remove();
      }
      final tagName = _tagName.text.trim();
      final bio = _bio.text.trim();
      await ref
          .read(profileRepositoryProvider)
          .updateIdentity(displayName: username, tagName: tagName, bio: bio);
      // ⚠️ Deux écritures, et c'est volontaire : l'identité et la mention n'ont
      // ni le même public ni les mêmes règles. Les fondre dans une seule
      // requête ferait de la mention un détail de l'identité.
      await ref
          .read(profileRepositoryProvider)
          .updateSpecialMention(
            mention: _mention.text.trim(),
            public: _mentionPublique,
          );
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
              // Une image tout juste recadrée prime sur celle du serveur ;
              // un retrait demandé prime sur les deux.
              child: _newAvatar != null
                  ? CircleAvatar(
                      radius: 48,
                      backgroundImage: MemoryImage(_newAvatar!),
                    )
                  : Avatar(
                      radius: 48,
                      stored: _removeAvatar ? null : widget.profile.avatarUrl,
                      fallback: const Icon(Icons.add_a_photo, size: 30),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _pickAvatar,
              child: Text(
                widget.profile.avatarUrl == null && _newAvatar == null
                    ? 'Ajouter une photo'
                    : 'Changer la photo',
              ),
            ),
          ),
          // ⚠️ Retirer sa photo était IMPOSSIBLE avant le 2026-08-13 : la mise
          // à jour employait l'entrée conditionnelle `'avatar_url': ?value`,
          // qui omet la colonne quand la valeur est nulle. On pouvait changer,
          // jamais enlever — et l'écran enregistrait sans erreur, donc rien ne
          // le disait.
          if (!_removeAvatar &&
              (widget.profile.avatarUrl != null || _newAvatar != null))
            Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _newAvatar = null;
                  _removeAvatar = true;
                }),
                child: Text(
                  'Retirer la photo',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          const SizedBox(height: 12),
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
            decoration: const InputDecoration(
              labelText: 'Biographie',
              helperText: 'Lue par tes amis, sur ton profil',
            ),
          ),
          const SizedBox(height: NeoSpace.xxl),

          // ⚠️ **Séparée de la bio par un vrai blanc et un titre.** Les deux
          // sont du texte libre sur soi : collées, on les remplirait pareil, et
          // on écrirait pour ses amis un texte que des inconnus vont lire.
          Text('Ta mention spéciale', style: context.sectionTitle),
          const SizedBox(height: NeoSpace.sm),
          Text(
            'Une phrase pour les gens que tu croises sans les connaître : '
            'ce que tu cherches, ce que tu fais là, ton humeur du jour.',
            style: TextStyle(color: context.muted),
          ),
          const SizedBox(height: NeoSpace.md),
          TextField(
            controller: _mention,
            maxLength: 90,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Mention spéciale',
              hintText: 'Cherche un binôme pour le TP de physique',
            ),
          ),
          SwitchListTile(
            value: _mentionPublique,
            onChanged: (v) => setState(() => _mentionPublique = v),
            contentPadding: EdgeInsets.zero,
            title: const Text('La montrer aux inconnus croisés'),
            subtitle: Text(
              _mentionPublique
                  ? 'Visible dans le Ping par les gens que tu croises.'
                  : 'Toi seul la vois pour le moment.',
            ),
          ),
          const SizedBox(height: NeoSpace.xl),
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
