import 'package:permission_handler/permission_handler.dart';

/// **Demander ce que le NATIF dit manquer à la radio — un seul endroit.**
///
/// Sorti de `ping_screen.dart` le 2026-09-24, quand l'arrivée en soirée (test
/// développeur) a eu besoin du même geste : deux copies de la traduction
/// auraient fini par ne plus demander la même chose.
///
/// ⚠️ **On demande ce que le natif dit manquer, on ne le déduit pas.** La liste
/// dépend de la version d'Android — `ACCESS_FINE_LOCATION` sous Android 12,
/// `BLUETOOTH_SCAN` au-dessus — et c'est `BlePermissions` qui la calcule, en
/// interrogeant le système. Écrire ici un test de version reviendrait à
/// décider une deuxième fois de ce qu'Android exige, à un endroit qui ne le
/// sait pas.
Future<void> requestRadioPermissions(
  List<String> missing, {
  bool withNotifications = true,
}) async {
  await [
    ...missing.map(_permissionAndroid).nonNulls,
    if (withNotifications) Permission.notification,
  ].request();
}

/// Traduit un nom de permission Android en permission `permission_handler`.
///
/// ⚠️ **Traduction, pas décision.** Les seuls noms qui arrivent ici sont ceux
/// que `BlePermissions.required()` a produits côté natif. `BLUETOOTH` et
/// `BLUETOOTH_ADMIN` (Android ≤ 11) n'en font jamais partie en pratique : ce
/// sont des permissions de niveau *normal*, accordées à l'installation, donc
/// `checkSelfPermission` ne les déclare jamais manquantes. On rend `null`
/// plutôt que de lever : un nom inconnu ne doit pas empêcher de demander les
/// autres.
Permission? _permissionAndroid(String nom) => switch (nom) {
  'android.permission.BLUETOOTH_SCAN' => Permission.bluetoothScan,
  'android.permission.BLUETOOTH_ADVERTISE' => Permission.bluetoothAdvertise,
  // ⚠️ `BLUETOOTH_CONNECT` a été retirée du natif le 2026-08-27, avec le bloc
  // GATT. Sa traduction part avec elle : la garder pour « au cas où » ferait
  // demander une permission que rien ne réclame plus.
  'android.permission.ACCESS_FINE_LOCATION' => Permission.locationWhenInUse,
  _ => null,
};
