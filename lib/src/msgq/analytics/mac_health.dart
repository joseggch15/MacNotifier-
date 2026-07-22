/// Salud de consolas AdaptMAC: trazabilidad de caidas y fallas — port de
/// `msgq/core/mac_health.py`.
///
/// Opera sobre el historial OBSERVADO ([MacEvent]) y el maestro actual, y
/// responde las preguntas del auditor:
///
///   * Frecuencia de caidas por consola y en el tiempo.
///   * Que fallas se presentan mas, dentro de la taxonomia observable — la API
///     no expone codigos de falla del hardware.
///   * En que fechas hubo mas caidas y cual fue la falla dominante ese dia.
///   * Episodios caida -> recuperacion con su duracion.
///
/// Diferencia con el resto del notificador: `health_check.dart` evalua el
/// estado ACTUAL para notificar transiciones; esto es el HISTORICO acumulado,
/// que es otra pregunta y necesita otra tabla.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../../models/adapt_mac.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/mac_event.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';

/// Un corte de conexion, de la caida a la recuperacion.
class MacOutage {
  const MacOutage({
    required this.code,
    this.description,
    this.droppedAt,
    this.recoveredAt,
    this.durationMinutes,
    required this.ongoing,
  });

  final String code;
  final String? description;

  /// `null` cuando la consola ya estaba caida y no se conoce el inicio.
  final DateTime? droppedAt;

  final DateTime? recoveredAt;

  /// `null` cuando no se puede medir (sin inicio conocido, o corte cerrado sin
  /// recuperacion observada).
  final double? durationMinutes;

  /// El corte sigue abierto.
  final bool ongoing;
}

/// Resumen por consola.
class MacConsoleSummary {
  const MacConsoleSummary({
    required this.code,
    this.description,
    required this.drops,
    required this.commsFailures,
    required this.bypassEvents,
    required this.events,
    this.lastDrop,
    this.lastFailure,
    this.onlineNow,
  });

  final String code;
  final String? description;
  final int drops;
  final int commsFailures;
  final int bypassEvents;
  final int events;
  final DateTime? lastDrop;
  final DateTime? lastFailure;

  /// Estado vigente segun el maestro. `null` = la consola ya no esta en el
  /// maestro, o el tenant no informa el flag.
  final bool? onlineNow;
}

/// Resumen de un dia.
class MacDaySummary {
  const MacDaySummary({
    required this.day,
    required this.drops,
    required this.commsFailures,
    required this.bypassEvents,
    required this.mainFault,
    required this.consolesAffected,
  });

  final DateTime day;
  final int drops;
  final int commsFailures;
  final int bypassEvents;

  /// Falla dominante del dia.
  final MacEventKind mainFault;

  final int consolesAffected;

  int get total => drops + commsFailures + bypassEvents;
}

/// Cuantas veces se presenta cada tipo de falla.
class MacFaultBreakdown {
  const MacFaultBreakdown({
    required this.kind,
    required this.events,
    required this.consolesAffected,
    this.lastEvent,
  });

  final MacEventKind kind;
  final int events;
  final int consolesAffected;
  final DateTime? lastEvent;
}

/// Punto de la serie temporal, con el desglose por tipo de falla.
class MacFaultPoint {
  const MacFaultPoint({
    required this.period,
    required this.drops,
    required this.commsFailures,
    required this.bypassEvents,
  });

  final DateTime period;
  final int drops;
  final int commsFailures;
  final int bypassEvents;

  int get total => drops + commsFailures + bypassEvents;
}

/// Consola inestable: demasiadas caidas en la ventana movil reciente.
class MacFlapping {
  const MacFlapping({
    required this.code,
    this.description,
    required this.drops,
    this.lastDrop,
  });

  final String code;
  final String? description;
  final int drops;
  final DateTime? lastDrop;
}

class MacHealthKpis {
  const MacHealthKpis({
    required this.consoles,
    required this.onlineNow,
    required this.drops,
    required this.commsFailures,
    required this.medianOutageMinutes,
    this.worstConsole,
    required this.worstConsoleDrops,
    required this.flapping,
  });

  final int consoles;
  final int onlineNow;
  final int drops;
  final int commsFailures;

  /// MEDIANA de la duracion de los cortes, no media: un unico corte de tres
  /// dias arrastraria el promedio y haria parecer cronica una red sana.
  final double medianOutageMinutes;

  final String? worstConsole;
  final int worstConsoleDrops;
  final int flapping;
}

// ===========================================================================
// Auditoria
// ===========================================================================

class MacHealthAudit {
  const MacHealthAudit._({
    required this.events,
    required this.outages,
    required this.byConsole,
    required this.byDay,
    required this.faults,
    required this.flapping,
    required this.kpis,
  });

  /// Eventos del rango, del mas reciente al mas antiguo.
  final List<MacEvent> events;

  final List<MacOutage> outages;
  final List<MacConsoleSummary> byConsole;
  final List<MacDaySummary> byDay;
  final List<MacFaultBreakdown> faults;
  final List<MacFlapping> flapping;
  final MacHealthKpis kpis;

  static MacHealthAudit run({
    required List<MacEvent> history,
    List<AdaptMac> consoles = const [],
    DateTime? from,
    DateTime? to,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final scoped = filterRange(history, from: from, to: to);
    final outages = outagesOf(scoped, consoles: consoles, now: at);
    final flaps = flappingOf(scoped, now: at);
    final drops =
        scoped.where((e) => e.kind == MacEventKind.offline).toList();
    final failures =
        scoped.where((e) => e.kind == MacEventKind.failedComms).length;

    final dropsByConsole = <String, int>{};
    for (final e in drops) {
      dropsByConsole[e.code] = (dropsByConsole[e.code] ?? 0) + 1;
    }
    final worst = dropsByConsole.entries.fold<MapEntry<String, int>?>(
        null, (acc, e) => acc == null || e.value > acc.value ? e : acc);

    final durations = outages
        .map((o) => o.durationMinutes)
        .whereType<double>()
        .toList();

    return MacHealthAudit._(
      events: List.unmodifiable(
          scoped.toList()..sort((a, b) => b.ts.compareTo(a.ts))),
      outages: outages,
      byConsole: byConsoleOf(scoped, consoles: consoles),
      byDay: byDayOf(scoped),
      faults: faultBreakdownOf(scoped),
      flapping: flaps,
      kpis: MacHealthKpis(
        consoles: consoles.length,
        onlineNow: consoles.where((c) => c.online == true).length,
        drops: drops.length,
        commsFailures: failures,
        medianOutageMinutes:
            durations.isEmpty ? 0 : roundTo(median(durations)!, 1),
        worstConsole: worst?.key,
        worstConsoleDrops: worst?.value ?? 0,
        flapping: flaps.length,
      ),
    );
  }
}

/// Eventos dentro del rango. [to] es inclusivo hasta el final del dia.
List<MacEvent> filterRange(
  List<MacEvent> history, {
  DateTime? from,
  DateTime? to,
}) {
  final end = to == null
      ? null
      : DateTime.utc(to.year, to.month, to.day).add(const Duration(days: 1));
  return history.where((e) {
    if (from != null && e.ts.isBefore(from.toUtc())) return false;
    if (end != null && !e.ts.isBefore(end)) return false;
    return true;
  }).toList(growable: false);
}

/// Episodios de desconexion: cada caida emparejada con la siguiente
/// recuperacion de la MISMA consola.
///
/// Con el maestro a mano, ademas SINTETIZA el corte en curso de toda consola
/// que este caida AHORA sin caida abierta en el historial. Es el caso tipico de
/// una consola que ya estaba caida antes de que la app empezara a observar: el
/// corte arranca en su `lastSuccessfulComms`, que el dispositivo congela al
/// caer. Sin esto, la consola mas problematica del sitio no tendria episodio.
List<MacOutage> outagesOf(
  List<MacEvent> history, {
  List<AdaptMac> consoles = const [],
  DateTime? now,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  final byConsole = <String, List<MacEvent>>{};
  for (final e in history) {
    if (e.kind != MacEventKind.offline && e.kind != MacEventKind.online) {
      continue;
    }
    byConsole.putIfAbsent(e.code, () => <MacEvent>[]).add(e);
  }

  final out = <MacOutage>[];
  final openConsoles = <String>{};
  for (final entry in byConsole.entries) {
    final flips = entry.value..sort((a, b) => a.ts.compareTo(b.ts));
    DateTime? openAt;
    String? description;
    for (final e in flips) {
      if (e.kind == MacEventKind.offline) {
        // Dos caidas seguidas sin recuperacion entre medio: la anterior se
        // cierra SIN duracion (nunca se observo que volviera) y se abre otra.
        if (openAt != null) {
          out.add(MacOutage(
            code: entry.key,
            description: description,
            droppedAt: openAt,
            ongoing: false,
          ));
        }
        openAt = e.ts;
        description = e.description;
      } else if (openAt != null) {
        out.add(MacOutage(
          code: entry.key,
          description: description,
          droppedAt: openAt,
          recoveredAt: e.ts,
          durationMinutes: roundTo(e.ts.difference(openAt).inSeconds / 60.0, 1),
          ongoing: false,
        ));
        openAt = null;
      }
    }
    if (openAt != null) {
      out.add(MacOutage(
        code: entry.key,
        description: description,
        droppedAt: openAt,
        durationMinutes:
            roundTo(_positiveMinutes(at.difference(openAt).inSeconds), 1),
        ongoing: true,
      ));
      openConsoles.add(entry.key);
    }
  }

  for (final console in consoles) {
    if (console.online != false || openConsoles.contains(console.code)) {
      continue;
    }
    final drop = console.lastSuccessfulComms;
    out.add(MacOutage(
      code: console.code,
      description: console.description,
      droppedAt: drop,
      durationMinutes: drop == null
          ? null
          : roundTo(_positiveMinutes(at.difference(drop).inSeconds), 1),
      ongoing: true,
    ));
  }

  out.sort((a, b) {
    if (a.droppedAt == null && b.droppedAt == null) return 0;
    if (a.droppedAt == null) return 1;
    if (b.droppedAt == null) return -1;
    return b.droppedAt!.compareTo(a.droppedAt!);
  });
  return List.unmodifiable(out);
}

double _positiveMinutes(int seconds) => seconds <= 0 ? 0 : seconds / 60.0;

/// Top de consolas por numero de caidas.
List<MacConsoleSummary> byConsoleOf(
  List<MacEvent> history, {
  List<AdaptMac> consoles = const [],
}) {
  final onlineNow = {
    for (final c in consoles)
      if (c.code.isNotEmpty) c.code: c.online,
  };
  final byCode = <String, List<MacEvent>>{};
  for (final e in history) {
    byCode.putIfAbsent(e.code, () => <MacEvent>[]).add(e);
  }
  int countOf(List<MacEvent> rows, MacEventKind kind) =>
      rows.where((e) => e.kind == kind).length;
  DateTime? lastOf(List<MacEvent> rows, MacEventKind kind) => rows
      .where((e) => e.kind == kind)
      .map((e) => e.ts)
      .fold<DateTime?>(null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc);

  final out = byCode.entries.map((e) {
    return MacConsoleSummary(
      code: e.key,
      description: e.value
          .map((x) => x.description)
          .firstWhere((d) => d != null, orElse: () => null),
      drops: countOf(e.value, MacEventKind.offline),
      commsFailures: countOf(e.value, MacEventKind.failedComms),
      bypassEvents: countOf(e.value, MacEventKind.bypassOn),
      events: e.value.length,
      lastDrop: lastOf(e.value, MacEventKind.offline),
      lastFailure: lastOf(e.value, MacEventKind.failedComms),
      onlineNow: onlineNow[e.key],
    );
  }).toList()
    ..sort((a, b) {
      final byDrops = b.drops.compareTo(a.drops);
      return byDrops != 0
          ? byDrops
          : b.commsFailures.compareTo(a.commsFailures);
    });
  return List.unmodifiable(out);
}

/// Caidas y fallas por DIA, con la falla dominante de cada fecha.
///
/// Ordenado por total descendente, no cronologicamente: la pregunta que
/// responde es "en que fechas hubo mas caidas", y para eso lo peor va arriba.
List<MacDaySummary> byDayOf(List<MacEvent> history) {
  final faults = history.where((e) => e.kind.isFault);
  final byDay = <DateTime, List<MacEvent>>{};
  for (final e in faults) {
    byDay
        .putIfAbsent(AnalyticsPeriod.daily.bucket(e.ts), () => <MacEvent>[])
        .add(e);
  }
  final out = byDay.entries.map((entry) {
    int countOf(MacEventKind kind) =>
        entry.value.where((e) => e.kind == kind).length;
    final drops = countOf(MacEventKind.offline);
    final failures = countOf(MacEventKind.failedComms);
    final bypass = countOf(MacEventKind.bypassOn);
    final counts = {
      MacEventKind.offline: drops,
      MacEventKind.failedComms: failures,
      MacEventKind.bypassOn: bypass,
    };
    final main = counts.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;
    return MacDaySummary(
      day: entry.key,
      drops: drops,
      commsFailures: failures,
      bypassEvents: bypass,
      mainFault: main,
      consolesAffected: entry.value.map((e) => e.code).toSet().length,
    );
  }).toList()
    ..sort((a, b) {
      final byTotal = b.total.compareTo(a.total);
      return byTotal != 0 ? byTotal : b.day.compareTo(a.day);
    });
  return List.unmodifiable(out);
}

/// Que fallas se presentan mas.
List<MacFaultBreakdown> faultBreakdownOf(List<MacEvent> history) {
  final byKind = <MacEventKind, List<MacEvent>>{};
  for (final e in history.where((e) => e.kind.isFault)) {
    byKind.putIfAbsent(e.kind, () => <MacEvent>[]).add(e);
  }
  final out = byKind.entries
      .map((e) => MacFaultBreakdown(
            kind: e.key,
            events: e.value.length,
            consolesAffected: e.value.map((x) => x.code).toSet().length,
            lastEvent: e.value.map((x) => x.ts).fold<DateTime?>(
                null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc),
          ))
      .toList()
    ..sort((a, b) => b.events.compareTo(a.events));
  return List.unmodifiable(out);
}

/// Serie temporal de fallas.
///
/// Con [from] y [to] la grilla cubre TODO el rango y rellena con ceros los dias
/// sin eventos: el historial es forward-only, y sin ese relleno el eje empezaria
/// en el primer evento observado en vez de en la fecha que el usuario eligio.
List<MacFaultPoint> faultsOverTime(
  List<MacEvent> history, {
  AnalyticsPeriod period = AnalyticsPeriod.daily,
  DateTime? from,
  DateTime? to,
}) {
  final buckets = bucketByPeriod(
    history.where((e) => e.kind.isFault),
    period,
    dateOf: (e) => e.ts,
  );
  final counted = <DateTime, MacFaultPoint>{
    for (final entry in buckets.entries)
      entry.key: MacFaultPoint(
        period: entry.key,
        drops: entry.value.where((e) => e.kind == MacEventKind.offline).length,
        commsFailures:
            entry.value.where((e) => e.kind == MacEventKind.failedComms).length,
        bypassEvents:
            entry.value.where((e) => e.kind == MacEventKind.bypassOn).length,
      ),
  };

  final grid = _grid(period, from, to);
  if (grid == null) {
    return List.unmodifiable(counted.values);
  }
  return List.unmodifiable(grid.map((day) =>
      counted[day] ??
      MacFaultPoint(period: day, drops: 0, commsFailures: 0, bypassEvents: 0)));
}

/// Rejilla de periodos que cubre el rango. `null` si no hay rango, o si es tan
/// largo que rellenarlo dibujaria cientos de periodos vacios.
List<DateTime>? _grid(AnalyticsPeriod period, DateTime? from, DateTime? to) {
  if (from == null || to == null) return null;
  final start = period.bucket(from);
  final end = period.bucket(to);
  if (end.isBefore(start)) return null;
  final out = <DateTime>[];
  var cursor = start;
  // Cota de seguridad: mas alla de esto el eje lo guian los datos.
  while (!cursor.isAfter(end) && out.length < 400) {
    out.add(cursor);
    cursor = switch (period) {
      AnalyticsPeriod.daily => cursor.add(const Duration(days: 1)),
      AnalyticsPeriod.weekly => cursor.add(const Duration(days: 7)),
      AnalyticsPeriod.monthly => DateTime.utc(cursor.year, cursor.month + 1),
    };
  }
  return out.length >= 400 ? null : out;
}

/// Consolas con demasiadas caidas dentro de la ventana movil reciente.
List<MacFlapping> flappingOf(
  List<MacEvent> history, {
  DateTime? now,
  int windowHours = macFlapWindowHours,
  int threshold = macFlapThreshold,
}) {
  final at = (now ?? DateTime.now()).toUtc();
  final cutoff = at.subtract(Duration(hours: windowHours));
  final byCode = <String, List<MacEvent>>{};
  for (final e in history) {
    if (e.kind != MacEventKind.offline || e.ts.isBefore(cutoff)) continue;
    byCode.putIfAbsent(e.code, () => <MacEvent>[]).add(e);
  }
  final out = byCode.entries
      .where((e) => e.value.length >= threshold)
      .map((e) => MacFlapping(
            code: e.key,
            description: e.value
                .map((x) => x.description)
                .firstWhere((d) => d != null, orElse: () => null),
            drops: e.value.length,
            lastDrop: e.value.map((x) => x.ts).fold<DateTime?>(
                null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc),
          ))
      .toList()
    ..sort((a, b) => b.drops.compareTo(a.drops));
  return List.unmodifiable(out);
}
