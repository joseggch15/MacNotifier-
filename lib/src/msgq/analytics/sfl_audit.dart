/// Auditoria de despachos contra el Safe Fill Level (SFL) — port de
/// `msgq/core/sfl_audit.py` y de la clasificacion de `dispense_report.py`.
///
/// El SFL es el volumen maximo seguro a despachar a un equipo en UN repostaje,
/// por producto. Dispensar mas es un SOBRELLENADO: riesgo de derrame y bandera
/// para el auditor. Este modulo cubre las tres vistas del escritorio, que se
/// solapan en el dato pero responden preguntas distintas:
///
///   * EXCESOS: despachos cuyo volumen supera el SFL del equipo para ese
///     producto (cruce por equipo+producto contra el limite real del FMS).
///   * CONFLICTOS: despachos SIN equipo valido cuyo volumen supera el SFL
///     MAXIMO de la flota para ese producto — un sobrellenado que no es seguro
///     para NINGUN equipo, y ademas sin trazabilidad.
///   * POR EQUIPO: cada despacho clasificado Normal / Over SFL, con el SFL
///     resuelto por la cascada compartida ([resolveSfl]) y los agregados por
///     equipo y por dimension del maestro.
///
/// Relacion con el notificador: `sfl_check.dart` DETECTA un sobrellenado para
/// notificarlo; esto es la VISTA de auditoria, con desgloses por operador,
/// categoria y grupo/BP que responden "quien y que tipo de equipo concentra los
/// excesos".
///
/// La tolerancia [sflTolerancePct] filtra el ruido de medicion: solo cuenta como
/// exceso si el volumen supera el SFL por mas de ese margen. El exceso reportado
/// sigue siendo `volume - sfl` (el exceso real sobre el nivel seguro).
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';
import 'sfl_resolution.dart';

/// Un despacho que supera el SFL del equipo para su producto.
class SflExceedance {
  const SflExceedance({
    this.date,
    required this.equipmentId,
    this.equipmentDescription,
    this.equipmentStatus,
    this.product,
    required this.volume,
    required this.sfl,
    required this.excess,
    required this.excessPct,
    this.fieldUser,
    this.dispensingPoint,
    this.sourceId,
    this.category,
    this.group,
  });

  final DateTime? date;
  final String equipmentId;
  final String? equipmentDescription;
  final String? equipmentStatus;
  final String? product;
  final double volume;
  final double sfl;

  /// volume - sfl.
  final double excess;

  /// excess / sfl * 100.
  final double excessPct;

  final String? fieldUser;
  final String? dispensingPoint;
  final String? sourceId;

  /// Dimensiones del equipo, resueltas del maestro (para los desgloses).
  final String? category;
  final String? group;
}

/// Un despacho sin equipo valido cuyo volumen es peligroso para cualquier equipo.
class SflConflict {
  const SflConflict({
    this.date,
    this.equipmentId,
    this.product,
    required this.volume,
    this.type,
    this.status,
    this.fleetMaxSfl,
    required this.overMax,
    this.fieldUser,
    this.dispensingPoint,
    this.sourceId,
  });

  final DateTime? date;
  final String? equipmentId;
  final String? product;
  final double volume;
  final String? type;
  final String? status;

  /// SFL maximo de la flota para ese producto. `null` = producto sin limite.
  final double? fleetMaxSfl;

  /// El volumen supera ese maximo: sobrellenado para cualquier equipo.
  final bool overMax;

  final String? fieldUser;
  final String? dispensingPoint;
  final String? sourceId;
}

/// Fila de un desglose de excesos por alguna dimension.
class SflBreakdownRow {
  const SflBreakdownRow({
    required this.key,
    required this.exceedances,
    required this.totalExcessL,
    required this.worstExcessL,
    this.equipmentCount,
  });

  final String key;
  final int exceedances;
  final double totalExcessL;
  final double worstExcessL;

  /// Solo en los desgloses por dimension del equipo.
  final int? equipmentCount;
}

class SflKpis {
  const SflKpis({
    required this.exceedances,
    required this.totalExcessL,
    required this.worstExcessL,
    required this.equipmentAffected,
    required this.pctOfDispenses,
    required this.conflicts,
    required this.conflictsOverMax,
  });

  final int exceedances;
  final double totalExcessL;
  final double worstExcessL;
  final int equipmentAffected;

  /// Porcentaje de los despachos totales que fueron excesos.
  final double pctOfDispenses;

  final int conflicts;
  final int conflictsOverMax;
}

class SflAudit {
  const SflAudit._({
    required this.exceedances,
    required this.conflicts,
    required this.kpis,
    required List<Movement> dispenses,
    required List<Equipment> equipment,
    required List<ConsumptionLimit> limits,
  })  : _dispenses = dispenses,
        _equipment = equipment,
        _limits = limits;

  final List<SflExceedance> exceedances;
  final List<SflConflict> conflicts;
  final SflKpis kpis;

  final List<Movement> _dispenses;
  final List<Equipment> _equipment;
  final List<ConsumptionLimit> _limits;

  static SflAudit run({
    required List<Movement> movements,
    List<ConsumptionLimit> limits = const [],
    List<Equipment> equipment = const [],
  }) {
    final dispenses =
        movements.where((m) => m.isDispense).toList(growable: false);
    final exceedances =
        exceedancesOf(dispenses, limits: limits, equipment: equipment);
    final conflicts = unattributedConflictsOf(dispenses, limits: limits);
    return SflAudit._(
      exceedances: exceedances,
      conflicts: conflicts,
      dispenses: dispenses,
      equipment: equipment,
      limits: limits,
      kpis: SflKpis(
        exceedances: exceedances.length,
        totalExcessL: roundTo(sumOf(exceedances, (e) => e.excess)),
        worstExcessL: exceedances.isEmpty
            ? 0
            : exceedances.map((e) => e.excess).reduce((a, b) => a > b ? a : b),
        equipmentAffected:
            exceedances.map((e) => e.equipmentId).toSet().length,
        pctOfDispenses: dispenses.isEmpty
            ? 0
            : roundTo(exceedances.length / dispenses.length * 100, 2),
        conflicts: conflicts.length,
        conflictsOverMax: conflicts.where((c) => c.overMax).length,
      ),
    );
  }

  // -- desgloses -------------------------------------------------------------

  List<SflBreakdownRow> byProduct() =>
      _breakdown((e) => e.product, keepNull: true);

  List<SflBreakdownRow> byFieldUser() =>
      _breakdown((e) => e.fieldUser, keepNull: true);

  List<SflBreakdownRow> byEquipment() {
    final rows = _breakdown((e) => e.equipmentId);
    // El desglose por equipo lleva ademas la descripcion en la clave visible.
    return rows;
  }

  List<SflBreakdownRow> byCategory() => _breakdown((e) => e.category,
      keepNull: true, withEquipmentCount: true);

  /// Por grupo / BP del equipo.
  List<SflBreakdownRow> byGroup() =>
      _breakdown((e) => e.group, keepNull: true, withEquipmentCount: true);

  List<SflBreakdownRow> _breakdown(
    String? Function(SflExceedance) keyOf, {
    bool keepNull = false,
    bool withEquipmentCount = false,
  }) {
    final byKey = <String, List<SflExceedance>>{};
    for (final e in exceedances) {
      final raw = keyOf(e);
      if (raw == null && !keepNull) continue;
      byKey.putIfAbsent(categoryKey(raw), () => <SflExceedance>[]).add(e);
    }
    final rows = byKey.entries
        .map((entry) => SflBreakdownRow(
              key: entry.key,
              exceedances: entry.value.length,
              totalExcessL: roundTo(sumOf(entry.value, (e) => e.excess)),
              worstExcessL: entry.value
                  .map((e) => e.excess)
                  .reduce((a, b) => a > b ? a : b),
              equipmentCount: withEquipmentCount
                  ? entry.value.map((e) => e.equipmentId).toSet().length
                  : null,
            ))
        .toList()
      ..sort((a, b) => b.exceedances.compareTo(a.exceedances));
    return List.unmodifiable(rows);
  }

  /// Serie temporal de excesos.
  List<SflOverTimePoint> overTime({
    AnalyticsPeriod period = AnalyticsPeriod.monthly,
  }) {
    final buckets =
        bucketByPeriod(exceedances, period, dateOf: (e) => e.date);
    return List.unmodifiable(buckets.entries.map((e) => SflOverTimePoint(
          period: e.key,
          exceedances: e.value.length,
          totalExcessL: roundTo(sumOf(e.value, (x) => x.excess)),
        )));
  }

  // -- reporte "por equipo" (clasificacion Normal / Over SFL) ----------------

  /// Clasifica CADA despacho contra el SFL resuelto de su equipo y agrega por
  /// equipo. A diferencia de [exceedances] —que solo lista los que exceden—,
  /// esto cuenta tambien los normales, para dar el "% Over" por equipo.
  List<EquipmentDispenseSummary> equipmentSummary() {
    final sfl = resolveSfl(
      movements: _dispenses,
      limits: _limits,
      equipment: _equipment,
    );
    final master = {
      for (final e in _equipment)
        if (realEquipmentId(e.equipmentId) != null)
          realEquipmentId(e.equipmentId)!: e,
    };
    final byEquipment = <String, List<Movement>>{};
    for (final m in _dispenses) {
      final id = realEquipmentId(m.equipmentId);
      if (id == null || m.volume == null) continue;
      byEquipment.putIfAbsent(id, () => <Movement>[]).add(m);
    }

    final rows = byEquipment.entries.map((entry) {
      final resolved = sfl[entry.key];
      final limit = resolved?.sfl;
      final over = limit == null
          ? 0
          : entry.value.where((m) => (m.volume ?? 0) > limit).length;
      final eq = master[entry.key];
      final dates =
          entry.value.map((m) => m.recordCollectedAt ?? m.updatedAt).whereType<DateTime>();
      return EquipmentDispenseSummary(
        equipmentId: entry.key,
        description: eq?.description ??
            entry.value
                .map((m) => m.equipmentDescription)
                .firstWhere((d) => d != null, orElse: () => null),
        category: eq?.category,
        group: eq?.group,
        sfl: limit,
        sflSource: resolved?.source ?? SflSource.none,
        dispenses: entry.value.length,
        overSfl: over,
        totalVolumeL: roundTo(sumOf(entry.value, (m) => m.volume)),
        maxVolumeL: roundTo(entry.value
            .map((m) => m.volume ?? 0)
            .reduce((a, b) => a > b ? a : b)),
        firstDispense: dates.isEmpty
            ? null
            : dates.reduce((a, b) => a.isBefore(b) ? a : b),
        lastDispense: dates.isEmpty
            ? null
            : dates.reduce((a, b) => a.isAfter(b) ? a : b),
      );
    }).toList()
      ..sort((a, b) => b.overSfl.compareTo(a.overSfl));
    return List.unmodifiable(rows);
  }
}

class SflOverTimePoint {
  const SflOverTimePoint({
    required this.period,
    required this.exceedances,
    required this.totalExcessL,
  });

  final DateTime period;
  final int exceedances;
  final double totalExcessL;
}

/// Resumen por equipo del reporte de dispensas.
class EquipmentDispenseSummary {
  const EquipmentDispenseSummary({
    required this.equipmentId,
    this.description,
    this.category,
    this.group,
    this.sfl,
    required this.sflSource,
    required this.dispenses,
    required this.overSfl,
    required this.totalVolumeL,
    required this.maxVolumeL,
    this.firstDispense,
    this.lastDispense,
  });

  final String equipmentId;
  final String? description;
  final String? category;
  final String? group;

  /// SFL aplicado. `null` = no se pudo resolver.
  final double? sfl;
  final SflSource sflSource;

  final int dispenses;
  final int overSfl;
  final double totalVolumeL;
  final double maxVolumeL;
  final DateTime? firstDispense;
  final DateTime? lastDispense;

  int get normal => dispenses - overSfl;
  double get overPct => dispenses == 0 ? 0 : roundTo(overSfl / dispenses * 100, 2);
}

// ===========================================================================
// Deteccion
// ===========================================================================

/// Despachos cuyo volumen excede el SFL del equipo para ese producto.
List<SflExceedance> exceedancesOf(
  List<Movement> dispenses, {
  List<ConsumptionLimit> limits = const [],
  List<Equipment> equipment = const [],
}) {
  if (limits.isEmpty) return const [];
  final sflByPair = <String, double>{
    for (final l in limits)
      if (asText(l.equipmentId) != null && asText(l.product) != null && l.sfl > 0)
        limitKey(l.equipmentId, l.product): l.sfl,
  };
  final master = {
    for (final e in equipment)
      if (realEquipmentId(e.equipmentId) != null)
        realEquipmentId(e.equipmentId)!: e,
  };

  final out = <SflExceedance>[];
  for (final m in dispenses) {
    final id = realEquipmentId(m.equipmentId);
    final volume = m.volume;
    if (id == null || volume == null || m.product == null) continue;
    final sfl = sflByPair[limitKey(id, m.product)];
    if (sfl == null) continue;
    // Tolerancia: solo cuenta como exceso si supera el SFL por mas del margen.
    if (volume <= sfl * (1 + sflTolerancePct)) continue;
    final eq = master[id];
    out.add(SflExceedance(
      date: m.recordCollectedAt ?? m.updatedAt,
      equipmentId: id,
      equipmentDescription: asText(m.equipmentDescription) ?? eq?.description,
      equipmentStatus: asText(m.equipmentStatus) ?? eq?.status,
      product: asText(m.product),
      volume: roundTo(volume, 2),
      sfl: sfl,
      excess: roundTo(volume - sfl, 2),
      excessPct: roundTo((volume - sfl) / sfl * 100, 1),
      fieldUser: asText(m.fieldUser),
      dispensingPoint: asText(m.tank),
      sourceId: m.id,
      category: eq?.category,
      group: eq?.group,
    ));
  }
  out.sort((a, b) {
    if (a.date == null && b.date == null) return 0;
    if (a.date == null) return 1;
    if (b.date == null) return -1;
    return b.date!.compareTo(a.date!);
  });
  return List.unmodifiable(out);
}

/// SFL maximo de la flota por producto.
Map<String, double> fleetSflByProduct(List<ConsumptionLimit> limits) {
  final out = <String, double>{};
  for (final l in limits) {
    final product = asText(l.product)?.toUpperCase();
    if (product == null || l.sfl <= 0) continue;
    final current = out[product];
    if (current == null || l.sfl > current) out[product] = l.sfl;
  }
  return out;
}

/// Despachos sin equipo valido, con la marca de si superan el SFL maximo de la
/// flota para su producto.
List<SflConflict> unattributedConflictsOf(
  List<Movement> dispenses, {
  List<ConsumptionLimit> limits = const [],
}) {
  final fleet = fleetSflByProduct(limits);
  final out = <SflConflict>[];
  for (final m in dispenses) {
    // Sin equipo valido: status no_equip, tipo Unauthorised, o id vacio/no real.
    final noEquip = realEquipmentId(m.equipmentId) == null;
    final isNoEquipStatus = asText(m.status)?.toLowerCase() == 'no_equip';
    final isUnauthorised = asText(m.type) == typeUnauthorised;
    if (!noEquip && !isNoEquipStatus && !isUnauthorised) continue;
    final volume = m.volume;
    if (volume == null) continue;
    final product = asText(m.product)?.toUpperCase();
    final maxSfl = product == null ? null : fleet[product];
    out.add(SflConflict(
      date: m.recordCollectedAt ?? m.updatedAt,
      equipmentId: asText(m.equipmentId),
      product: asText(m.product),
      volume: roundTo(volume),
      type: asText(m.type),
      status: asText(m.status),
      fleetMaxSfl: maxSfl,
      overMax: maxSfl != null && volume > maxSfl * (1 + sflTolerancePct),
      fieldUser: asText(m.fieldUser),
      dispensingPoint: asText(m.tank),
      sourceId: m.id,
    ));
  }
  out.sort((a, b) {
    if (a.overMax != b.overMax) return a.overMax ? -1 : 1;
    return b.volume.compareTo(a.volume);
  });
  return List.unmodifiable(out);
}
