/// Ciclo completo de chequeo de salud — el corazon compartido del monitor.
///
/// La MISMA funcion corre en dos contextos:
///
///   * Primer plano: el provider de Riverpod la invoca cada `pollSeconds`
///     (20 s por defecto, igual que el dashboard de escritorio MSGQ).
///   * Segundo plano: el callback de Workmanager la invoca cada
///     `backgroundMinutes` (15-30 min) con la app cerrada.
///
/// Ambos contextos comparten el snapshot persistido en shared_preferences, asi
/// que una caida notificada por el worker NO se vuelve a notificar cuando el
/// usuario abre la app (y viceversa): solo las transiciones generan eventos.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../api/adaptiq_client.dart';
import '../core/health_check.dart';
import '../notifications/notification_service.dart';
import '../storage/app_store.dart';

/// La app aun no tiene token configurado: no hay nada que chequear.
class NotConfiguredException implements Exception {
  const NotConfiguredException();
  @override
  String toString() => 'Token de la API no configurado.';
}

Future<HealthCheckResult> runHealthCheck({AppStore? store}) async {
  final s = store ?? AppStore(await SharedPreferences.getInstance());
  // Relee del disco lo que el OTRO isolate (worker o app) haya escrito.
  await s.reload();
  final settings = s.loadSettings();
  if (!settings.isConfigured) throw const NotConfiguredException();

  final client = AdaptIQClient(
    settings,
    siteId: s.cachedSiteId,
    knownOptionalFields: s.cachedAdaptMacFields,
  );
  try {
    final consoles = await client.fetchAdaptMacs();
    final now = DateTime.now().toUtc();

    // Persiste los descubrimientos para que el proximo arranque (sobre todo el
    // del isolate de background) no gaste peticiones en re-descubrir.
    await s.saveCachedSiteId(client.siteId);
    await s.saveCachedAdaptMacFields(client.discoveredOptionalFields);

    final previous = s.loadConditions();
    final current = evaluateAll(consoles, staleAfter: settings.staleAfter, now: now);
    final events = diffEvents(
      previous: previous,
      consoles: consoles,
      current: current,
      now: now,
    );

    final result =
        HealthCheckResult(consoles: consoles, events: events, fetchedAt: now);
    await s.saveConditions(current);
    await s.saveSnapshot(result);
    await s.saveLastError(null);

    if (settings.notificationsEnabled && events.isNotEmpty) {
      await NotificationService.instance.showEvents(events, settings);
    }
    return result;
  } on Object catch (e) {
    await s.saveLastError(e.toString());
    rethrow;
  } finally {
    client.close();
  }
}
