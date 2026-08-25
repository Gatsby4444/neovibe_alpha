import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **Le consommateur décide de ce que « différent » veut dire.**
///
/// ## Le problème que ce fichier supprime
///
/// En Dart, l'égalité d'une `List` est **l'identité**. Deux listes au contenu
/// rigoureusement identique ne sont pas égales. Un provider dérivé qui refabrique
/// une liste — `all.where(...).toList()` — produit donc un nouvel objet à chaque
/// passage, et Riverpod notifie **tous** ses abonnés, même quand l'utilisateur
/// verrait exactement la même chose.
///
/// Mesuré le 2026-08-25 (checkup `RAPPELS.md` #52) : une connexion *partielle*
/// qui changeait réveillait la liste des connexions *complètes*, observée par
/// **7 écrans de 6 modules**. Rien ne s'affichait de faux — c'est un coût qui ne
/// lève aucune erreur, et qui ne se voit qu'en comptant.
///
/// ## Pourquoi ici, et pas dans la couche d'acquisition
///
/// Règle de Jay du 2026-08-20 : *qui acquiert publie fidèlement, qui consomme
/// décide*. La tentation est de faire taire la source — « ne republie que si ça
/// a changé ». C'est précisément ce qu'il ne faut pas : la source ne connaît pas
/// les champs que ses lecteurs affichent, et deux lecteurs n'ont pas la même
/// définition de « différent ». Le tri se fait **en aval**, une fois par
/// consommateur.
///
/// ## Usage
///
/// ```dart
/// class FullConnections extends Notifier<List<Connection>>
///     with DerivedList<Connection> {
///   @override
///   List<Connection> build() => …;   // recalcul libre
/// }
/// ```
///
/// ⚠️ **Le type de l'élément DOIT avoir une égalité de valeur** — sinon
/// [listEquals] retombe sur l'identité et ce mixin ne sert à rien, en silence.
/// C'est la raison pour laquelle les modèles de `core/models/` ont reçu leur
/// `==` le 2026-08-25.
mixin DerivedList<T> on Notifier<List<T>> {
  @override
  bool updateShouldNotify(List<T> previous, List<T> next) =>
      !listEquals(previous, next);
}

/// La même chose pour un `Set`, qui souffre du même défaut.
mixin DerivedSet<T> on Notifier<Set<T>> {
  @override
  bool updateShouldNotify(Set<T> previous, Set<T> next) =>
      !setEquals(previous, next);
}

/// Une liste dont **l'égalité est celle de son contenu**.
///
/// ## Pourquoi ce type existe À CÔTÉ de [DerivedList]
///
/// [DerivedList] s'applique à un `Notifier`, et Riverpod 3 **sans génération de
/// code n'offre pas de `Notifier` familial** (constaté le 2026-08-25 : la
/// fabrique attend `NotifierT Function(Ref, ArgT)`, réservée au codegen). Pour
/// une vue paramétrée — « les messages de CETTE conversation » — il reste
/// `Provider.family`, dont l'`updateShouldNotify` compare avec `==`.
///
/// D'où ce type : il donne à `==` le sens qu'on veut, et un `Provider.family`
/// redevient silencieux quand son contenu ne change pas.
///
/// **Lequel utiliser** : `Notifier` + [DerivedList] pour une vue **sans
/// paramètre** ; `Provider.family` + [ValueList] pour une vue **paramétrée**.
///
/// ⚠️ Comme pour [DerivedList], le type de l'élément doit avoir une égalité de
/// valeur, sinon la comparaison retombe sur l'identité — sans rien signaler.
@immutable
class ValueList<T> extends Iterable<T> {
  const ValueList(this._items);

  const ValueList.empty() : _items = const [];

  final List<T> _items;

  @override
  Iterator<T> get iterator => _items.iterator;

  @override
  int get length => _items.length;

  T operator [](int index) => _items[index];

  /// La liste nue, pour les rares API qui l'exigent.
  List<T> get items => _items;

  @override
  bool operator ==(Object other) =>
      other is ValueList<T> && listEquals(other._items, _items);

  @override
  int get hashCode => Object.hashAll(_items);
}
