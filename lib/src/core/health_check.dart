/// Evaluacion de salud de consolas AdaptMAC y deteccion de TRANSICIONES.
///
/// Las condiciones son el port de `detect_adaptmac_alerts` (msgq/core/alerts.py):
///
///   * `keyBypass`  — consola en modo bypass de autorizacion (CRITICO).
///   * `offline`    — el flag `online` de la API esta en falso (ALERTA).
///   * `stale`      — online, pero sin comunicacion exitosa hace mas de
///                    `staleAfter` (solo evaluable si el tenant expone
///                    `lastSuccessfulComms`).
///
/// A diferencia del dashboard (que pinta el estado ACTUAL en cada refresco),
/// el movil notifica: lo que importa es el CAMBIO de estado. `diffEvents`
/// compara el estado actual contra el ultimo snapshot persistido y emite un
/// evento solo cuando una condicion aparece o desaparece — eso es lo que
/// elimina las notificaciones duplicadas entre polls (y entre el poll de
/// primer plano y el de background, que comparten el mismo snapshot).
///
/// Dart puro: sin dependencias de Flutter, corre en cualquier isolate y es
/// testeable sin emulador.
library;

import '../models/adapt_mac.dart';
import '../models/delivery.dart';
import 'delivery_check.dart';
import 'flow_temp_check.dart';
import 'sfl_check.dart';
import 'unauthorised_check.dart';

/// Orden del enum = severidad (se usa para ordenar eventos y la lista de UI).
enum ConsoleCondition { keyBypass, offline, stale }

/// Una condicion que APARECIO (`active = true`) o se DESPEJO (`active = false`)
/// en una consola entre dos chequeos consecutivos.
class ConsoleEvent {
  const ConsoleEvent({
    required this.console,
    required this.condition,
    required this.active,
    required this.at,
  });

  final AdaptMac console;
  final ConsoleCondition condition;
  final bool active;
  final DateTime at;
}

/// Resultado de un ciclo completo de chequeo (lo que consume la UI y el
/// notificador). `events` vacio = nada cambio desde el ciclo anterior.
class HealthCheckResult {
  const HealthCheckResult({
    required this.consoles,
    required this.events,
    required this.fetchedAt,
    this.deliveries = const [],
    this.deliveryEvents = const [],
    this.overfills = const [],
    this.overfillEvents = const [],
    this.unauthorised = const [],
    this.unauthorisedEvents = const [],
    this.flowTempAlerts = const [],
    this.flowTempEvents = const [],
    this.offlineSince = const {},
    this.offlineAlarmEvents = const [],
  });

  final List<AdaptMac> consoles;
  final List<ConsoleEvent> events;
  final DateTime fetchedAt;

  /// Entregas recientes (ventana local de kDeliveryKeepDays) para la UI.
  final List<Delivery> deliveries;
  final List<DeliveryEvent> deliveryEvents;

  /// Sobrellenados SFL recientes (ventana local de kOverfillKeepDays).
  final List<OverfillAlert> overfills;

  /// Sobrellenados NUEVOS de este ciclo (ya filtrados por silenciado).
  final List<OverfillAlert> overfillEvents;

  /// Despachos UNAUTHORISED sin ID ABIERTOS (para la pestaña dedicada).
  final List<UnauthorisedTxn> unauthorised;

  /// Transiciones de no autorizados de este ciclo (nuevos / asignados).
  final List<UnauthorisedEvent> unauthorisedEvents;

  /// Anomalias de caudal/temperatura recientes (ventana kFlowTempKeepDays).
  final List<FlowTempAlert> flowTempAlerts;

  /// Anomalias de caudal/temperatura NUEVAS de este ciclo (ya filtradas por
  /// silenciado): lo que se notifica.
  final List<FlowTempAlert> flowTempEvents;

  /// code -> instante en que la consola se observo OFFLINE por primera vez
  /// (para mostrar "lleva N min sin conexion" y disparar la alarma).
  final Map<String, DateTime> offlineSince;

  /// Consolas que ACABAN de cruzar el umbral de alarma este ciclo (ya
  /// filtradas por silenciado): la alarma "estilo despertador".
  final List<AdaptMac> offlineAlarmEvents;

  int get total => consoles.length;
  int get onlineCount => consoles.where((c) => c.online == true).length;
  int get offlineCount => consoles.where((c) => c.online == false).length;
  int get bypassCount => consoles.where((c) => c.keyBypass == true).length;

  int get unconfirmedDeliveries =>
      deliveries.where((d) => d.isUnconfirmed).length;
}

/// Condiciones activas de UNA consola (mismas reglas que MSGQ: el stale solo
/// se evalua cuando la consola se reporta online y hay fecha de comunicacion).
Set<ConsoleCondition> conditionsFor(
  AdaptMac mac, {
  required Duration staleAfter,
  required DateTime now,
}) {
  final out = <ConsoleCondition>{};
  if (mac.keyBypass == true) out.add(ConsoleCondition.keyBypass);
  if (mac.online == false) {
    out.add(ConsoleCondition.offline);
  } else {
    final last = mac.lastSuccessfulComms;
    if (last != null && now.difference(last) > staleAfter) {
      out.add(ConsoleCondition.stale);
    }
  }
  return out;
}

/// Mapa code -> condiciones activas de toda la flota de consolas.
Map<String, Set<ConsoleCondition>> evaluateAll(
  List<AdaptMac> consoles, {
  required Duration staleAfter,
  required DateTime now,
}) {
  return {
    for (final mac in consoles)
      mac.code: conditionsFor(mac, staleAfter: staleAfter, now: now),
  };
}

/// Compara el estado actual contra el snapshot anterior y devuelve los
/// eventos (condiciones que aparecieron o se despejaron), ordenados por
/// severidad.
///
/// `previous == null` significa PRIMER chequeo (sin snapshot persistido): toda
/// condicion activa se reporta — quien instala el monitor quiere enterarse de
/// una consola que YA esta caida, no solo de las proximas caidas.
///
/// Las consolas que desaparecen del maestro se descartan en silencio (retiradas
/// del FMS, no una anomalia de conexion).
List<ConsoleEvent> diffEvents({
  required Map<String, Set<ConsoleCondition>>? previous,
  required List<AdaptMac> consoles,
  required Map<String, Set<ConsoleCondition>> current,
  required DateTime now,
}) {
  final prev = previous ?? const <String, Set<ConsoleCondition>>{};
  final events = <ConsoleEvent>[];
  for (final mac in consoles) {
    final was = prev[mac.code] ?? const <ConsoleCondition>{};
    final isNow = current[mac.code] ?? const <ConsoleCondition>{};
    for (final c in isNow.difference(was)) {
      events.add(ConsoleEvent(console: mac, condition: c, active: true, at: now));
    }
    for (final c in was.difference(isNow)) {
      events.add(ConsoleEvent(console: mac, condition: c, active: false, at: now));
    }
  }
  events.sort((a, b) {
    if (a.active != b.active) return a.active ? -1 : 1; // alzas primero
    return a.condition.index.compareTo(b.condition.index);
  });
  return events;
}

/// Severidad agregada de una consola para ordenar la lista de la UI:
/// 0 = bypass, 1 = offline, 2 = stale, 3 = sana.
int severityRank(Set<ConsoleCondition> conditions) {
  if (conditions.isEmpty) return ConsoleCondition.values.length;
  return conditions.map((c) => c.index).reduce((a, b) => a < b ? a : b);
}

/// Resultado del seguimiento de caidas PROLONGADAS (offline sostenido).
class OfflineAlarmResult {
  const OfflineAlarmResult({
    required this.offlineSince,
    required this.alarmed,
    required this.newAlarms,
  });

  /// code -> instante de la primera observacion offline (a persistir).
  final Map<String, DateTime> offlineSince;

  /// Consolas YA en estado de alarma (cruzaron el umbral): el dedup por
  /// episodio — mientras siga offline no se vuelve a alarmar.
  final Set<String> alarmed;

  /// Consolas que cruzaron el umbral EN ESTE ciclo (a notificar).
  final List<AdaptMac> newAlarms;
}

/// Mantiene, para cada consola OFFLINE, desde cuando lo esta, y decide cuales
/// acaban de superar [alarmAfter] (sin haberlas alarmado antes en este mismo
/// episodio de caida).
///
/// El silenciado NO se aplica aqui: igual que el resto del motor, el estado de
/// dedup se mantiene completo y el filtrado por consola silenciada se hace al
/// notificar. Una consola que vuelve ONLINE se borra de ambos conjuntos, de
/// modo que una caida futura re-arma la alarma.
OfflineAlarmResult trackOfflineAlarms({
  required List<AdaptMac> consoles,
  required Map<String, DateTime> previousSince,
  required Set<String> previousAlarmed,
  required Duration alarmAfter,
  required DateTime now,
}) {
  final since = <String, DateTime>{};
  final alarmed = <String>{};
  final newAlarms = <AdaptMac>[];
  for (final mac in consoles) {
    if (mac.online != false) continue; // online o desconocido: no es caida
    final start = previousSince[mac.code] ?? now;
    since[mac.code] = start;
    final wasAlarmed = previousAlarmed.contains(mac.code);
    if (now.difference(start) >= alarmAfter) {
      alarmed.add(mac.code);
      if (!wasAlarmed) newAlarms.add(mac);
    } else if (wasAlarmed) {
      // Conserva el flag (reloj hacia atras u otra anomalia): no re-dispara.
      alarmed.add(mac.code);
    }
  }
  return OfflineAlarmResult(
      offlineSince: since, alarmed: alarmed, newAlarms: newAlarms);
}
