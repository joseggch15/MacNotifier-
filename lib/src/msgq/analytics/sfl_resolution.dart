/// Resolucion del Safe Fill Level por equipo — port de
/// `msgq/core/dispense_report.py::resolve_sfl`.
///
/// Vive aparte porque lo comparten varios auditores: la actividad lo usa para
/// decidir si un tanque pudo absorber unos litros, y el reporte de dispensas
/// para dimensionar cada despacho. Tener DOS cascadas distintas daria hallazgos
/// contradictorios sobre el mismo equipo.
///
/// La cascada, en orden:
///
///   1. LIMITE REAL del FMS por (equipo, producto), priorizando el producto
///      DOMINANTE del equipo — el mas despachado. Un equipo con varios
///      productos tiene varios SFL, y el pertinente es el del combustible que
///      realmente recibe, no el de un lubricante marginal.
///   2. RESPALDO por palabra clave de categoria, para los equipos sin limite
///      cargado en el FMS.
///   3. Sin dato: el equipo no participa de las reglas que dependen del SFL.
///
/// Dart puro: sin dependencias de Flutter.
library;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';

/// SFL resuelto de un equipo, con su procedencia.
class ResolvedSfl {
  const ResolvedSfl({
    required this.equipmentId,
    this.sfl,
    required this.source,
  });

  final String equipmentId;

  /// Litros. `null` cuando no se pudo resolver.
  final double? sfl;

  final SflSource source;

  bool get isKnown => sfl != null;
}

/// SFL de respaldo por palabra clave de categoria. `null` si ninguna coincide.
double? fallbackSfl(String? category) {
  final cat = category?.trim().toUpperCase();
  if (cat == null || cat.isEmpty) return null;
  for (final (keyword, sfl) in sflFallbackByCategory) {
    if (cat.contains(keyword)) return sfl;
  }
  return null;
}

/// Resuelve el SFL de cada equipo que aparece en [movements].
///
/// Solo se resuelven los equipos con despachos: un SFL sin transacciones no
/// tiene nada que dimensionar.
Map<String, ResolvedSfl> resolveSfl({
  required List<Movement> movements,
  List<ConsumptionLimit> limits = const [],
  List<Equipment> equipment = const [],
}) {
  // Producto DOMINANTE por equipo (el mas despachado), con desempate alfabetico
  // para que el resultado no dependa del orden de llegada de las filas.
  final dispenseCounts = <String, Map<String, int>>{};
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    if (id == null) continue;
    final product = asText(m.product)?.toUpperCase() ?? '';
    dispenseCounts.putIfAbsent(id, () => <String, int>{});
    dispenseCounts[id]![product] = (dispenseCounts[id]![product] ?? 0) + 1;
  }
  if (dispenseCounts.isEmpty) return const {};

  final dominant = <String, String>{};
  for (final entry in dispenseCounts.entries) {
    final top = entry.value.entries.reduce((a, b) {
      if (a.value != b.value) return a.value > b.value ? a : b;
      return a.key.compareTo(b.key) <= 0 ? a : b;
    });
    if (top.key.isNotEmpty) dominant[entry.key] = top.key;
  }

  // Limites por (equipo, PRODUCTO) y el maximo por equipo (respaldo interno,
  // cuando el producto dominante no tiene limite propio).
  final byPair = <String, double>{};
  final byEquipmentMax = <String, double>{};
  for (final l in limits) {
    final id = asText(l.equipmentId);
    final product = asText(l.product)?.toUpperCase();
    if (id == null || product == null || l.sfl <= 0) continue;
    byPair['$id|$product'] = l.sfl;
    final current = byEquipmentMax[id];
    if (current == null || l.sfl > current) byEquipmentMax[id] = l.sfl;
  }

  final categoryById = {
    for (final e in equipment)
      if (realEquipmentId(e.equipmentId) != null && e.category != null)
        realEquipmentId(e.equipmentId)!: e.category!,
  };

  final out = <String, ResolvedSfl>{};
  for (final id in dispenseCounts.keys) {
    final product = dominant[id];
    final fromLimit =
        (product == null ? null : byPair['$id|$product']) ?? byEquipmentMax[id];
    if (fromLimit != null) {
      out[id] = ResolvedSfl(
        equipmentId: id,
        sfl: fromLimit,
        source: SflSource.limit,
      );
      continue;
    }
    final fromCategory = fallbackSfl(categoryById[id]);
    out[id] = ResolvedSfl(
      equipmentId: id,
      sfl: fromCategory,
      source: fromCategory == null ? SflSource.none : SflSource.fallback,
    );
  }
  return Map.unmodifiable(out);
}
