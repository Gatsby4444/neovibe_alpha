import 'package:flutter/material.dart';
import '../../core/widgets/avatar.dart';
import '../../core/theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/message.dart';
import '../../core/supabase_providers.dart';
import '../../core/utils/formats.dart';
import '../conversations/chat_screen.dart';
import '../conversations/conversations_repository.dart';
import '../conversations/create_group_screen.dart';
import '../stories/stories_bar.dart';
import '../stories/stories_repository.dart';
import 'categories_repository.dart';

/// Filtres prédéfinis du hub (consigne Jay : Tout / Amis / Groupes, plus les
/// catégories personnalisées de l'utilisateur).
enum _BuiltinFilter { all, friends, groups }

/// Cercle — le hub social : stories des amis en haut (2026-08-02), puis
/// conversations des connexions (1-à-1 + groupes) et catégories. Les
/// conversations ping vivent dans le module Ping, qui a son propre onglet
/// depuis le 2026-08-01.
class CircleScreen extends ConsumerStatefulWidget {
  const CircleScreen({super.key});

  @override
  ConsumerState<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends ConsumerState<CircleScreen> {
  _BuiltinFilter _builtin = _BuiltinFilter.all;
  String? _customCategoryId; // non null = catégorie personnalisée active

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider)!;
    final conversations = ref.watch(conversationsProvider);
    final categories = ref.watch(myCategoriesProvider).value ?? [];
    final memberships = ref.watch(categoryMembersProvider).value ?? {};
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cercle'),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_add),
            tooltip: 'Nouveau groupe',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
            ),
          ),
        ],
      ),
      // Le FAB Ping a été RETIRÉ le 2026-08-01 : le module de proximité a
      // désormais son propre onglet dans la barre du bas. Le garder ici en
      // ferait un doublon, et la mécanique fondatrice du produit n'a pas à
      // vivre dans un bouton flottant secondaire.
      body: Column(
        children: [
          // Emplacement réservé depuis le 2026-07-12, occupé le 2026-08-02 :
          // les stories de mes amis, en haut du hub.
          StoriesBar(
            provider: friendStoriesProvider,
            emptyHint:
                'Pas de story pour l\'instant. Publie une Vibe en story '
                'depuis l\'écran d\'envoi.',
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _FilterChip(
                  label: 'Tout',
                  selected:
                      _customCategoryId == null &&
                      _builtin == _BuiltinFilter.all,
                  onTap: () => setState(() {
                    _builtin = _BuiltinFilter.all;
                    _customCategoryId = null;
                  }),
                ),
                _FilterChip(
                  label: 'Amis',
                  selected:
                      _customCategoryId == null &&
                      _builtin == _BuiltinFilter.friends,
                  onTap: () => setState(() {
                    _builtin = _BuiltinFilter.friends;
                    _customCategoryId = null;
                  }),
                ),
                _FilterChip(
                  label: 'Groupes',
                  selected:
                      _customCategoryId == null &&
                      _builtin == _BuiltinFilter.groups,
                  onTap: () => setState(() {
                    _builtin = _BuiltinFilter.groups;
                    _customCategoryId = null;
                  }),
                ),
                for (final category in categories)
                  _FilterChip(
                    label: category.name,
                    selected: _customCategoryId == category.id,
                    onTap: () =>
                        setState(() => _customCategoryId = category.id),
                    onLongPress: () => _confirmDeleteCategory(category),
                  ),
                _FilterChip(
                  label: '+',
                  selected: false,
                  onTap: _createCategory,
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(conversationsProvider);
                ref.invalidate(myCategoriesProvider);
                ref.invalidate(categoryMembersProvider);
                ref.invalidate(friendStoriesProvider);
              },
              child: conversations.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Erreur : $e'),
                    ),
                  ],
                ),
                data: (list) {
                  // Cercle = connexions uniquement ; les conversations ping
                  // (proximité) vivent dans le module Ping.
                  var visible = list
                      .where((c) => c.type != ConversationType.proximity)
                      .toList();
                  visible = switch (_builtin) {
                    _ when _customCategoryId != null =>
                      visible
                          .where(
                            (c) =>
                                memberships[_customCategoryId]?.contains(
                                  c.id,
                                ) ??
                                false,
                          )
                          .toList(),
                    _BuiltinFilter.friends =>
                      visible
                          .where((c) => c.type == ConversationType.direct)
                          .toList(),
                    _BuiltinFilter.groups =>
                      visible
                          .where((c) => c.type == ConversationType.group)
                          .toList(),
                    _BuiltinFilter.all => visible,
                  };
                  if (visible.isEmpty) {
                    return ListView(
                      children: [
                        const SizedBox(height: 100),
                        Icon(
                          Icons.forum_outlined,
                          size: 56,
                          color: context.ghost,
                        ),
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Rien ici pour l\'instant.\nTes conversations avec tes connexions vivent ici.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.muted),
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final conv = visible[index];
                      final last = conv.lastMessage;
                      return ListTile(
                        leading: conv.type == ConversationType.group
                            ? const CircleAvatar(child: Icon(Icons.group))
                            : Avatar(
                                stored: conv.otherMember(me)?.avatarUrl,
                                fallback: Text(
                                  conv
                                      .displayName(me)
                                      .characters
                                      .first
                                      .toUpperCase(),
                                ),
                              ),
                        title: Text(conv.displayName(me)),
                        subtitle: Text(
                          switch (last?.kind) {
                            null => 'Nouvelle conversation',
                            MessageKind.text => last!.body ?? '',
                            MessageKind.image => '📷 Photo',
                            MessageKind.video => '🎥 Vidéo',
                            MessageKind.card => '🃏 Vibe',
                            MessageKind.libraryAdd => '🔒 Vibe en attente',
                            MessageKind.contentShare => '↗️ Contenu partagé',
                          },
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: last == null
                            ? null
                            : Text(
                                shortTime(last.createdAt),
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                        onTap: () => Navigator.of(context)
                            .push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    ChatScreen(conversationId: conv.id),
                              ),
                            )
                            .then((_) => ref.invalidate(conversationsProvider)),
                        onLongPress: categories.isEmpty
                            ? null
                            : () => _assignCategories(conv.id),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouvelle catégorie'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 25, // consigne Jay : 25 caractères max
          decoration: const InputDecoration(hintText: 'Nom de la catégorie'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Créer'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(categoriesRepositoryProvider).create(name);
      ref.invalidate(myCategoriesProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }

  Future<void> _confirmDeleteCategory(ConversationCategory category) async {
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Supprimer « ${category.name} » ?'),
        content: const Text(
          'Les conversations ne sont pas supprimées, juste la catégorie.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (delete != true) return;
    await ref.read(categoriesRepositoryProvider).delete(category.id);
    if (_customCategoryId == category.id) {
      setState(() => _customCategoryId = null);
    }
    ref.invalidate(myCategoriesProvider);
    ref.invalidate(categoryMembersProvider);
  }

  /// Appui long sur une conversation : choisir ses catégories
  /// (multi-appartenance autorisée — consigne Jay).
  Future<void> _assignCategories(String conversationId) async {
    final categories = ref.read(myCategoriesProvider).value ?? [];
    final memberships = ref.read(categoryMembersProvider).value ?? {};
    final selected = {
      for (final c in categories)
        c.id: memberships[c.id]?.contains(conversationId) ?? false,
    };
    final result = await showDialog<Map<String, bool>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Catégories'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final category in categories)
                CheckboxListTile(
                  title: Text(category.name),
                  value: selected[category.id],
                  onChanged: (v) =>
                      setDialogState(() => selected[category.id] = v ?? false),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final repo = ref.read(categoriesRepositoryProvider);
    for (final entry in result.entries) {
      final was = memberships[entry.key]?.contains(conversationId) ?? false;
      if (was != entry.value) {
        await repo.setMembership(entry.key, conversationId, entry.value);
      }
    }
    ref.invalidate(categoryMembersProvider);
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onTap(),
          selectedColor: scheme.primary.withValues(alpha: 0.25),
          showCheckmark: false,
        ),
      ),
    );
  }
}
