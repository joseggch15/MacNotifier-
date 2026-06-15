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
import '../core/unauthorised_check.dart';
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

    // ---- 1b. Alarma de caida prolongada (offline sostenido) -----------------
    // Escala una consola OFFLINE que lleva >= offlineAlarmMinutes caida a una
    // alarma "estilo despertador". El silenciado por consola se aplica AQUI
    // (al notificar); el estado de offlineSince/alarmed se persiste completo.
    final offline = trackOfflineAlarms(
      consoles: consoles,
      previousSince: s.loadOfflineSince(),
      previousAlarmed: s.loadOfflineAlarmed(),
      alarmAfter: settings.offlineAlarmAfter,
      now: now,
    );
    await s.saveOfflineSince(offline.offlineSince);
    await s.saveOfflineAlarmed(offline.alarmed);
    final offlineAlarmEvents = [
      for (final mac in offline.newAlarms)
        if (!settings.isConsoleMuted(mac.code)) mac,
    ];

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

    // ---- 3. Auditorias sobre DESPACHOS (un solo fetch incremental) ------------
    //   3a. Sobrellenados SFL (despacho > limite del equipo).
    //   3b. UNAUTHORISED sin ID asignado en los lanes vigilados.
    final dispenseAudits = await _syncDispenseAudits(client, s, settings, now);
    final overfills = dispenseAudits.overfills;
    final overfillEvents = [
      for (final o in dispenseAudits.newOverfills)
        if (!settings.isSflProductMuted(o.product)) o,
    ];
    final unauthorised = dispenseAudits.unauthorised;
    final unauthorisedEvents = dispenseAudits.unauthorisedEvents;

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
      unauthorised: unauthorised,
      unauthorisedEvents: unauthorisedEvents,
      offlineSince: offline.offlineSince,
      offlineAlarmEvents: offlineAlarmEvents,
    );
    await s.saveSnapshot(result);
    await s.saveLastError(null);

    if (settings.notificationsEnabled) {
      if (events.isNotEmpty) {
        await NotificationService.instance.showEvents(events, settings);
      }
      if (offlineAlarmEvents.isNotEmpty) {
        await NotificationService.instance.showOfflineAlarms(
          offlineAlarmEvents,
          settings,
          offlineSince: offline.offlineSince,
          now: now,
        );
      }
      if (deliveryEvents.isNotEmpty) {
        await NotificationService.instance
            .showDeliveryEvents(deliveryEvents, settings);
      }
      if (overfillEvents.isNotEmpty) {
        await NotificationService.instance
            .showOverfillEvents(overfillEvents, settings);
      }
      if (unauthorisedEvents.isNotEmpty) {
        await NotificationService.instance
            .showUnauthorisedEvents(unauthorisedEvents, settings);
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

/// Sincroniza los despachos UNA SOLA VEZ desde el watermark compartido y corre
/// sobre ellos las dos auditorias que dependen de despachos:
///
///   * Sobrellenados SFL — cruce contra el mapa de limites del maestro de
///     equipos (refrescado a lo sumo cada kSflLimitsMaxAge).
///   * UNAUTHORISED sin ID — despachos no autorizados sin equipo en los lanes
///     vigilados, con dedup por transicion (igual que entregas).
///
/// Si ninguna de las dos esta activa (o el overfill no tiene limites y el de
/// no autorizados esta apagado) no se gasta la peticion de despachos.
Future<
    ({
      List<OverfillAlert> overfills,
      List<OverfillAlert> newOverfills,
      List<UnauthorisedTxn> unauthorised,
      List<UnauthorisedEvent> unauthorisedEvents,
    })> _syncDispenseAudits(
  AdaptIQClient client,
  AppStore s,
  AppSettings settings,
  DateTime now,
) async {
  // 1. Mapa de limites SFL (solo si se auditan sobrellenados).
  Map<String, double>? limits;
  if (settings.monitorOverfill) {
    limits = s.loadSflLimits();
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
  }
  final overfillEnabled =
      settings.monitorOverfill && limits != null && limits.isNotEmpty;
  final unauthEnabled = settings.monitorUnauthorised;

  if (!overfillEnabled && !unauthEnabled) {
    // Nada que auditar sobre despachos: no se consulta la API.
    return (
      overfills: s.loadOverfillSnapshot(),
      newOverfills: const <OverfillAlert>[],
      unauthorised: sortedOpen(s.loadUnauthorisedOpen().values),
      unauthorisedEvents: const <UnauthorisedEvent>[],
    );
  }

  // 2. Despachos incrementales (un solo fetch para ambas auditorias).
  final watermark = s.dispenseWatermark;
  final since = (watermark ?? now.subtract(kDispenseLookback))
      .subtract(kDeliveryWatermarkOverlap);
  final dispenses = await client.fetchDispenses(updatedFrom: since);

  // 3a. Sobrellenados SFL: dedup one-shot por dispense id. TODOS los detectados
  // se marcan como vistos (silenciados incluidos).
  var overfills = s.loadOverfillSnapshot();
  var newOverfills = const <OverfillAlert>[];
  if (overfillEnabled) {
    final detected = detectOverfills(dispenses: dispenses, limits: limits);
    final seen = s.loadNotifiedOverfillIds();
    newOverfills = [
      for (final o in detected)
        if (!seen.contains(o.dispenseId)) o,
    ];
    await s.saveNotifiedOverfillIds(
      {...seen, for (final o in detected) o.dispenseId},
      now: now,
    );
    final cutoff = now.subtract(const Duration(days: kOverfillKeepDays));
    final byId = <String, OverfillAlert>{
      for (final o in s.loadOverfillSnapshot()) o.dispenseId: o,
      for (final o in detected) o.dispenseId: o,
    };
    overfills = byId.values
        .where((o) => (o.collectedAt ?? now).isAfter(cutoff))
        .toList()
      ..sort((a, b) {
        final ta = a.collectedAt ?? DateTime(0);
        final tb = b.collectedAt ?? DateTime(0);
        return tb.compareTo(ta);
      });
    await s.saveOverfillSnapshot(overfills);
  }

  // 3b. UNAUTHORISED sin ID: transiciones contra el conjunto de abiertos.
  var unauthorised = sortedOpen(s.loadUnauthorisedOpen().values);
  var unauthorisedEvents = const <UnauthorisedEvent>[];
  if (unauthEnabled) {
    final diff = diffUnauthorised(
      previousOpen: s.loadUnauthorisedOpen(),
      fetched: dispenses,
      normalizedLanes: settings.normalizedUnauthorisedLanes,
      now: now,
    );
    await s.saveUnauthorisedOpen(diff.updatedOpen, now: now);
    unauthorised = sortedOpen(diff.updatedOpen.values);
    unauthorisedEvents = diff.events;
  }

  // 4. Watermark al mayor recordUpdatedAt visto (una vez para ambas).
  var maxUpdated = watermark ?? since;
  for (final d in dispenses) {
    final u = d.updatedAt;
    if (u != null && u.isAfter(maxUpdated)) maxUpdated = u;
  }
  await s.saveDispenseWatermark(maxUpdated);

  return (
    overfills: overfills,
    newOverfills: newOverfills,
    unauthorised: unauthorised,
    unauthorisedEvents: unauthorisedEvents,
  );
}
