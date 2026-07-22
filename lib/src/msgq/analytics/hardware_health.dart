/// Auditoria de Salud de Hardware y Sensores — port de
/// `msgq/core/hardware_health.py`.
///
/// Tres detectores sobre los datos ya replicados (despachos + log de cambios):
///
///   1. SMU EN REGRESION / ESTANCADO. El SMU (horometro/odometro) siempre debe
///      avanzar.
///        * Regresion: da un paso atras respecto a la lectura anterior y NO se
///          recupera en la siguiente -> el sensor se rompio, se reinicio o lo
///          manipularon. Usa el SMU *calculado*.
///        * Estancamiento: el MISMO SMU *crudo* en >= K despachos consecutivos
///          de un equipo In Service abarcando >= D dias -> el sensor no envia
///          pulsos al AdaptMAC.
///   2. RE-TAGUEO SOSPECHOSO. Mas de N cambios de RFID del mismo equipo en una
///      ventana movil de D dias: el operador podria estar destruyendo los tags
///      para forzar despachos manuales o en bypass.
///   3. DEGRADACION DEL MEDIDOR. Por manguera, si el caudal reciente cae >= PCT%
///      respecto a su linea base historica, los filtros estan obstruidos o la
///      bomba falla.
///
/// Todo lo marcado se consolida en una lista accionable de ORDENES DE TRABAJO.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/change_event.dart';
import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';

/// Que le pasa al SMU de un equipo.
enum SmuAnomalyType {
  regression('Regresion'),
  stagnation('Estancamiento');

  const SmuAnomalyType(this.label);

  final String label;
}

/// Severidad de una orden de trabajo. El orden de declaracion es el de
/// atencion: lo critico primero.
enum WorkOrderSeverity {
  critical('CRITICAL'),
  warning('WARNING');

  const WorkOrderSeverity(this.label);

  final String label;
}

/// Una anomalia del SMU de un equipo.
class SmuAnomaly {
  const SmuAnomaly({
    this.date,
    required this.equipmentId,
    required this.equipmentDescription,
    this.category,
    this.equipmentStatus,
    required this.type,
    this.smuType,
    required this.smuValue,
    this.referenceValue,
    this.drop,
    this.repeats,
    this.days,
    this.sourceId,
  });

  final DateTime? date;
  final String equipmentId;
  final String equipmentDescription;
  final String? category;
  final String? equipmentStatus;
  final SmuAnomalyType type;
  final String? smuType;

  /// Valor observado (el que cayo, o el que se repite).
  final double smuValue;

  /// Lectura anterior. Solo en una regresion.
  final double? referenceValue;

  /// Cuanto retrocedio. Solo en una regresion.
  final double? drop;

  /// Despachos con el mismo SMU. Solo en un estancamiento.
  final int? repeats;

  /// Dias que abarca el evento.
  final int? days;

  final String? sourceId;
}

/// Un equipo con demasiados cambios de tag en la ventana movil.
class RetagAlert {
  const RetagAlert({
    required this.equipmentId,
    required this.internalId,
    this.equipmentDescription,
    this.category,
    this.equipmentStatus,
    required this.changesInWindow,
    this.firstChange,
    this.lastChange,
    this.lastTag,
  });

  /// Codigo visible, o `(no identificado)` si el tag ya no esta en el maestro.
  final String equipmentId;

  /// Id interno: la clave real del log.
  final String internalId;

  final String? equipmentDescription;
  final String? category;
  final String? equipmentStatus;

  /// Maximo de cambios observados dentro de cualquier ventana de
  /// [retagWindowDays] dias.
  final int changesInWindow;

  final DateTime? firstChange;
  final DateTime? lastChange;
  final String? lastTag;
}

/// Salud de UNA manguera: caudal reciente contra su linea base.
class MeterHealth {
  const MeterHealth({
    required this.meterId,
    this.meterDescription,
    required this.metric,
    required this.baseSamples,
    required this.recentSamples,
    required this.baseFlow,
    required this.recentFlow,
    required this.dropPct,
    required this.degraded,
  });

  final String meterId;
  final String? meterDescription;

  /// Que caudal se pudo medir: promedio si el tenant lo expone, si no el pico.
  final String metric;

  final int baseSamples;
  final int recentSamples;
  final double baseFlow;
  final double recentFlow;

  /// Caida porcentual del caudal reciente respecto a la base. Negativa = subio.
  final double dropPct;

  final bool degraded;
}

/// Caudal mediano de una manguera en un dia.
class MeterSeriesPoint {
  const MeterSeriesPoint({
    required this.meterId,
    required this.date,
    required this.flow,
  });

  final String meterId;
  final DateTime date;
  final double flow;
}

/// Ticket accionable derivado de un hallazgo.
class WorkOrder {
  const WorkOrder({
    required this.type,
    required this.asset,
    required this.severity,
    required this.detail,
    this.date,
    required this.action,
  });

  /// Categoria canonica de la alerta (`alertSmuRegression`, etc.).
  final String type;

  /// Equipo o manguera afectada.
  final String asset;

  final WorkOrderSeverity severity;
  final String detail;
  final DateTime? date;

  /// Que hacer al respecto.
  final String action;

  /// Un ticket por activo y problema.
  String get key => '$type|$asset';
}

class HardwareKpis {
  const HardwareKpis({
    required this.smuRegressions,
    required this.smuStagnations,
    required this.retagAlerts,
    required this.degradedMeters,
    required this.workOrders,
  });

  final int smuRegressions;
  final int smuStagnations;
  final int retagAlerts;
  final int degradedMeters;
  final int workOrders;
}

// ===========================================================================
// Auditoria
// ===========================================================================

const String _actionSmu = 'Revisar / reemplazar sensor SMU (horometro/odometro)';
const String _actionRetag =
    'Auditar tags y operador; revisar despachos manuales/bypass';
const String _actionMeter = 'Revisar filtros / bomba de la manguera';

class HardwareAudit {
  const HardwareAudit._({
    required this.smuAnomalies,
    required this.retagAlerts,
    required this.meters,
    required this.meterSeries,
    required this.workOrders,
    required this.meterDataAvailable,
    required this.kpis,
  });

  final List<SmuAnomaly> smuAnomalies;
  final List<RetagAlert> retagAlerts;
  final List<MeterHealth> meters;
  final List<MeterSeriesPoint> meterSeries;
  final List<WorkOrder> workOrders;

  /// La replica trae datos de medidor. Si es `false`, la seccion de mangueras
  /// esta vacia porque el tenant no expone esos campos — no porque todas las
  /// mangueras esten sanas. La distincion es la diferencia entre "sin hallazgos"
  /// y "sin capacidad de detectar".
  final bool meterDataAvailable;

  final HardwareKpis kpis;

  static HardwareAudit run({
    required List<Movement> movements,
    List<Equipment> equipment = const [],
    List<ChangeEvent> changes = const [],
  }) {
    final smu = smuAnomaliesOf(movements: movements, equipment: equipment);
    final retag = retagAlertsOf(changes: changes, equipment: equipment);
    final meters = meterHealthOf(movements);
    final orders = workOrdersOf(smu: smu, retag: retag, meters: meters);
    return HardwareAudit._(
      smuAnomalies: smu,
      retagAlerts: retag,
      meters: meters,
      meterSeries: meterSeriesOf(movements),
      workOrders: orders,
      meterDataAvailable: meterDataAvailableIn(movements),
      kpis: HardwareKpis(
        smuRegressions:
            smu.where((a) => a.type == SmuAnomalyType.regression).length,
        smuStagnations:
            smu.where((a) => a.type == SmuAnomalyType.stagnation).length,
        retagAlerts: retag.length,
        degradedMeters: meters.where((m) => m.degraded).length,
        workOrders: orders.length,
      ),
    );
  }
}

// ===========================================================================
// 1. SMU: regresion y estancamiento
// ===========================================================================

/// Regresiones y estancamientos del SMU, del evento mas reciente al mas antiguo.
List<SmuAnomaly> smuAnomaliesOf({
  required List<Movement> movements,
  List<Equipment> equipment = const [],
}) {
  final master = {
    for (final e in equipment)
      if (realEquipmentId(e.equipmentId) != null) realEquipmentId(e.equipmentId)!: e,
  };

  final byEquipment = <String, List<_SmuReading>>{};
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    final date = m.recordCollectedAt ?? m.updatedAt;
    if (id == null || date == null) continue;
    final eq = master[id];
    byEquipment.putIfAbsent(id, () => <_SmuReading>[]).add(_SmuReading(
          equipmentId: id,
          description:
              asText(m.equipmentDescription) ?? asText(eq?.description) ?? id,
          category: eq?.category,
          // Estado vigente del maestro; si no esta, el que traia el movimiento.
          status: asText(eq?.status) ?? asText(m.equipmentStatus),
          // El SMU calculado es el que refleja la lectura corregida; el crudo,
          // los pulsos que llegan del sensor. Cada deteccion usa el suyo.
          calculated: m.calculatedSmuValue ?? m.smuValue,
          raw: m.rawSmuValue ?? m.smuValue,
          smuType: m.smuType,
          date: date,
          sourceId: m.id,
        ));
  }

  final out = <SmuAnomaly>[];
  for (final readings in byEquipment.values) {
    readings.sort((a, b) => a.date.compareTo(b.date));
    out.addAll(_regressions(readings));
    out.addAll(_stagnations(readings));
  }
  out.sort((a, b) => _compareDatesDesc(a.date, b.date));
  return List.unmodifiable(out);
}

/// Cada paso ATRAS del SMU calculado que no se recupera en la lectura
/// siguiente.
///
/// Exigir que no se recupere es lo que separa un reset real de un bache
/// transitorio, y hace que cada manipulacion se reporte UNA vez (el evento) en
/// vez de en cada despacho posterior.
List<SmuAnomaly> _regressions(List<_SmuReading> readings) {
  final withValue =
      readings.where((r) => r.calculated != null).toList(growable: false);
  final out = <SmuAnomaly>[];
  for (var i = 1; i < withValue.length; i++) {
    final prev = withValue[i - 1];
    final curr = withValue[i];
    final drop = prev.calculated! - curr.calculated!;
    if (drop < smuRegressionMinDrop) continue;
    // Sin lectura siguiente, la caida persiste hasta el final del historico.
    final next = i + 1 < withValue.length ? withValue[i + 1] : null;
    final recovered = next != null && next.calculated! >= prev.calculated!;
    if (recovered) continue;
    out.add(SmuAnomaly(
      date: curr.date,
      equipmentId: curr.equipmentId,
      equipmentDescription: curr.description,
      category: curr.category,
      equipmentStatus: curr.status,
      type: SmuAnomalyType.regression,
      smuType: curr.smuType,
      smuValue: roundTo(curr.calculated!),
      referenceValue: roundTo(prev.calculated!),
      drop: roundTo(drop),
      days: curr.date.difference(prev.date).inDays,
      sourceId: curr.sourceId,
    ));
  }
  return out;
}

/// Corridas de SMU crudo identico en despachos consecutivos de un equipo
/// In Service.
///
/// Solo In Service: un equipo fuera de servicio no deberia mover su horometro,
/// asi que un SMU quieto ahi es lo esperado, no una averia.
List<SmuAnomaly> _stagnations(List<_SmuReading> readings) {
  final working = readings
      .where((r) => r.raw != null && r.status?.trim() == statusInService)
      .toList(growable: false);
  final out = <SmuAnomaly>[];
  var start = 0;
  while (start < working.length) {
    var end = start;
    while (end + 1 < working.length &&
        working[end + 1].raw == working[start].raw) {
      end++;
    }
    final run = working.sublist(start, end + 1);
    final days = run.last.date.difference(run.first.date).inDays;
    if (run.length >= smuStagnationMinRepeats && days >= smuStagnationMinDays) {
      final last = run.last;
      out.add(SmuAnomaly(
        date: last.date,
        equipmentId: last.equipmentId,
        equipmentDescription: last.description,
        category: last.category,
        equipmentStatus: last.status,
        type: SmuAnomalyType.stagnation,
        smuType: last.smuType,
        smuValue: roundTo(last.raw!),
        repeats: run.length,
        days: days,
        sourceId: last.sourceId,
      ));
    }
    start = end + 1;
  }
  return out;
}

class _SmuReading {
  const _SmuReading({
    required this.equipmentId,
    required this.description,
    this.category,
    this.status,
    this.calculated,
    this.raw,
    this.smuType,
    required this.date,
    this.sourceId,
  });

  final String equipmentId;
  final String description;
  final String? category;
  final String? status;
  final double? calculated;
  final double? raw;
  final String? smuType;
  final DateTime date;
  final String? sourceId;
}

// ===========================================================================
// 2. Re-tagueo sospechoso
// ===========================================================================

/// Equipos con mas de [retagMaxChanges] REEMPLAZOS de tag dentro de cualquier
/// ventana movil de [retagWindowDays] dias.
///
/// Solo cuenta los reemplazos (tag -> otro tag): una alta inicial o una baja no
/// son sintoma de nada, y contarlas marcaria a cualquier equipo recien dado de
/// alta.
List<RetagAlert> retagAlertsOf({
  required List<ChangeEvent> changes,
  List<Equipment> equipment = const [],
}) {
  final master = {
    for (final e in equipment)
      if (e.internalId != null) e.internalId!: e,
  };
  final byRecord = <String, List<ChangeEvent>>{};
  for (final c in changes) {
    if (!c.isRfidRecord || c.attribute != attrRfid) continue;
    if (c.rfidChangeType != RfidChangeType.changed) continue;
    if (c.recordId == null || c.changedAt == null) continue;
    byRecord.putIfAbsent(c.recordId!, () => <ChangeEvent>[]).add(c);
  }

  final window = const Duration(days: retagWindowDays);
  final out = <RetagAlert>[];
  for (final entry in byRecord.entries) {
    final events = entry.value
      ..sort((a, b) => a.changedAt!.compareTo(b.changedAt!));
    final peak = _peakInWindow(
        events.map((e) => e.changedAt!).toList(growable: false), window);
    if (peak.count <= retagMaxChanges) continue;
    final eq = master[entry.key];
    out.add(RetagAlert(
      equipmentId: eq?.equipmentId ?? unidentifiedLabel,
      internalId: entry.key,
      equipmentDescription: eq?.description,
      category: eq?.category,
      equipmentStatus: eq?.status,
      changesInWindow: peak.count,
      firstChange: peak.from,
      lastChange: peak.to,
      lastTag: events.last.after,
    ));
  }
  out.sort((a, b) => b.changesInWindow.compareTo(a.changesInWindow));
  return List.unmodifiable(out);
}

/// Maximo de eventos que caben en una ventana movil, y sus extremos.
///
/// Ventana MOVIL, no calendario: cuatro cambios repartidos entre el 28 de un
/// mes y el 2 del siguiente son igual de sospechosos que cuatro dentro del
/// mismo mes, y una particion por mes los perderia.
({int count, DateTime? from, DateTime? to}) _peakInWindow(
  List<DateTime> sorted,
  Duration window,
) {
  var best = 0;
  DateTime? from;
  DateTime? to;
  var lo = 0;
  for (var hi = 0; hi < sorted.length; hi++) {
    final cutoff = sorted[hi].subtract(window);
    while (sorted[lo].isBefore(cutoff)) {
      lo++;
    }
    final count = hi - lo + 1;
    if (count > best) {
      best = count;
      from = sorted[lo];
      to = sorted[hi];
    }
  }
  return (count: best, from: from, to: to);
}

// ===========================================================================
// 3. Degradacion del medidor
// ===========================================================================

class _FlowSetup {
  const _FlowSetup({required this.readings, required this.metric});

  final List<({String meterId, String? description, DateTime date, double flow})>
      readings;
  final String metric;
}

/// Prepara las lecturas de caudal por manguera.
///
/// Prefiere el caudal PROMEDIO: describe toda la transaccion. El pico solo se
/// usa como respaldo cuando el tenant no expone el promedio — sirve para ver la
/// tendencia, pero es mas ruidoso.
_FlowSetup? _flowSetup(List<Movement> movements) {
  final dispenses = movements
      .where((m) => m.isDispense && asText(m.meterId) != null)
      .toList(growable: false);
  if (dispenses.isEmpty) return null;

  for (final option in const [
    (label: 'Caudal promedio', average: true),
    (label: 'Caudal pico', average: false),
  ]) {
    final readings = <({
      String meterId,
      String? description,
      DateTime date,
      double flow
    })>[];
    for (final m in dispenses) {
      final flow = option.average ? m.averageFlowRate : m.peakFlowRate;
      final date = m.recordCollectedAt ?? m.updatedAt;
      if (flow == null || flow <= 0 || date == null) continue;
      readings.add((
        meterId: asText(m.meterId)!,
        description: asText(m.meterDescription),
        date: date,
        flow: flow,
      ));
    }
    if (readings.isNotEmpty) {
      return _FlowSetup(readings: readings, metric: option.label);
    }
  }
  return null;
}

/// Caudal reciente vs linea base historica, por manguera.
///
/// La frontera "reciente" se mide desde el ULTIMO dato replicado, no desde hoy:
/// si la sincronizacion lleva dias parada, anclarla al reloj dejaria la ventana
/// reciente vacia y ninguna manguera se evaluaria.
List<MeterHealth> meterHealthOf(List<Movement> movements) {
  final setup = _flowSetup(movements);
  if (setup == null) return const [];
  final latest = setup.readings
      .map((r) => r.date)
      .reduce((a, b) => a.isAfter(b) ? a : b);
  final recentStart = latest.subtract(const Duration(days: meterRecentDays));

  final byMeter = <String,
      List<({String meterId, String? description, DateTime date, double flow})>>{};
  for (final r in setup.readings) {
    byMeter.putIfAbsent(r.meterId, () => []).add(r);
  }

  final out = <MeterHealth>[];
  for (final entry in byMeter.entries) {
    final base = entry.value.where((r) => r.date.isBefore(recentStart));
    final recent = entry.value.where((r) => !r.date.isBefore(recentStart));
    if (base.length < meterMinSamples || recent.length < meterMinSamples) {
      continue;
    }
    final baseFlow = median(base.map((r) => r.flow))!;
    final recentFlow = median(recent.map((r) => r.flow))!;
    final dropPct = baseFlow > 0 ? (baseFlow - recentFlow) / baseFlow * 100 : 0.0;
    out.add(MeterHealth(
      meterId: entry.key,
      meterDescription: entry.value
          .map((r) => r.description)
          .firstWhere((d) => d != null, orElse: () => null),
      metric: setup.metric,
      baseSamples: base.length,
      recentSamples: recent.length,
      baseFlow: roundTo(baseFlow),
      recentFlow: roundTo(recentFlow),
      dropPct: roundTo(dropPct),
      degraded: baseFlow > 0 && dropPct >= meterDropPct,
    ));
  }
  out.sort((a, b) {
    if (a.degraded != b.degraded) return a.degraded ? -1 : 1;
    return b.dropPct.compareTo(a.dropPct);
  });
  return List.unmodifiable(out);
}

/// Caudal mediano por manguera y dia (grafica de tendencia).
List<MeterSeriesPoint> meterSeriesOf(List<Movement> movements) {
  final setup = _flowSetup(movements);
  if (setup == null) return const [];
  final byMeterDay = <String, Map<DateTime, List<double>>>{};
  for (final r in setup.readings) {
    byMeterDay
        .putIfAbsent(r.meterId, () => <DateTime, List<double>>{})
        .putIfAbsent(AnalyticsPeriod.daily.bucket(r.date), () => <double>[])
        .add(r.flow);
  }
  final out = <MeterSeriesPoint>[];
  for (final meter in byMeterDay.entries) {
    for (final day in meter.value.entries) {
      out.add(MeterSeriesPoint(
        meterId: meter.key,
        date: day.key,
        flow: roundTo(median(day.value)!),
      ));
    }
  }
  out.sort((a, b) {
    final byMeter = a.meterId.compareTo(b.meterId);
    return byMeter != 0 ? byMeter : a.date.compareTo(b.date);
  });
  return List.unmodifiable(out);
}

/// La replica trae identificador de medidor en algun despacho.
bool meterDataAvailableIn(List<Movement> movements) =>
    movements.any((m) => m.isDispense && asText(m.meterId) != null);

// ===========================================================================
// 4. Ordenes de trabajo
// ===========================================================================

/// Consolida los hallazgos en tickets accionables.
///
/// UNA orden por activo y problema, con el evento mas reciente: el detalle de
/// cada ocurrencia sigue en las tablas de SMU. Sin esa deduplicacion, un sensor
/// roto generaria decenas de tickets identicos y el listado dejaria de ser una
/// lista de trabajo.
List<WorkOrder> workOrdersOf({
  required List<SmuAnomaly> smu,
  required List<RetagAlert> retag,
  required List<MeterHealth> meters,
}) {
  final candidates = <WorkOrder>[
    ...smu.map((a) {
      final isRegression = a.type == SmuAnomalyType.regression;
      return WorkOrder(
        type: isRegression ? alertSmuRegression : alertSmuStagnation,
        asset: a.equipmentId,
        severity: WorkOrderSeverity.critical,
        detail: isRegression
            ? 'SMU cayo ${a.drop} (de ${a.referenceValue} a ${a.smuValue}) '
                'tras ${a.days} dias'
            : 'Mismo SMU ${a.smuValue} en ${a.repeats} despachos '
                '(${a.days} dias)',
        date: a.date,
        action: _actionSmu,
      );
    }),
    ...retag.map((r) => WorkOrder(
          type: alertRetag,
          asset: r.equipmentId,
          severity: WorkOrderSeverity.critical,
          detail:
              '${r.changesInWindow} cambios de RFID en $retagWindowDays dias',
          date: r.lastChange,
          action: _actionRetag,
        )),
    ...meters.where((m) => m.degraded).map((m) => WorkOrder(
          type: alertMeterDegraded,
          asset: m.meterId,
          severity: WorkOrderSeverity.warning,
          detail: '${m.metric} cayo ${m.dropPct}% '
              '(${m.baseFlow} -> ${m.recentFlow} L/min)',
          action: _actionMeter,
        )),
  ]..sort((a, b) => _compareDatesDesc(a.date, b.date));

  final byKey = <String, WorkOrder>{};
  for (final order in candidates) {
    byKey.putIfAbsent(order.key, () => order); // el primero es el mas reciente
  }
  final out = byKey.values.toList()
    ..sort((a, b) {
      final bySeverity = a.severity.index.compareTo(b.severity.index);
      return bySeverity != 0 ? bySeverity : _compareDatesDesc(a.date, b.date);
    });
  return List.unmodifiable(out);
}

/// Ordena descendente dejando las fechas ausentes al final.
int _compareDatesDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}
