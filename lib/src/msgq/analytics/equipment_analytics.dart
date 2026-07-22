/// Analitica de la flota de equipos — port de
/// `msgq/core/equipment_analytics.py`.
///
/// Dos familias de calculos:
///
///   * SNAPSHOT, sobre el maestro de equipos: KPIs de flota, agrupaciones por
///     categoria / grupo / departamento / marca y completitud de datos.
///   * TEMPORAL, sobre el log de auditoria ([ChangeEvent]): frecuencia de
///     cambios de RFID, transiciones de estado por equipo (con foco en
///     In Service -> Out of Service) y quien hace los cambios.
///
/// Limitacion heredada del modelo, no del port: el log NO enlaza el tag RFID
/// con su equipo (`EquipmentRfid` no trae FK), por eso los eventos de RFID son
/// de FLOTA / registro-de-tag. Las transiciones de estado si son por equipo
/// (`EquipmentItem`, enlazable por `internalId`).
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/change_event.dart';
import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';

class EquipmentAnalytics {
  const EquipmentAnalytics({
    this.equipment = const [],
    this.changes = const [],
  });

  final List<Equipment> equipment;
  final List<ChangeEvent> changes;

  // =========================================================================
  // Snapshot de flota
  // =========================================================================

  /// Indicadores de cabecera. `null` si no hay maestro cargado: mostrar
  /// "0 equipos, 0% disponibilidad" cuando el inventario aun no bajo seria una
  /// alarma falsa.
  FleetKpis? fleetKpis() {
    if (equipment.isEmpty) return null;
    final total = equipment.length;
    final inService = equipment.where((e) => e.isInService).length;
    final contractor =
        equipment.where((e) => e.isContractorVehicle == true).length;
    return FleetKpis(
      total: total,
      inService: inService,
      outOfService: equipment.where((e) => e.isOutOfService).length,
      decommissioned: equipment.where((e) => e.isDecommissioned).length,
      availabilityPct: roundTo(inService / total * 100, 1),
      contractorVehicles: contractor,
      contractorPct: roundTo(contractor / total * 100, 1),
      lightVehicles: equipment.where((e) => e.isLightVehicle == true).length,
    );
  }

  /// Conteo y disponibilidad por una dimension del equipo.
  List<GroupSummary> groupSummary(EquipmentDimension dimension) =>
      _summarize(equipment, (e) => e.dimension(dimension));

  /// Conteo por estado (para el grafico de barras).
  List<StatusCount> statusBreakdown() {
    final counts = <String, int>{};
    for (final e in equipment) {
      final key = categoryKey(e.status);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final rows = counts.entries
        .map((e) => StatusCount(status: e.key, equipment: e.value))
        .toList()
      ..sort((a, b) => b.equipment.compareTo(a.equipment));
    return List.unmodifiable(rows);
  }

  /// Resumen de la flota de contratistas.
  ///
  /// El maestro no tiene columna "contratista", asi que se agrupa por
  /// departamento como proxy (y por marca si tampoco hay departamento) —
  /// exactamente el mismo criterio que MSGQ.
  List<GroupSummary> contractorSummary() {
    final contractors =
        equipment.where((e) => e.isContractorVehicle == true).toList();
    if (contractors.isEmpty) return const [];
    final hasDepartment = contractors.any((e) => e.department != null);
    return _summarize(
      contractors,
      (e) => hasDepartment ? e.department : e.make,
    );
  }

  /// Porcentaje de registros con dato presente en cada campo clave.
  List<CompletenessRow> dataCompleteness() {
    if (equipment.isEmpty) return const [];
    final total = equipment.length;
    return List.unmodifiable(completenessFields.map((field) {
      final filled = equipment.where((e) => e.hasCompletenessField(field)).length;
      return CompletenessRow(
        field: field,
        filled: filled,
        missing: total - filled,
        completenessPct: roundTo(filled / total * 100, 1),
      );
    }));
  }

  // =========================================================================
  // Temporal — cambios de RFID
  // =========================================================================

  /// Eventos de cambio de tag RFID, del mas reciente al mas antiguo.
  List<ChangeEvent> rfidChanges() {
    final rows = changes
        .where((c) => c.isRfidRecord && c.attribute == attrRfid)
        .toList()
      ..sort(_byChangedAtDesc);
    return List.unmodifiable(rows);
  }

  RfidChangeSummary rfidChangeSummary() {
    final rows = rfidChanges();
    return RfidChangeSummary(
      events: rows.length,
      assigned: rows
          .where((c) => c.rfidChangeType == RfidChangeType.assigned)
          .length,
      changed:
          rows.where((c) => c.rfidChangeType == RfidChangeType.changed).length,
      removed:
          rows.where((c) => c.rfidChangeType == RfidChangeType.removed).length,
      tagRecords: rows.map((c) => c.recordId).whereType<String>().toSet().length,
    );
  }

  /// Serie temporal de eventos de RFID por periodo y tipo.
  List<RfidChangePoint> rfidChangesOverTime({
    AnalyticsPeriod period = AnalyticsPeriod.monthly,
  }) {
    final buckets =
        bucketByPeriod(rfidChanges(), period, dateOf: (c) => c.changedAt);
    return List.unmodifiable(buckets.entries.map((e) {
      int countOf(RfidChangeType type) =>
          e.value.where((c) => c.rfidChangeType == type).length;
      return RfidChangePoint(
        period: e.key,
        assigned: countOf(RfidChangeType.assigned),
        changed: countOf(RfidChangeType.changed),
        removed: countOf(RfidChangeType.removed),
      );
    }));
  }

  /// Registros de tag con mas cambios (proxy de "re-tagueo").
  List<RfidChurnRow> rfidChurnByTag({int n = 25}) {
    final byRecord = _groupBy(rfidChanges(), (c) => c.recordId);
    final rows = byRecord.entries
        .map((e) => RfidChurnRow(
              recordId: e.key,
              events: e.value.length,
              lastChange: _maxDate(e.value),
            ))
        .toList()
      ..sort((a, b) => b.events.compareTo(a.events));
    return takeTop(rows, n);
  }

  // =========================================================================
  // Temporal — transiciones de estado
  // =========================================================================

  /// Transiciones de estado por equipo, enlazadas al maestro por `internalId`.
  ///
  /// Descarta los eventos sin valor previo: son el alta del equipo, no una
  /// transicion (contarlas convertiria cada equipo nuevo en una "salida de
  /// servicio" ficticia).
  List<StatusTransition> statusTransitions() {
    final lut = _equipmentByInternalId();
    final rows = changes
        .where((c) =>
            c.isEquipmentRecord && c.attribute == attrStatus && c.isReassignment)
        .map((c) {
          final eq = c.recordId == null ? null : lut[c.recordId!];
          return StatusTransition(
            changedAt: c.changedAt,
            recordId: c.recordId,
            equipmentId: eq?.equipmentId,
            description: eq?.description,
            group: eq?.group,
            category: eq?.category,
            department: eq?.department,
            costCentre: eq?.costCentre,
            from: c.statusFrom,
            to: c.statusTo,
            whodunnit: c.whodunnit,
          );
        })
        .toList()
      ..sort((a, b) => _compareDatesDesc(a.changedAt, b.changedAt));
    return List.unmodifiable(rows);
  }

  /// Transiciones agrupadas por una dimension del equipo, con desglose
  /// In->Out / Out->In.
  List<TransitionDimensionRow> transitionsByDimension(
    List<StatusTransition> transitions,
    EquipmentDimension dimension,
  ) {
    final byKey =
        _groupBy(transitions, (t) => t.dimension(dimension), keepNull: true);
    final rows = byKey.entries
        .map((e) => TransitionDimensionRow(
              key: e.key,
              total: e.value.length,
              inToOut: e.value.where((t) => t.isInToOut).length,
              outToIn: e.value.where((t) => t.isOutToIn).length,
            ))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return List.unmodifiable(rows);
  }

  /// Equipos con mas transiciones del tipo [from] -> [to] (p. ej. Out->In, el
  /// patron de un equipo que entra y sale de servicio sin parar).
  List<TopTransitionRow> topEquipmentByTransition(
    List<StatusTransition> transitions, {
    required String from,
    required String to,
    int n = 25,
  }) {
    final matching =
        transitions.where((t) => t.from == from && t.to == to).toList();
    final byRecord = _groupBy(matching, (t) => t.recordId);
    final rows = byRecord.entries
        .map((e) => TopTransitionRow(
              recordId: e.key,
              equipmentId: e.value.first.equipmentId,
              description: e.value.first.description,
              group: e.value.first.group,
              costCentre: e.value.first.costCentre,
              times: e.value.length,
              last: e.value
                  .map((t) => t.changedAt)
                  .whereType<DateTime>()
                  .fold<DateTime?>(
                      null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc),
            ))
        .toList()
      ..sort((a, b) => b.times.compareTo(a.times));
    return takeTop(rows, n);
  }

  /// Conteo por tipo de transicion ("In Service -> Out of Service": 42).
  List<TransitionSummaryRow> statusTransitionSummary(
    List<StatusTransition> transitions,
  ) {
    final counts = <String, int>{};
    for (final t in transitions) {
      final key = '${t.from} -> ${t.to}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final rows = counts.entries
        .map((e) => TransitionSummaryRow(transition: e.key, times: e.value))
        .toList()
      ..sort((a, b) => b.times.compareTo(a.times));
    return List.unmodifiable(rows);
  }

  /// Serie temporal de transiciones In Service -> Out of Service.
  List<InToOutPoint> inToOutOverTime(
    List<StatusTransition> transitions, {
    AnalyticsPeriod period = AnalyticsPeriod.monthly,
  }) {
    final buckets = bucketByPeriod(
      transitions.where((t) => t.isInToOut),
      period,
      dateOf: (t) => t.changedAt,
    );
    return List.unmodifiable(buckets.entries
        .map((e) => InToOutPoint(period: e.key, count: e.value.length)));
  }

  /// Por equipo: cuantas veces salio de servicio y cuantos dias aguanto en
  /// servicio antes de salir.
  ///
  /// El lapso se mide entre una ENTRADA a In Service y la siguiente SALIDA a
  /// Out of Service del mismo equipo. Un equipo que ya estaba en servicio antes
  /// del historico no tiene entrada previa: su primera salida cuenta como
  /// salida pero no aporta lapso.
  List<TimeInServiceRow> timeInService(List<StatusTransition> transitions) {
    final byRecord = _groupBy(
      transitions.where((t) => t.changedAt != null),
      (t) => t.recordId,
    );
    final rows = byRecord.entries.map((entry) {
      final chunk = entry.value
        ..sort((a, b) => a.changedAt!.compareTo(b.changedAt!));
      DateTime? lastIn;
      final spans = <double>[];
      var exits = 0;
      for (final t in chunk) {
        if (t.to == statusInService) {
          lastIn = t.changedAt;
        } else if (t.to == statusOutOfService) {
          exits += 1;
          if (lastIn != null) {
            spans.add(
                t.changedAt!.difference(lastIn).inSeconds / Duration.secondsPerDay);
            lastIn = null;
          }
        }
      }
      final meta = chunk.last;
      return TimeInServiceRow(
        recordId: entry.key,
        equipmentId: meta.equipmentId,
        description: meta.description,
        exitsToOutOfService: exits,
        avgDaysInService: spans.isEmpty
            ? null
            : roundTo(spans.reduce((a, b) => a + b) / spans.length, 1),
      );
    }).toList()
      ..sort((a, b) => b.exitsToOutOfService.compareTo(a.exitsToOutOfService));
    return List.unmodifiable(rows);
  }

  // =========================================================================
  // Temporal — cambios de atributos y auditoria
  // =========================================================================

  /// Eventos de cambio de un atributo de `EquipmentItem`, enlazados al equipo.
  ///
  /// Con [realOnly] (por defecto) solo reasignaciones, no altas iniciales.
  List<AttributeChange> attributeChanges(
    String attribute, {
    bool realOnly = true,
  }) {
    final lut = _equipmentByInternalId();
    final rows = changes
        .where((c) =>
            c.isEquipmentRecord &&
            c.attribute == attribute &&
            (!realOnly || c.isReassignment))
        .map((c) {
          final eq = c.recordId == null ? null : lut[c.recordId!];
          return AttributeChange(
            changedAt: c.changedAt,
            recordId: c.recordId,
            equipmentId: eq?.equipmentId,
            description: eq?.description,
            group: eq?.group,
            category: eq?.category,
            department: eq?.department,
            costCentre: eq?.costCentre,
            attribute: attribute,
            before: c.before,
            after: c.after,
            whodunnit: c.whodunnit,
          );
        })
        .toList()
      ..sort((a, b) => _compareDatesDesc(a.changedAt, b.changedAt));
    return List.unmodifiable(rows);
  }

  /// Equipos que mas veces cambiaron un atributo (p. ej. de cost centre).
  List<TopTransitionRow> topEquipmentByAttribute(
    String attribute, {
    int n = 25,
  }) {
    final byRecord = _groupBy(attributeChanges(attribute), (c) => c.recordId);
    final rows = byRecord.entries
        .map((e) => TopTransitionRow(
              recordId: e.key,
              equipmentId: e.value.first.equipmentId,
              description: e.value.first.description,
              group: e.value.first.group,
              costCentre: e.value.first.costCentre,
              times: e.value.length,
              last: e.value
                  .map((c) => c.changedAt)
                  .whereType<DateTime>()
                  .fold<DateTime?>(
                      null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc),
            ))
        .toList()
      ..sort((a, b) => b.times.compareTo(a.times));
    return takeTop(rows, n);
  }

  /// Cambios de un atributo agrupados por una dimension del equipo (p. ej.
  /// cambios de cost centre agrupados por el cost centre ACTUAL del equipo).
  List<AttributeDimensionRow> attributeChangeByDimension(
    String attribute,
    EquipmentDimension dimension,
  ) {
    final byKey = _groupBy(
      attributeChanges(attribute),
      (c) => c.dimension(dimension),
      keepNull: true,
    );
    final rows = byKey.entries
        .map((e) => AttributeDimensionRow(
              key: e.key,
              changes: e.value.length,
              equipmentCount:
                  e.value.map((c) => c.recordId).whereType<String>().toSet().length,
            ))
        .toList()
      ..sort((a, b) => b.changes.compareTo(a.changes));
    return List.unmodifiable(rows);
  }

  /// Atributos de equipo que mas se modifican (solo reasignaciones reales).
  List<AttributeChangeSummaryRow> attributeChangeSummary() {
    final byAttribute = _groupBy(
      changes.where((c) => c.isEquipmentRecord && c.isReassignment),
      (c) => c.attribute,
    );
    final rows = byAttribute.entries
        .map((e) => AttributeChangeSummaryRow(
              attribute: e.key,
              label: attrLabel(e.key),
              changes: e.value.length,
              equipmentCount:
                  e.value.map((c) => c.recordId).whereType<String>().toSet().length,
            ))
        .toList()
      ..sort((a, b) => b.changes.compareTo(a.changes));
    return List.unmodifiable(rows);
  }

  /// Historial completo de UN equipo, como la pestaña Audit Log de AdaptIQ.
  /// [recordId] es el id INTERNO ([Equipment.internalId]), no el visible.
  List<AuditLogRow> equipmentAuditLog(String recordId) {
    final rows = changes
        .where((c) => c.isEquipmentRecord && c.recordId == recordId)
        .map((c) => AuditLogRow(
              changedAt: c.changedAt,
              whodunnit: c.whodunnit,
              event: c.event,
              attributeLabel: c.attributeLabel,
              from: _renderValue(c.attribute, c.before),
              to: _renderValue(c.attribute, c.after),
            ))
        .toList()
      ..sort((a, b) => _compareDatesDesc(a.changedAt, b.changedAt));
    return List.unmodifiable(rows);
  }

  /// Quien hace los cambios: volumen por usuario, con desglose equipos / RFID.
  List<AuditUserRow> auditByUser() {
    final byUser = <String, List<ChangeEvent>>{};
    for (final c in changes) {
      byUser
          .putIfAbsent(c.whodunnit ?? '(desconocido)', () => <ChangeEvent>[])
          .add(c);
    }
    final rows = byUser.entries
        .map((e) => AuditUserRow(
              user: e.key,
              changes: e.value.length,
              equipmentChanges: e.value.where((c) => c.isEquipmentRecord).length,
              rfidChanges: e.value.where((c) => c.isRfidRecord).length,
              lastChange: _maxDate(e.value),
            ))
        .toList()
      ..sort((a, b) => b.changes.compareTo(a.changes));
    return List.unmodifiable(rows);
  }

  // -- helpers ---------------------------------------------------------------

  List<GroupSummary> _summarize(
    List<Equipment> rows,
    String? Function(Equipment) keyOf,
  ) {
    final byKey = <String, List<Equipment>>{};
    for (final e in rows) {
      byKey.putIfAbsent(categoryKey(keyOf(e)), () => <Equipment>[]).add(e);
    }
    final summaries = byKey.entries.map((e) {
      final total = e.value.length;
      final inService = e.value.where((x) => x.isInService).length;
      return GroupSummary(
        key: e.key,
        total: total,
        inService: inService,
        outOfService: e.value.where((x) => x.isOutOfService).length,
        decommissioned: e.value.where((x) => x.isDecommissioned).length,
        availabilityPct: roundTo(inService / total * 100, 1),
      );
    }).toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return List.unmodifiable(summaries);
  }

  Map<String, Equipment> _equipmentByInternalId() => {
        for (final e in equipment)
          if (e.internalId != null) e.internalId!: e,
      };

  /// Valor legible para el audit log: los ids de estado se resuelven a su
  /// nombre, el resto se muestra tal cual.
  static String? _renderValue(String? attribute, String? value) {
    if (value == null) return null;
    if (attribute == attrStatus) {
      return equipmentStatusById[value.trim()] ?? value;
    }
    return value;
  }
}

// -- utilidades internas -----------------------------------------------------

/// Agrupa por una clave de texto. Con [keepNull] las claves ausentes caen en
/// `(sin dato)`; sin el, esas filas se descartan (para agrupar por un id, donde
/// un `null` no es una categoria sino un registro inutilizable).
Map<String, List<T>> _groupBy<T>(
  Iterable<T> items,
  String? Function(T) keyOf, {
  bool keepNull = false,
}) {
  final out = <String, List<T>>{};
  for (final item in items) {
    final raw = keyOf(item);
    if (raw == null && !keepNull) continue;
    out.putIfAbsent(categoryKey(raw), () => <T>[]).add(item);
  }
  return out;
}

int _byChangedAtDesc(ChangeEvent a, ChangeEvent b) =>
    _compareDatesDesc(a.changedAt, b.changedAt);

/// Ordena descendente dejando las fechas ausentes al final.
int _compareDatesDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

DateTime? _maxDate(Iterable<ChangeEvent> events) => events
    .map((e) => e.changedAt)
    .whereType<DateTime>()
    .fold<DateTime?>(null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc);

// ===========================================================================
// Filas de resultado
// ===========================================================================

class FleetKpis {
  const FleetKpis({
    required this.total,
    required this.inService,
    required this.outOfService,
    required this.decommissioned,
    required this.availabilityPct,
    required this.contractorVehicles,
    required this.contractorPct,
    required this.lightVehicles,
  });

  final int total;
  final int inService;
  final int outOfService;
  final int decommissioned;
  final double availabilityPct;
  final int contractorVehicles;
  final double contractorPct;
  final int lightVehicles;
}

class GroupSummary {
  const GroupSummary({
    required this.key,
    required this.total,
    required this.inService,
    required this.outOfService,
    required this.decommissioned,
    required this.availabilityPct,
  });

  final String key;
  final int total;
  final int inService;
  final int outOfService;
  final int decommissioned;
  final double availabilityPct;
}

class StatusCount {
  const StatusCount({required this.status, required this.equipment});

  final String status;
  final int equipment;
}

class CompletenessRow {
  const CompletenessRow({
    required this.field,
    required this.filled,
    required this.missing,
    required this.completenessPct,
  });

  /// Nombre canonico del campo (`cost_centre`, `rfid`...).
  final String field;
  final int filled;
  final int missing;
  final double completenessPct;
}

class RfidChangeSummary {
  const RfidChangeSummary({
    required this.events,
    required this.assigned,
    required this.changed,
    required this.removed,
    required this.tagRecords,
  });

  final int events;
  final int assigned;
  final int changed;
  final int removed;

  /// Registros de tag distintos afectados.
  final int tagRecords;
}

class RfidChangePoint {
  const RfidChangePoint({
    required this.period,
    required this.assigned,
    required this.changed,
    required this.removed,
  });

  final DateTime period;
  final int assigned;
  final int changed;
  final int removed;

  int get total => assigned + changed + removed;
}

class RfidChurnRow {
  const RfidChurnRow({
    required this.recordId,
    required this.events,
    this.lastChange,
  });

  final String recordId;
  final int events;
  final DateTime? lastChange;
}

/// Una transicion de estado de UN equipo, ya resuelta a nombres legibles.
class StatusTransition {
  const StatusTransition({
    this.changedAt,
    this.recordId,
    this.equipmentId,
    this.description,
    this.group,
    this.category,
    this.department,
    this.costCentre,
    required this.from,
    required this.to,
    this.whodunnit,
  });

  final DateTime? changedAt;

  /// Id interno del equipo (clave del log).
  final String? recordId;
  final String? equipmentId;
  final String? description;
  final String? group;
  final String? category;
  final String? department;
  final String? costCentre;

  /// Estado de origen / destino, ya con nombre ('In Service'...).
  final String from;
  final String to;

  final String? whodunnit;

  bool get isInToOut => from == statusInService && to == statusOutOfService;
  bool get isOutToIn => from == statusOutOfService && to == statusInService;

  String? dimension(EquipmentDimension dim) => switch (dim) {
        EquipmentDimension.group => group,
        EquipmentDimension.category => category,
        EquipmentDimension.department => department,
        EquipmentDimension.costCentre => costCentre,
        EquipmentDimension.make => null, // la marca no viaja en el log
      };
}

class TransitionDimensionRow {
  const TransitionDimensionRow({
    required this.key,
    required this.total,
    required this.inToOut,
    required this.outToIn,
  });

  final String key;
  final int total;
  final int inToOut;
  final int outToIn;
}

class TopTransitionRow {
  const TopTransitionRow({
    required this.recordId,
    this.equipmentId,
    this.description,
    this.group,
    this.costCentre,
    required this.times,
    this.last,
  });

  final String recordId;
  final String? equipmentId;
  final String? description;
  final String? group;
  final String? costCentre;
  final int times;
  final DateTime? last;
}

class TransitionSummaryRow {
  const TransitionSummaryRow({required this.transition, required this.times});

  final String transition;
  final int times;
}

class InToOutPoint {
  const InToOutPoint({required this.period, required this.count});

  final DateTime period;
  final int count;
}

class TimeInServiceRow {
  const TimeInServiceRow({
    required this.recordId,
    this.equipmentId,
    this.description,
    required this.exitsToOutOfService,
    this.avgDaysInService,
  });

  final String recordId;
  final String? equipmentId;
  final String? description;
  final int exitsToOutOfService;

  /// `null` cuando no hubo ninguna entrada a servicio previa que medir.
  final double? avgDaysInService;
}

/// Un cambio de atributo, ya enlazado a su equipo.
class AttributeChange {
  const AttributeChange({
    this.changedAt,
    this.recordId,
    this.equipmentId,
    this.description,
    this.group,
    this.category,
    this.department,
    this.costCentre,
    required this.attribute,
    this.before,
    this.after,
    this.whodunnit,
  });

  final DateTime? changedAt;
  final String? recordId;
  final String? equipmentId;
  final String? description;
  final String? group;
  final String? category;
  final String? department;
  final String? costCentre;
  final String attribute;
  final String? before;
  final String? after;
  final String? whodunnit;

  String? dimension(EquipmentDimension dim) => switch (dim) {
        EquipmentDimension.group => group,
        EquipmentDimension.category => category,
        EquipmentDimension.department => department,
        EquipmentDimension.costCentre => costCentre,
        EquipmentDimension.make => null,
      };
}

class AttributeDimensionRow {
  const AttributeDimensionRow({
    required this.key,
    required this.changes,
    required this.equipmentCount,
  });

  final String key;
  final int changes;
  final int equipmentCount;
}

class AttributeChangeSummaryRow {
  const AttributeChangeSummaryRow({
    required this.attribute,
    required this.label,
    required this.changes,
    required this.equipmentCount,
  });

  final String attribute;
  final String label;
  final int changes;
  final int equipmentCount;
}

class AuditLogRow {
  const AuditLogRow({
    this.changedAt,
    this.whodunnit,
    this.event,
    required this.attributeLabel,
    this.from,
    this.to,
  });

  final DateTime? changedAt;
  final String? whodunnit;
  final String? event;
  final String attributeLabel;
  final String? from;
  final String? to;
}

class AuditUserRow {
  const AuditUserRow({
    required this.user,
    required this.changes,
    required this.equipmentChanges,
    required this.rfidChanges,
    this.lastChange,
  });

  final String user;
  final int changes;
  final int equipmentChanges;
  final int rfidChanges;
  final DateTime? lastChange;
}
