/// Auditoria de coherencia Producto <-> Equipo (posible tag clonado) — port de
/// `msgq/core/product_audit.py`.
///
/// Detecta despachos cuyo producto es AJENO al equipo: un equipo solo-DIESEL al
/// que le cargan Coolant o Hydraulic Fluid, o al reves. Suele indicar un tag
/// RFID clonado o un equipo mal configurado en el maestro.
///
/// El reto es TEMPORAL, y es lo que hace este modulo mas sutil de lo que
/// parece: un producto pudo estar habilitado y luego deshabilitarse, dejando
/// despachos perfectamente legitimos en el historico. La API no expone cuando
/// se habilito cada uno. Por eso el conjunto permitido de un equipo es la union
/// de tres fuentes:
///
///   1. el MAESTRO vigente (`consumptionTanks`);
///   2. el HISTORIAL observado de habilitacion ([ProductAssignment]);
///   3. el USO ESTABLECIDO: productos con huella real en el propio historial de
///      despachos del equipo (suficientes eventos, suficiente span, o
///      suficiente peso relativo).
///
/// Un equipo sin ninguna base se OMITE en vez de marcarse: no hay con que
/// juzgarlo, y marcarlo seria ruido, no un hallazgo.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';

/// Un despacho de producto ajeno al equipo.
class ProductMismatch {
  const ProductMismatch({
    this.date,
    required this.equipmentId,
    this.equipmentDescription,
    this.equipmentStatus,
    this.product,
    required this.productClassOf,
    this.expectedProducts,
    this.expectedClasses,
    this.volume,
    this.fieldUser,
    this.dispensingPoint,
    this.sourceId,
    required this.crossClass,
  });

  final DateTime? date;
  final String equipmentId;
  final String? equipmentDescription;
  final String? equipmentStatus;
  final String? product;

  /// Clase del producto despachado.
  final ProductClass productClassOf;

  /// Productos que el equipo SI tiene establecidos, para el contraste.
  final String? expectedProducts;
  final String? expectedClasses;

  final double? volume;
  final String? fieldUser;

  /// Tanque o punto desde el que se despacho.
  final String? dispensingPoint;

  final String? sourceId;

  /// Cruce entre CLASES (combustible vs fluido). Es la señal fuerte de tag
  /// clonado: que a un equipo de diesel le carguen refrigerante no es una mala
  /// configuracion, es otra maquina.
  final bool crossClass;

  /// Categoria canonica de la alerta.
  String get alertCategory =>
      crossClass ? alertProductForeign : alertProductOffMaster;
}

class ProductAuditKpis {
  const ProductAuditKpis({
    required this.mismatches,
    required this.crossClass,
    required this.equipmentAffected,
  });

  final int mismatches;
  final int crossClass;
  final int equipmentAffected;
}

class ProductAudit {
  const ProductAudit._({required this.mismatches, required this.kpis});

  final List<ProductMismatch> mismatches;
  final ProductAuditKpis kpis;

  List<ProductMismatch> get crossClassMismatches =>
      mismatches.where((m) => m.crossClass).toList(growable: false);

  static ProductAudit run({
    required List<Movement> movements,
    List<ConsumptionLimit> limits = const [],
    List<ProductAssignment> productHistory = const [],
  }) {
    final rows = productMismatchesOf(
      movements: movements,
      limits: limits,
      productHistory: productHistory,
    );
    return ProductAudit._(
      mismatches: rows,
      kpis: ProductAuditKpis(
        mismatches: rows.length,
        crossClass: rows.where((m) => m.crossClass).length,
        equipmentAffected: rows.map((m) => m.equipmentId).toSet().length,
      ),
    );
  }
}

/// Despachos cuyo (equipo, producto) no esta permitido.
List<ProductMismatch> productMismatchesOf({
  required List<Movement> movements,
  List<ConsumptionLimit> limits = const [],
  List<ProductAssignment> productHistory = const [],
}) {
  // Despachos utilizables: con equipo real y producto identificable.
  final dispenses = <({Movement movement, String equipmentId, String product})>[];
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    final product = asText(m.product);
    if (id == null || product == null) continue;
    dispenses.add((
      movement: m,
      equipmentId: id,
      product: product.toUpperCase(),
    ));
  }
  if (dispenses.isEmpty) return const [];

  // Conjunto permitido: maestro U historial observado U uso establecido.
  final allowed = <String, Set<String>>{};
  final displayLabels = <String, Set<String>>{};

  void allow(String equipmentId, String productUpper, String? label) {
    allowed.putIfAbsent(equipmentId, () => <String>{}).add(productUpper);
    displayLabels
        .putIfAbsent(equipmentId, () => <String>{})
        .add(asText(label) ?? productUpper);
  }

  for (final l in limits) {
    final id = asText(l.equipmentId);
    final product = asText(l.product);
    if (id == null || product == null) continue;
    allow(id, product.toUpperCase(), product);
  }
  for (final h in productHistory) {
    final id = asText(h.equipmentId);
    final product = asText(h.product);
    if (id == null || product == null) continue;
    allow(id, product.toUpperCase(), product);
  }
  for (final entry in _establishedByUsage(dispenses).entries) {
    for (final e in entry.value.entries) {
      allow(entry.key, e.key, e.value);
    }
  }

  final allowedClasses = <String, Set<ProductClass>>{
    for (final e in allowed.entries)
      e.key: e.value.map(productClass).toSet(),
  };

  const known = {ProductClass.fuel, ProductClass.fluid};
  final out = <ProductMismatch>[];
  for (final d in dispenses) {
    if (allowed[d.equipmentId]?.contains(d.product) ?? false) continue;
    final classes = allowedClasses[d.equipmentId];
    // Sin base para juzgar al equipo: se omite en vez de marcar por defecto.
    if (classes == null || classes.isEmpty) continue;

    final pclass = productClass(d.movement.product);
    final knownForEquipment = classes.where(known.contains).toSet();
    final cross = known.contains(pclass) &&
        knownForEquipment.isNotEmpty &&
        !knownForEquipment.contains(pclass);

    final labels = (displayLabels[d.equipmentId] ?? <String>{}).toList()..sort();
    final classLabels = classes.map((c) => c.label).toList()..sort();

    out.add(ProductMismatch(
      date: d.movement.recordCollectedAt ?? d.movement.updatedAt,
      equipmentId: d.equipmentId,
      equipmentDescription: asText(d.movement.equipmentDescription),
      equipmentStatus: asText(d.movement.equipmentStatus),
      product: asText(d.movement.product),
      productClassOf: pclass,
      expectedProducts: labels.isEmpty ? null : labels.join(', '),
      expectedClasses: classLabels.isEmpty ? null : classLabels.join(', '),
      volume: d.movement.volume,
      fieldUser: d.movement.fieldUser,
      dispensingPoint: asText(d.movement.tank),
      sourceId: d.movement.id,
      crossClass: cross,
    ));
  }
  // Los cruces de clase primero, luego los mas recientes.
  out.sort((a, b) {
    if (a.crossClass != b.crossClass) return a.crossClass ? -1 : 1;
    if (a.date == null && b.date == null) return 0;
    if (a.date == null) return 1;
    if (b.date == null) return -1;
    return b.date!.compareTo(a.date!);
  });
  return List.unmodifiable(out);
}

/// Productos con huella real en el historial de despachos de cada equipo.
///
/// Un producto cuenta como establecido —legitimo, aunque hoy no figure
/// habilitado— si cumple cualquiera de: suficientes despachos, suficiente span
/// temporal, o suficiente peso relativo. La regla de peso exige ademas 2
/// despachos: un UNICO despacho aislado nunca se establece solo, que es
/// justamente el cruce que se quiere marcar en equipos de baja actividad.
Map<String, Map<String, String>> _establishedByUsage(
  List<({Movement movement, String equipmentId, String product})> dispenses,
) {
  final counts = <String, Map<String, int>>{};
  final firstSeen = <String, DateTime>{};
  final lastSeen = <String, DateTime>{};
  final labels = <String, String>{};
  final totals = <String, int>{};

  for (final d in dispenses) {
    final pairKey = '${d.equipmentId}|${d.product}';
    counts.putIfAbsent(d.equipmentId, () => <String, int>{});
    counts[d.equipmentId]![d.product] =
        (counts[d.equipmentId]![d.product] ?? 0) + 1;
    totals[d.equipmentId] = (totals[d.equipmentId] ?? 0) + 1;
    labels.putIfAbsent(pairKey, () => asText(d.movement.product) ?? d.product);
    final date = d.movement.recordCollectedAt ?? d.movement.updatedAt;
    if (date == null) continue;
    final first = firstSeen[pairKey];
    if (first == null || date.isBefore(first)) firstSeen[pairKey] = date;
    final last = lastSeen[pairKey];
    if (last == null || date.isAfter(last)) lastSeen[pairKey] = date;
  }

  final out = <String, Map<String, String>>{};
  for (final equipment in counts.entries) {
    final total = totals[equipment.key] ?? 0;
    for (final product in equipment.value.entries) {
      final pairKey = '${equipment.key}|${product.key}';
      final n = product.value;
      final first = firstSeen[pairKey];
      final last = lastSeen[pairKey];
      final spanDays = (first == null || last == null)
          ? 0.0
          : last.difference(first).inSeconds / Duration.secondsPerDay;
      final share = total == 0 ? 0.0 : n / total;

      final established = n >= productMismatchMinEvents ||
          spanDays >= productMismatchMinDays ||
          (share >= productMismatchMinShare && n >= 2);
      if (!established) continue;
      out.putIfAbsent(equipment.key, () => <String, String>{})[product.key] =
          labels[pairKey] ?? product.key;
    }
  }
  return out;
}
