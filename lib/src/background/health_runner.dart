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
///
/// Cada ciclo cubre DOS dominios:
///   1. Consolas AdaptMAC (lista completa, es corta).
///   2. Entregas (deliveries) — sincronizacion INCREMENTAL por watermark
///      (`filter: { updatedFrom }`), como el poller de MSGQ: solo viajan las
///      entregas nuevas o editadas desde el ultimo ciclo.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../api/adaptiq_client.dart';
import '../config/app_settings.dart';
import '../core/delivery_check.dart';
import '../core/health_check.dart';
import '../models/delivery.dart';
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
    // ---- 1. Consolas AdaptMAC ------------------------------------------------
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
    await s.saveConditions(current);

    // ---- 2. Entregas (deliveries) ---------------------------------------------
    var deliveries = <Delivery>[];
    var deliveryEvents = <DeliveryEvent>[];
    if (settings.monitorDeliveries) {
      final synced = await _syncDeliveries(client, s, settings, now);
      deliveries = synced.deliveries;
      deliveryEvents = synced.events;
    }

    final result = HealthCheckResult(
      consoles: consoles,
      events: events,
      fetchedAt: now,
      deliveries: deliveries,
      deliveryEvents: deliveryEvents,
    );
    await s.saveSnapshot(result);
    await s.saveLastError(null);

    if (settings.notificationsEnabled) {
      if (events.isNotEmpty) {
        await NotificationService.instance.showEvents(events, settings);
      }
      if (deliveryEvents.isNotEmpty) {
        await NotificationService.instance
            .showDeliveryEvents(deliveryEvents, settings);
      }
    }
    return result;
  } on Object catch (e) {
    await s.saveLastError(e.toString());
    rethrow;
  } finally {
    client.close();
  }
}

/// Sincroniza las entregas desde el watermark, evalua transiciones y mantiene
/// el snapshot local (ventana de kDeliveryKeepDays) que consume la UI.
Future<({List<Delivery> deliveries, List<DeliveryEvent> events})>
    _syncDeliveries(
  AdaptIQClient client,
  AppStore s,
  AppSettings settings,
  DateTime now,
) async {
  final watermark = s.deliveryWatermark;
  final since = (watermark ?? now.subtract(kDeliveryLookback))
      .subtract(kDeliveryWatermarkOverlap);
  final fetched = await client.fetchDeliveries(updatedFrom: since);

  // Diff contra lo ya notificado: re-traer una entrega sin cambios no emite nada.
  final diff = diffDeliveryEvents(
    previous: s.loadDeliveryConditions(),
    fetched: fetched,
    thresholdPct: settings.varianceThresholdPct,
    now: now,
  );
  await s.saveDeliveryConditions(diff.updated, now: now);

  // Snapshot local: las recien traidas REEMPLAZAN por id a las guardadas, y
  // todo lo mas viejo que la ventana se descarta.
  final cutoff = now.subtract(const Duration(days: kDeliveryKeepDays));
  final byId = <String, Delivery>{
    for (final d in s.loadDeliverySnapshot()) d.id: d,
    for (final d in fetched) d.id: d,
  };
  final merged = byId.values
      .where((d) => (d.collectedAt ?? d.updatedAt ?? now).isAfter(cutoff))
      .toList()
    ..sort((a, b) {
      final ta = a.collectedAt ?? a.updatedAt ?? now;
      final tb = b.collectedAt ?? b.updatedAt ?? now;
      return tb.compareTo(ta); // recientes primero
    });
  await s.saveDeliverySnapshot(merged);

  // Avanza el watermark al mayor recordUpdatedAt visto.
  var maxUpdated = watermark ?? since;
  for (final d in fetched) {
    final u = d.updatedAt;
    if (u != null && u.isAfter(maxUpdated)) maxUpdated = u;
  }
  await s.saveDeliveryWatermark(maxUpdated);

  return (deliveries: merged, events: diff.events);
}
