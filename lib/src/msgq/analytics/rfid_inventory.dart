/// Inventario de tags RFID — el reporte 'Inventory Tag Installed' desde el
/// endpoint. Port de `msgq/core/rfid_inventory.py`.
///
/// Clasifica cada cambio de RFID como NEW INSTALLATION / REPLACEMENT / REMOVAL,
/// con KPIs, agrupaciones y validaciones, alimentado por el LOG DE AUDITORIA
/// (`EquipmentRfid` / atributo `rfid`) en vez de por comparacion de snapshots.
/// Esa diferencia es la que arregla la columna de fecha: el log YA trae la fecha
/// REAL del cambio, no la del inventario en que se noto.
///
/// Enlace tag -> equipo
/// --------------------
/// La API no expone ningun FK del tag a su equipo (el `ChangeEvent` no tiene
/// relacion al equipo y `rfidTags` es solo una lista de valores). El unico
/// enlace posible es POR VALOR, en cascada:
///
///   1. contra el maestro ACTUAL (tags vigentes) — resuelve altas y reemplazos;
///   2. contra el historial de asignaciones observado ([RfidAssignment]) — el
///      equipo sigue existiendo aunque su tag ya no; asi se resuelven las
///      remociones, que de otro modo serian irrecuperables;
///   3. si tampoco, se marca `(no identificado)`. Nunca se inventa un equipo.
///
/// El producto no existe en `EquipmentItem`: sale de los productos HABILITADOS
/// (`consumptionTanks`) y, como respaldo, del mas despachado del historial.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/change_event.dart';
import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';

/// Una fila del reporte de instalacion.
class TagInstallation {
  const TagInstallation({
    required this.operation,
    required this.date,
    required this.equipmentId,
    this.tag,
    this.costCentre,
    this.department,
    this.product,
    this.whodunnit,
    this.status,
    this.category,
    this.group,
    this.description,
  });

  final RfidOperation operation;

  /// Fecha REAL del cambio, en hora LOCAL del sitio.
  final DateTime date;

  /// Codigo del equipo, o `(no identificado)`.
  final String equipmentId;

  /// El tag nuevo en un alta o reemplazo; el que se quito en una remocion.
  final String? tag;

  final String? costCentre;
  final String? department;
  final String? product;
  final String? whodunnit;

  // Columnas de soporte para validaciones y agrupaciones.
  final String? status;
  final String? category;
  final String? group;
  final String? description;

  bool get isIdentified =>
      equipmentId.trim().isNotEmpty && equipmentId != unidentifiedLabel;

  /// Dispara una validacion: tag puesto en un equipo fuera de servicio, o alta
  /// / reemplazo sin equipo identificado.
  bool get isAnomalous =>
      status?.trim() == statusOutOfService ||
      (operation != RfidOperation.removal && !isIdentified);
}

/// Atributos del equipo que viajan a cada fila del reporte.
class _EquipmentAttrs {
  const _EquipmentAttrs({
    this.equipmentId,
    this.costCentre,
    this.department,
    this.product,
    this.status,
    this.category,
    this.group,
    this.description,
  });

  final String? equipmentId;
  final String? costCentre;
  final String? department;
  final String? product;
  final String? status;
  final String? category;
  final String? group;
  final String? description;
}

/// Fila de un resumen agrupado, con desglose por tipo de operacion.
class RfidGroupSummary {
  const RfidGroupSummary({
    required this.key,
    required this.installations,
    required this.newInstallations,
    required this.replacements,
    required this.removals,
  });

  final String key;
  final int installations;
  final int newInstallations;
  final int replacements;
  final int removals;
}

/// Equipo con su volumen de cambios de tag en el periodo.
class TagChurnRow {
  const TagChurnRow({
    required this.equipmentId,
    this.description,
    required this.changes,
    required this.newInstallations,
    required this.replacements,
    required this.removals,
  });

  final String equipmentId;
  final String? description;
  final int changes;
  final int newInstallations;
  final int replacements;
  final int removals;
}

/// El mismo tag asignado a mas de un equipo en el maestro vigente.
class DuplicateTag {
  const DuplicateTag({
    required this.tag,
    required this.equipmentId,
    this.description,
    this.status,
    required this.equipmentCount,
  });

  final String tag;
  final String equipmentId;
  final String? description;
  final String? status;

  /// Cuantos equipos comparten este tag.
  final int equipmentCount;
}

/// Conteo de una validacion.
class RfidValidation {
  const RfidValidation({
    required this.name,
    required this.anomalies,
    required this.description,
  });

  final String name;
  final int anomalies;
  final String description;
}

class RfidKpis {
  const RfidKpis({
    required this.newInstallations,
    required this.replacements,
    required this.removals,
    required this.distinctTags,
    required this.equipmentWithRfid,
    required this.totalEquipment,
  });

  final int newInstallations;
  final int replacements;
  final int removals;
  final int distinctTags;
  final int equipmentWithRfid;
  final int totalEquipment;
}

/// Punto mensual de la serie de eventos por tipo.
class RfidEventPoint {
  const RfidEventPoint({
    required this.period,
    required this.newInstallations,
    required this.replacements,
    required this.removals,
  });

  final DateTime period;
  final int newInstallations;
  final int replacements;
  final int removals;

  int get total => newInstallations + replacements + removals;
}

/// Punto mensual de la tendencia de auditoria.
class RfidAuditPoint {
  const RfidAuditPoint({
    required this.period,
    required this.activity,
    required this.removals,
    required this.anomalies,
  });

  final DateTime period;

  /// Todos los cambios del mes.
  final int activity;

  /// Tags retirados: un alza sostenida puede indicar bajas de flota, robo de
  /// tags o equipos saliendo de servicio.
  final int removals;

  /// Filas que disparan una validacion.
  final int anomalies;
}

// ===========================================================================
// Auditoria
// ===========================================================================

class RfidInventoryAudit {
  const RfidInventoryAudit._({
    required this.report,
    required this.equipment,
    required this.kpis,
  });

  /// Filas del reporte, de la mas antigua a la mas reciente.
  final List<TagInstallation> report;

  /// Maestro vigente (necesario para las validaciones sobre el inventario).
  final List<Equipment> equipment;

  final RfidKpis kpis;

  /// Construye el reporte a partir del log de auditoria.
  ///
  /// [from]/[to] son FECHAS LOCALES inclusivas; [to] cubre el dia completo.
  /// [tzOffsetHours] convierte el `changedAt` en UTC del log a la hora local del
  /// sitio, para que el filtro y la fecha reflejen el dia operativo: sin eso,
  /// una instalacion nocturna cae en el dia siguiente y se pierde del reporte.
  static RfidInventoryAudit run({
    required List<ChangeEvent> changes,
    List<Equipment> equipment = const [],
    List<Movement> movements = const [],
    List<ConsumptionLimit> limits = const [],
    List<RfidAssignment> history = const [],
    DateTime? from,
    DateTime? to,
    int tzOffsetHours = 0,
  }) {
    final products = equipmentProductMap(movements: movements, limits: limits);
    final byTag = _tagLookup(equipment, products);
    final byId = {
      for (final e in equipment)
        if (asText(e.equipmentId) != null)
          e.equipmentId!: _attrsOf(e, products),
    };
    final assignedTo = {
      for (final h in history)
        if (h.equipmentId != null) h.tag.toUpperCase(): h.equipmentId!,
    };

    final rows = <TagInstallation>[];
    for (final c in changes) {
      if (!c.isRfidRecord || c.attribute != attrRfid) continue;
      final changedAt = c.changedAt;
      if (changedAt == null) continue;
      final local = changedAt.add(Duration(hours: tzOffsetHours));
      if (from != null && local.isBefore(from)) continue;
      if (to != null && !local.isBefore(_endOfDay(to))) continue;

      final operation = RfidOperation.classify(before: c.before, after: c.after);
      final tag = operation == RfidOperation.removal ? c.before : c.after;
      final key = asText(tag)?.toUpperCase();

      // Cascada: maestro vigente -> historial observado -> sin identificar.
      var attrs = key == null ? null : byTag[key];
      if (attrs == null && key != null) {
        final ownerId = assignedTo[key];
        if (ownerId != null) {
          attrs = byId[ownerId] ?? _EquipmentAttrs(equipmentId: ownerId);
        }
      }

      rows.add(TagInstallation(
        operation: operation,
        date: local,
        equipmentId: asText(attrs?.equipmentId) ?? unidentifiedLabel,
        tag: asText(tag),
        costCentre: attrs?.costCentre,
        department: attrs?.department,
        product: attrs?.product,
        whodunnit: c.whodunnit,
        status: attrs?.status,
        category: attrs?.category,
        group: attrs?.group,
        description: attrs?.description,
      ));
    }
    rows.sort((a, b) => a.date.compareTo(b.date));

    return RfidInventoryAudit._(
      report: List.unmodifiable(rows),
      equipment: equipment,
      kpis: RfidKpis(
        newInstallations: _countOf(rows, RfidOperation.newInstallation),
        replacements: _countOf(rows, RfidOperation.replacement),
        removals: _countOf(rows, RfidOperation.removal),
        distinctTags:
            rows.map((r) => r.tag).whereType<String>().toSet().length,
        equipmentWithRfid: equipment.where((e) => e.rfidTags.isNotEmpty).length,
        totalEquipment: equipment.length,
      ),
    );
  }

  // -- agrupaciones ---------------------------------------------------------

  /// Equipos del maestro que HOY tienen al menos un tag asignado.
  List<Equipment> currentInventory() => equipment
      .where((e) => e.rfidTags.isNotEmpty)
      .toList(growable: false);

  /// Conteo por tipo de operacion.
  Map<RfidOperation, int> byType() => {
        for (final op in RfidOperation.values) op: _countOf(report, op),
      };

  List<RfidGroupSummary> byDepartment() => _groupBy((r) => r.department);
  List<RfidGroupSummary> byCostCentre() => _groupBy((r) => r.costCentre);
  List<RfidGroupSummary> byCategory() => _groupBy((r) => r.category);

  /// Actividad de tags por GRUPO del equipo (Newmont / SEMC / Major Drilling...).
  List<RfidGroupSummary> byGroup() => _groupBy((r) => r.group);

  /// Equipos con MAS cambios de tag en el periodo.
  ///
  /// Un equipo que cambia de tag muy seguido señala un problema fisico (el tag
  /// se cae o se daña, lector con fallas) o un proceso mal aplicado. Solo cuenta
  /// equipos identificados: agrupar los `(no identificado)` los sumaria a todos
  /// bajo una misma fila sin sentido.
  List<TagChurnRow> tagChangeFrequency({int topN = 15}) {
    final byEquipment = <String, List<TagInstallation>>{};
    for (final r in report.where((r) => r.isIdentified)) {
      byEquipment.putIfAbsent(r.equipmentId, () => <TagInstallation>[]).add(r);
    }
    final rows = byEquipment.entries
        .map((e) => TagChurnRow(
              equipmentId: e.key,
              description: e.value
                  .map((r) => r.description)
                  .firstWhere((d) => d != null, orElse: () => null),
              changes: e.value.length,
              newInstallations:
                  _countOf(e.value, RfidOperation.newInstallation),
              replacements: _countOf(e.value, RfidOperation.replacement),
              removals: _countOf(e.value, RfidOperation.removal),
            ))
        .toList()
      ..sort((a, b) {
        final byChanges = b.changes.compareTo(a.changes);
        return byChanges != 0
            ? byChanges
            : a.equipmentId.compareTo(b.equipmentId);
      });
    return takeTop(rows, topN);
  }

  // -- validaciones ---------------------------------------------------------

  /// Tags instalados o reemplazados en un equipo 'Out of Service'.
  List<TagInstallation> outOfServiceInstallations() => report
      .where((r) => r.status?.trim() == statusOutOfService)
      .toList(growable: false);

  /// El mismo tag asignado a mas de un equipo en el maestro vigente.
  ///
  /// Se detecta sobre el MAESTRO y no sobre el reporte: el enlace por valor
  /// asocia cada tag a un solo equipo, asi que la doble asignacion solo es
  /// visible en el inventario actual.
  List<DuplicateTag> duplicateTags() {
    final owners = <String, List<Equipment>>{};
    for (final e in equipment) {
      for (final tag in e.rfidTags) {
        owners.putIfAbsent(tag.toUpperCase(), () => <Equipment>[]).add(e);
      }
    }
    final out = <DuplicateTag>[];
    for (final entry in owners.entries) {
      final distinct =
          entry.value.map((e) => e.equipmentId).whereType<String>().toSet();
      if (distinct.length <= 1) continue;
      for (final e in entry.value) {
        out.add(DuplicateTag(
          tag: entry.key,
          equipmentId: e.equipmentId ?? unidentifiedLabel,
          description: e.description,
          status: e.status,
          equipmentCount: distinct.length,
        ));
      }
    }
    out.sort((a, b) {
      final byTag = a.tag.compareTo(b.tag);
      return byTag != 0 ? byTag : a.equipmentId.compareTo(b.equipmentId);
    });
    return List.unmodifiable(out);
  }

  /// Equipos que aparecen mas de una vez en el periodo (re-tagueo legitimo o
  /// posible inconsistencia).
  List<TagInstallation> duplicateIds() {
    final counts = <String, int>{};
    for (final r in report.where((r) => r.isIdentified)) {
      counts[r.equipmentId] = (counts[r.equipmentId] ?? 0) + 1;
    }
    final rows = report
        .where((r) => r.isIdentified && (counts[r.equipmentId] ?? 0) > 1)
        .toList()
      ..sort((a, b) => a.equipmentId.compareTo(b.equipmentId));
    return List.unmodifiable(rows);
  }

  /// Altas y reemplazos cuyo equipo NO se pudo identificar.
  ///
  /// Las remociones se excluyen: el equipo de un tag retirado puede ser
  /// legitimamente desconocido si nunca se observo mientras estuvo asignado.
  List<TagInstallation> incompleteRecords() => report
      .where((r) => r.operation != RfidOperation.removal && !r.isIdentified)
      .toList(growable: false);

  List<RfidValidation> validationSummary() => List.unmodifiable([
        RfidValidation(
          name: 'Equipos fuera de servicio',
          anomalies: outOfServiceInstallations().length,
          description: "Tag instalado en equipo con estado 'Out of Service'",
        ),
        RfidValidation(
          name: 'Tags duplicados',
          anomalies: duplicateTags().length,
          description: 'El mismo tag asignado a mas de un equipo en el maestro',
        ),
        RfidValidation(
          name: 'IDs duplicados en el periodo',
          anomalies: duplicateIds().length,
          description: 'El mismo equipo aparece mas de una vez (re-tagueo)',
        ),
        RfidValidation(
          name: 'Altas/reemplazos sin equipo',
          anomalies: incompleteRecords().length,
          description: 'Alta o reemplazo sin equipo identificado',
        ),
      ]);

  // -- series temporales ----------------------------------------------------

  /// Eventos por mes y tipo.
  List<RfidEventPoint> eventsOverTime({
    AnalyticsPeriod period = AnalyticsPeriod.monthly,
  }) {
    final buckets = bucketByPeriod(report, period, dateOf: (r) => r.date);
    return List.unmodifiable(buckets.entries.map((e) => RfidEventPoint(
          period: e.key,
          newInstallations: _countOf(e.value, RfidOperation.newInstallation),
          replacements: _countOf(e.value, RfidOperation.replacement),
          removals: _countOf(e.value, RfidOperation.removal),
        )));
  }

  /// Actividad, remociones y anomalias por mes.
  List<RfidAuditPoint> auditTrends({
    AnalyticsPeriod period = AnalyticsPeriod.monthly,
  }) {
    final buckets = bucketByPeriod(report, period, dateOf: (r) => r.date);
    return List.unmodifiable(buckets.entries.map((e) => RfidAuditPoint(
          period: e.key,
          activity: e.value.length,
          removals: _countOf(e.value, RfidOperation.removal),
          anomalies: e.value.where((r) => r.isAnomalous).length,
        )));
  }

  // -- helpers --------------------------------------------------------------

  List<RfidGroupSummary> _groupBy(String? Function(TagInstallation) keyOf) {
    final groups = <String, List<TagInstallation>>{};
    for (final r in report) {
      groups.putIfAbsent(categoryKey(keyOf(r)), () => <TagInstallation>[]).add(r);
    }
    final rows = groups.entries
        .map((e) => RfidGroupSummary(
              key: e.key,
              installations: e.value.length,
              newInstallations:
                  _countOf(e.value, RfidOperation.newInstallation),
              replacements: _countOf(e.value, RfidOperation.replacement),
              removals: _countOf(e.value, RfidOperation.removal),
            ))
        .toList()
      ..sort((a, b) => b.installations.compareTo(a.installations));
    return List.unmodifiable(rows);
  }
}

int _countOf(Iterable<TagInstallation> rows, RfidOperation operation) =>
    rows.where((r) => r.operation == operation).length;

DateTime _endOfDay(DateTime day) =>
    DateTime.utc(day.year, day.month, day.day).add(const Duration(days: 1));

// ===========================================================================
// Enlace tag -> equipo y producto
// ===========================================================================

/// Producto(s) por equipo: `{equipmentId: producto}`.
///
/// Fuente primaria: los productos HABILITADOS del equipo (`consumptionTanks`, el
/// panel 'Products consumed' de AdaptIQ), unidos por ", ". Asi el producto sale
/// aunque el equipo sea nuevo y no haya despachado nunca. Respaldo: el producto
/// mas despachado del historial, para equipos sin limite cargado en el FMS.
///
/// Incluye alias sin espacios internos, para puentear los registros DUPLICADOS
/// del maestro del FMS ('C- SE-12' vs 'C-SE-12': el mismo activo fisico, pero
/// los limites cuelgan de una sola de las dos variantes).
Map<String, String> equipmentProductMap({
  List<Movement> movements = const [],
  List<ConsumptionLimit> limits = const [],
}) {
  final out = <String, String>{};

  final enabledByEquipment = <String, Set<String>>{};
  for (final l in limits) {
    final id = asText(l.equipmentId);
    final product = asText(l.product);
    if (id == null || product == null) continue;
    enabledByEquipment.putIfAbsent(id, () => <String>{}).add(product);
  }
  for (final entry in enabledByEquipment.entries) {
    final products = entry.value.toList()..sort();
    out[entry.key] = products.join(', ');
  }

  // Respaldo: el producto mas despachado (solo para equipos sin limite).
  final counts = <String, Map<String, int>>{};
  for (final m in movements.where((m) => m.isDispense)) {
    final id = asText(m.equipmentId);
    final product = asText(m.product);
    if (id == null || product == null || out.containsKey(id)) continue;
    final byProduct = counts.putIfAbsent(id, () => <String, int>{});
    byProduct[product] = (byProduct[product] ?? 0) + 1;
  }
  for (final entry in counts.entries) {
    final top = entry.value.entries.reduce((a, b) {
      if (a.value != b.value) return a.value > b.value ? a : b;
      return a.key.compareTo(b.key) <= 0 ? a : b; // desempate estable
    });
    out[entry.key] = top.key;
  }

  for (final entry in out.entries.toList()) {
    final alias = entry.key.replaceAll(RegExp(r'\s+'), '');
    if (alias != entry.key && !out.containsKey(alias)) {
      out[alias] = entry.value;
    }
  }
  return out;
}

/// `{TAG_MAYUSCULAS: atributos del equipo}` desde el maestro ACTUAL.
///
/// Si el mismo tag estuviera en dos equipos gana el primero; la duplicidad la
/// reporta [RfidInventoryAudit.duplicateTags], no se resuelve aqui en silencio.
Map<String, _EquipmentAttrs> _tagLookup(
  List<Equipment> equipment,
  Map<String, String> products,
) {
  final out = <String, _EquipmentAttrs>{};
  for (final e in equipment) {
    final attrs = _attrsOf(e, products);
    for (final tag in e.rfidTags) {
      out.putIfAbsent(tag.toUpperCase(), () => attrs);
    }
  }
  return out;
}

_EquipmentAttrs _attrsOf(Equipment e, Map<String, String> products) {
  final id = e.equipmentId;
  final product = id == null
      ? null
      : products[id] ?? products[id.replaceAll(RegExp(r'\s+'), '')];
  return _EquipmentAttrs(
    equipmentId: id,
    costCentre: e.costCentre,
    department: e.department,
    product: product,
    status: e.status,
    category: e.category,
    group: e.group,
    description: e.description,
  );
}
