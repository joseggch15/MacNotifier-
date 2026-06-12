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
/// Cada ciclo cubre TRES dominios:
///   1. Consolas AdaptMAC (lista completa, es corta).
///   2. Entregas (deliveries) — sincronizacion INCREMENTAL por watermark
///      (`filter: { updatedFrom }`), como el poller de MSGQ: solo viajan las
///      entregas nuevas o editadas desde el ultimo ciclo.
///   3. Sobrellenados SFL — despachos incrementales cruzados contra el mapa de
///      limites (refrescado del maestro de equipos a lo sumo una vez al dia).
///
/// El "silenciado por producto" se aplica AL NOTIFICAR (y al armar los
/// eventos del resultado), no al evaluar: el estado de dedup se mantiene
/// completo, asi que silenciar/des-silenciar un producto no re-dispara
/// alertas viejas.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../api/adaptiq_client.dart';
import '../config/app_settings.dart';
import '../core/delivery_check.dart';
import '../core/health_check.dart';
import '../core/sfl_check.dart';
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
    equipmentField: s.cachedEquipmentField,
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
    // El silenciado por consola se aplica a los EVENTOS (lo que se notifica);
    // el estado de dedup se guarda completo, asi que des-silenciar un MAC no
    // re-dispara sus alertas viejas.
    final events = [
      for (final e in diffEvents(
        previous: previous,
        consoles: consoles,
        current: current,
        now: now,
      ))
        if (!settings.isConsoleMuted(e.console.code)) e,
    ];
    await s.saveConditions(current);

    // ---- 2. Entregas (deliveries) ---------------------------------------------
    var deliveries = <Delivery>[];
    var deliveryEvents = <DeliveryEvent>[];
    if (settings.monitorDeliveries) {
      final synced = await _syncDeliveries(client, s, settings, now);
      deliveries = synced.deliveries;
      // El silenciado por producto se aplica a los EVENTOS (lo que se
      // notifica), no al snapshot: la pestaña Entregas sigue mostrando todo.
      deliveryEvents = [
        for (final e in synced.events)
          if (!settings.isDeliveryProductMuted(e.delivery.product)) e,
      ];
    }

    // ---- 3. Sobrellenados SFL ----------------------------------------------------
    var overfills = <OverfillAlert>[];
    var overfillEvents = <OverfillAlert>[];
    if (settings.monitorOverfill) {
      final synced = await _syncOverfills(client, s, settings, now);
      overfills = synced.overfills;
      overfillEvents = [
        for (final o in synced.newAlerts)
          if (!settings.isSflProductMuted(o.product)) o,
      ];
    }

    // Acumula los productos vistos para la UI de silenciado.
    await s.addKnownProducts([
      for (final d in deliveries) d.product,
      for (final o in overfills) o.product,
    ]);

    final result = HealthCheckResult(
      consoles: consoles,
      events: events,
      fetchedAt: now,
      deliveries: deliveries,
      deliveryEvents: deliveryEvents,
      overfills: overfills,
      overfillEvents: overfillEvents,
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
      if (overfillEvents.isNotEmpty) {
        await NotificationService.instance
            .showOverfillEvents(overfillEvents, settings);
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

/// Sincroniza despachos desde el watermark, los cruza contra el mapa de
/// limites SFL (refrescado a lo sumo cada kSflLimitsMaxAge) y devuelve la
/// ventana local + los sobrellenados NUEVOS (no procesados antes).
Future<({List<OverfillAlert> overfills, List<OverfillAlert> newAlerts})>
    _syncOverfills(
  AdaptIQClient client,
  AppStore s,
  AppSettings settings,
  DateTime now,
) async {
  // 1. Mapa de limites SFL (la consulta pesada: maestro de equipos completo).
  var limits = s.loadSflLimits();
  final fetchedAt = s.sflLimitsFetchedAt;
  if (fetchedAt == null || now.difference(fetchedAt) > kSflLimitsMaxAge) {
    try {
      final fresh = await client.fetchSflLimits();
      await s.saveSflLimits(fresh,
          equipmentField: client.equipmentField ?? '', now: now);
      if (fresh != null) {
        limits = fresh;
        await s.addKnownProducts(
            [for (final key in fresh.keys) key.split('|').last]);
      }
    } on ApiException {
      // Refresco fallido: se sigue auditando con el mapa cacheado (si existe).
    }
  }
  if (limits == null || limits.isEmpty) {
    // Tenant sin conexion de equipos (o maestro sin SFL): nada que auditar.
    return (
      overfills: s.loadOverfillSnapshot(),
      newAlerts: const <OverfillAlert>[],
    );
  }

  // 2. Despachos incrementales.
  final watermark = s.dispenseWatermark;
  final since = (watermark ?? now.subtract(kDispenseLookback))
      .subtract(kDeliveryWatermarkOverlap);
  final dispenses = await client.fetchDispenses(updatedFrom: since);

  // 3. Deteccion + dedup one-shot por dispense id. TODOS los detectados se
  // marcan como vistos (silenciados incluidos): des-silenciar un producto no
  // debe replantear sobrellenados viejos.
  final detected = detectOverfills(dispenses: dispenses, limits: limits);
  final seen = s.loadNotifiedOverfillIds();
  final newAlerts = [
    for (final o in detected)
      if (!seen.contains(o.dispenseId)) o,
  ];
  await s.saveNotifiedOverfillIds(
    {...seen, for (final o in detected) o.dispenseId},
    now: now,
  );

  // 4. Snapshot local (ventana kOverfillKeepDays, reemplazo por id).
  final cutoff = now.subtract(const Duration(days: kOverfillKeepDays));
  final byId = <String, OverfillAlert>{
    for (final o in s.loadOverfillSnapshot()) o.dispenseId: o,
    for (final o in detected) o.dispenseId: o,
  };
  final merged = byId.values
      .where((o) => (o.collectedAt ?? now).isAfter(cutoff))
      .toList()
    ..sort((a, b) {
      final ta = a.collectedAt ?? DateTime(0);
      final tb = b.collectedAt ?? DateTime(0);
      return tb.compareTo(ta);
    });
  await s.saveOverfillSnapshot(merged);

  // 5. Watermark al mayor recordUpdatedAt visto.
  var maxUpdated = watermark ?? since;
  for (final d in dispenses) {
    final u = d.updatedAt;
    if (u != null && u.isAfter(maxUpdated)) maxUpdated = u;
  }
  await s.saveDispenseWatermark(maxUpdated);

  return (overfills: merged, newAlerts: newAlerts);
}
