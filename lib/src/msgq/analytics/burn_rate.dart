/// Auditoria del Burn Rate (consumo de combustible, L/h) — port de
/// `msgq/core/burn_rate.py`.
///
/// AdaptIQ publica un burn rate por equipo/dia (Litres Consumed / SMU Increase).
/// Aqui se RECONSTRUYE desde los despachos replicados, para poder auditarlo y
/// marcar los equipos con comportamiento anomalo.
///
/// Metodo «tanque-a-tanque», el estandar del dominio:
///
///   * Para cada equipo se ordenan sus despachos por fecha.
///   * Entre dos consecutivos, los litros del POSTERIOR reponen lo quemado desde
///     el anterior, y el avance del SMU es el uso del intervalo:
///
///         burnRate = litros(despacho_n) / (SMU_n - SMU_n-1)
///
///   * Asuncion: el repostaje llena el tanque. Los repostajes parciales meten
///     ruido — por eso TODO se resume con mediana y MAD, inmunes justamente a
///     los outliers que se quieren detectar.
///
/// Dos granularidades de anomalia:
///
///   1. EQUIPO vs su categoria: el burn rate tipico del equipo contra la linea
///      base de su categoria. 'Alto' = sobre-consumo (fuga, robo, falla
///      mecanica); 'Bajo' = sub-consumo (medidor mal o despachos sin registrar).
///   2. INTERVALO atipico: un despacho puntual que se aparta del propio
///      historial del equipo.
///
/// Las series se encadenan por (equipo, PRODUCTO): un equipo dual-fuel produce
/// una serie de Diesel y otra de Gasolina por separado, y los lubricantes nunca
/// contaminan al combustible.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';

// ===========================================================================
// Muestras
// ===========================================================================

/// Un intervalo entre dos despachos consecutivos del mismo equipo y producto.
class BurnRateSample {
  const BurnRateSample({
    this.date,
    required this.equipmentId,
    required this.equipmentDescription,
    required this.category,
    required this.product,
    required this.litres,
    required this.smuDelta,
    required this.burnRate,
    required this.smuPrev,
    required this.smuCurr,
    this.smuType,
    this.fieldUser,
    this.sourceId,
  });

  final DateTime? date;
  final String equipmentId;
  final String equipmentDescription;
  final String category;
  final String product;

  /// Litros del despacho POSTERIOR (los que reponen lo quemado).
  final double litres;

  /// Avance del SMU en el intervalo.
  final double smuDelta;

  /// litros / smuDelta.
  final double burnRate;

  final double smuPrev;
  final double smuCurr;
  final String? smuType;
  final String? fieldUser;

  /// Id del despacho que cierra el intervalo (para poder ir al registro).
  final String? sourceId;

  /// Clave de encadenado: la serie NUNCA mezcla productos de un mismo equipo.
  String get seriesKey => '$equipmentId|$product';
}

// ===========================================================================
// Resultado por equipo, categoria e intervalo
// ===========================================================================

/// Burn rate tipico de un equipo y su comparacion con la categoria.
class EquipmentBurnRate {
  const EquipmentBurnRate({
    required this.equipmentId,
    required this.equipmentDescription,
    required this.category,
    required this.product,
    this.smuType,
    required this.samples,
    required this.burnRate,
    this.baseline,
    this.deviationPct,
    this.z,
    required this.direction,
    required this.totalLitres,
    required this.anomalous,
  });

  final String equipmentId;
  final String equipmentDescription;
  final String category;
  final String product;
  final String? smuType;

  /// Intervalos validos que respaldan el dato.
  final int samples;

  /// Mediana de los intervalos del equipo.
  final double burnRate;

  /// Linea base de su categoria. `null` = la categoria no tiene equipos
  /// suficientes para fijar una.
  final double? baseline;

  final double? deviationPct;

  /// z robusto respecto a la categoria. `null` si la categoria es degenerada
  /// (todos sus equipos casi identicos: sigma 0).
  final double? z;

  final Deviation direction;
  final double totalLitres;

  /// Confiable, con linea base, desviacion operativamente relevante Y
  /// estadisticamente significativa.
  final bool anomalous;

  /// Con muestras suficientes para que la mediana sea estable.
  bool get isReliable => samples >= burnRateMinSamples;
}

/// Linea base de una categoria y su dispersion.
class CategoryBaseline {
  const CategoryBaseline({
    required this.category,
    required this.baseline,
    required this.sigma,
    required this.equipmentCount,
    required this.min,
    required this.max,
  });

  final String category;

  /// Mediana de los burn rates de los equipos confiables de la categoria.
  final double baseline;

  /// MAD escalado. `0` = categoria degenerada.
  final double sigma;

  final int equipmentCount;
  final double min;
  final double max;
}

/// Fila del resumen por categoria (linea base + cuantos anomalos tiene).
class CategoryBurnRate {
  const CategoryBurnRate({
    required this.category,
    required this.equipmentCount,
    required this.samples,
    required this.baseline,
    required this.dispersion,
    required this.min,
    required this.max,
    required this.anomalous,
  });

  final String category;
  final int equipmentCount;
  final int samples;
  final double baseline;
  final double dispersion;
  final double min;
  final double max;
  final int anomalous;
}

/// Un despacho cuyo burn rate se aparta del historial del propio equipo.
class IntervalAnomaly {
  const IntervalAnomaly({
    required this.sample,
    required this.typicalBurnRate,
    this.deviationPct,
    this.z,
    required this.direction,
  });

  final BurnRateSample sample;

  /// Mediana del propio equipo y producto.
  final double typicalBurnRate;

  final double? deviationPct;
  final double? z;
  final Deviation direction;
}

/// Cobertura temporal REAL de las muestras dentro del rango elegido.
///
/// El burn rate solo se calcula con despachos que traen lectura de SMU. Si el
/// SMU dejo de registrarse durante parte del periodo, las muestras cubren solo
/// un tramo y la auditoria se ve identica entre rangos distintos — hay que
/// avisarlo, o el auditor concluye que "no cambio nada" cuando en realidad no
/// hay con que comparar.
class BurnRateCoverage {
  const BurnRateCoverage({
    this.first,
    this.last,
    required this.spanDays,
    required this.daysWithData,
    required this.rangeDays,
    required this.partial,
  });

  final DateTime? first;
  final DateTime? last;
  final int spanDays;
  final int daysWithData;
  final int rangeDays;

  /// El tramo con datos cubre menos del 80% del rango elegido.
  final bool partial;
}

class BurnRateKpis {
  const BurnRateKpis({
    required this.equipmentAnalysed,
    required this.anomalousEquipment,
    required this.intervals,
    required this.atypicalIntervals,
    required this.fleetBurnRate,
    required this.worstDeviationPct,
  });

  final int equipmentAnalysed;
  final int anomalousEquipment;
  final int intervals;
  final int atypicalIntervals;
  final double fleetBurnRate;
  final double worstDeviationPct;
}

// ===========================================================================
// Auditoria
// ===========================================================================

class BurnRateAudit {
  const BurnRateAudit._({
    required this.samplesAll,
    required this.samples,
    required this.equipment,
    required this.categories,
    required this.intervalAnomalies,
    required this.products,
    required this.kpis,
    this.product,
  });

  /// TODAS las muestras (todos los productos): permite re-proyectar a otro
  /// producto sin recomputar los intervalos ([forProduct]).
  final List<BurnRateSample> samplesAll;

  /// Muestras del producto seleccionado (todas si [product] es `null`).
  final List<BurnRateSample> samples;

  final List<EquipmentBurnRate> equipment;
  final List<CategoryBurnRate> categories;
  final List<IntervalAnomaly> intervalAnomalies;

  /// Productos disponibles, ordenados por litros totales descendente.
  final List<String> products;

  final BurnRateKpis kpis;

  /// Producto seleccionado (`null` = todos agregados).
  final String? product;

  List<EquipmentBurnRate> get equipmentAnomalies =>
      equipment.where((e) => e.anomalous).toList(growable: false);

  /// Calcula la auditoria completa en una sola pasada.
  static BurnRateAudit run({
    required List<Movement> movements,
    List<Equipment> equipment = const [],
    String? product,
  }) {
    final all = intervalSamples(movements: movements, equipment: equipment);
    return _project(all, _productsByVolume(all), product);
  }

  /// Re-proyecta a otro producto SIN recomputar las muestras (en memoria).
  BurnRateAudit forProduct(String? next) =>
      _project(samplesAll, products, next);

  static BurnRateAudit _project(
    List<BurnRateSample> all,
    List<String> products,
    String? product,
  ) {
    final samples = product == null
        ? all
        : all.where((s) => s.product == product).toList(growable: false);
    final stats = _equipmentStats(samples);
    final baselines = categoryBaselines(stats);
    final table = equipmentTable(stats, baselines);
    final intervals = intervalAnomaliesOf(samples);
    return BurnRateAudit._(
      samplesAll: all,
      samples: samples,
      equipment: table,
      categories: categoriesTable(table, baselines),
      intervalAnomalies: intervals,
      products: products,
      product: product,
      kpis: summaryKpis(table, samples, intervals),
    );
  }

  /// Serie temporal de UN equipo (para la grafica individual).
  List<BurnRateSample> equipmentSeries(String equipmentId, {String? product}) {
    final rows = samplesAll
        .where((s) =>
            s.equipmentId == equipmentId &&
            s.date != null &&
            (product == null || s.product == product))
        .toList()
      ..sort((a, b) => a.date!.compareTo(b.date!));
    return List.unmodifiable(rows);
  }

  /// Cobertura de las muestras dentro de [from]..[to].
  BurnRateCoverage coverage(DateTime from, DateTime to) {
    final rangeDays = _dayCount(from, to);
    final dates = samples
        .map((s) => s.date)
        .whereType<DateTime>()
        .map((d) => AnalyticsPeriod.daily.bucket(d))
        .toList()
      ..sort();
    if (dates.isEmpty) {
      // Sin muestras el rango es integramente ciego: `partial` arranca en true.
      return BurnRateCoverage(
        spanDays: 0,
        daysWithData: 0,
        rangeDays: rangeDays,
        partial: true,
      );
    }
    final span = _dayCount(dates.first, dates.last);
    return BurnRateCoverage(
      first: dates.first,
      last: dates.last,
      spanDays: span,
      daysWithData: dates.toSet().length,
      rangeDays: rangeDays,
      partial: span < rangeDays * 0.8,
    );
  }
}

int _dayCount(DateTime from, DateTime to) {
  final days = to.toUtc().difference(from.toUtc()).inDays + 1;
  return days < 1 ? 1 : days;
}

// ===========================================================================
// 1. Muestras por intervalo
// ===========================================================================

/// Un burn rate por cada par de despachos consecutivos del mismo equipo y
/// producto.
///
/// Descarta lo que no puede producir un cociente confiable: despachos sin
/// equipo real, sin volumen o sin lectura de SMU; intervalos con avance de SMU
/// insuficiente (division entre casi-cero) y burn rates no plausibles
/// (artefactos del dato, como un SMU de tanque que avanza 1 con miles de litros).
List<BurnRateSample> intervalSamples({
  required List<Movement> movements,
  List<Equipment> equipment = const [],
}) {
  final categoryById = <String, String>{};
  final descriptionById = <String, String>{};
  for (final e in equipment) {
    final id = realEquipmentId(e.equipmentId);
    if (id == null) continue;
    if (e.category != null) categoryById[id] = e.category!;
    if (e.description != null) descriptionById[id] = e.description!;
  }

  // Agrupa por (equipo, producto): encadenar sin separar producto daria el
  // cociente de litros de coolant sobre horas quemadas de diesel.
  final chains = <String, List<_Reading>>{};
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    final litres = m.volume;
    final smu = m.smuValue;
    if (id == null || litres == null || litres <= 0 || smu == null) continue;
    final product = asText(m.product) ?? noProductLabel;
    chains.putIfAbsent('$id|$product', () => <_Reading>[]).add(_Reading(
          movement: m,
          equipmentId: id,
          product: product,
          litres: litres,
          smu: smu,
          // El instante de recoleccion es el del hecho fisico; `updatedAt` es
          // cuando el FMS lo escribio, y puede reordenar despachos reales.
          date: m.recordCollectedAt ?? m.updatedAt,
        ));
  }

  final out = <BurnRateSample>[];
  for (final chain in chains.values) {
    chain.sort(_Reading.chronological);
    for (var i = 1; i < chain.length; i++) {
      final prev = chain[i - 1];
      final curr = chain[i];
      final delta = curr.smu - prev.smu;
      if (delta < burnRateMinSmuDelta) continue;
      final burn = curr.litres / delta;
      if (burn <= 0 || burn > burnRateMaxPlausible) continue;
      final id = curr.equipmentId;
      out.add(BurnRateSample(
        date: curr.date,
        equipmentId: id,
        equipmentDescription: asText(curr.movement.equipmentDescription) ??
            descriptionById[id] ??
            id,
        category: categoryById[id] ?? noDataLabel,
        product: curr.product,
        litres: roundTo(curr.litres),
        smuDelta: roundTo(delta, 2),
        burnRate: roundTo(burn, 2),
        smuPrev: roundTo(prev.smu),
        smuCurr: roundTo(curr.smu),
        smuType: curr.movement.smuType,
        fieldUser: curr.movement.fieldUser,
        sourceId: curr.movement.id,
      ));
    }
  }
  out.sort((a, b) => _compareDatesDesc(a.date, b.date));
  return List.unmodifiable(out);
}

class _Reading {
  const _Reading({
    required this.movement,
    required this.equipmentId,
    required this.product,
    required this.litres,
    required this.smu,
    this.date,
  });

  final Movement movement;
  final String equipmentId;
  final String product;
  final double litres;
  final double smu;
  final DateTime? date;

  /// Orden temporal; ante fechas iguales desempata por SMU, que es monotono.
  /// Los despachos sin fecha van al principio para no romper la cadena.
  static int chronological(_Reading a, _Reading b) {
    final ad = a.date;
    final bd = b.date;
    if (ad != null && bd != null) {
      final byDate = ad.compareTo(bd);
      if (byDate != 0) return byDate;
    } else if (ad == null && bd != null) {
      return -1;
    } else if (ad != null && bd == null) {
      return 1;
    }
    return a.smu.compareTo(b.smu);
  }
}

// ===========================================================================
// 2. Estadistica por equipo y linea base por categoria
// ===========================================================================

/// Resumen intermedio de UN equipo: su burn rate tipico y el respaldo que
/// tiene. Publico porque las lineas base y la tabla se calculan en pasos
/// separados, y un test puede fijar este paso intermedio.
class EquipmentStats {
  const EquipmentStats({
    required this.equipmentId,
    required this.description,
    required this.category,
    required this.product,
    this.smuType,
    required this.samples,
    required this.burnRate,
    required this.totalLitres,
  });

  final String equipmentId;
  final String description;
  final String category;
  final String product;
  final String? smuType;
  final int samples;
  final double burnRate;
  final double totalLitres;
}

List<EquipmentStats> _equipmentStats(List<BurnRateSample> samples) {
  final byEquipment = <String, List<BurnRateSample>>{};
  for (final s in samples) {
    byEquipment.putIfAbsent(s.equipmentId, () => <BurnRateSample>[]).add(s);
  }
  return byEquipment.entries.map((e) {
    final first = e.value.first;
    return EquipmentStats(
      equipmentId: e.key,
      description: first.equipmentDescription,
      category: first.category,
      product: first.product,
      smuType: first.smuType,
      samples: e.value.length,
      burnRate: median(e.value.map((s) => s.burnRate))!,
      totalLitres: roundTo(sumOf(e.value, (s) => s.litres)),
    );
  }).toList(growable: false);
}

/// Linea base por categoria, sobre los equipos CONFIABLES.
///
/// Una categoria con menos de [burnRateMinCategoryEquipment] equipos confiables
/// no produce linea base: comparar un equipo contra si mismo (o contra otro
/// solo) marcaria anomalias inventadas.
List<CategoryBaseline> categoryBaselines(List<EquipmentStats> stats) {
  final byCategory = <String, List<double>>{};
  for (final s in stats) {
    if (s.samples < burnRateMinSamples) continue;
    byCategory.putIfAbsent(s.category, () => <double>[]).add(s.burnRate);
  }
  final out = <CategoryBaseline>[];
  for (final entry in byCategory.entries) {
    final values = entry.value;
    if (values.length < burnRateMinCategoryEquipment) continue;
    final center = median(values)!;
    out.add(CategoryBaseline(
      category: entry.key,
      baseline: center,
      sigma: robustSigma(values, center: center),
      equipmentCount: values.length,
      min: values.reduce((a, b) => a < b ? a : b),
      max: values.reduce((a, b) => a > b ? a : b),
    ));
  }
  return List.unmodifiable(out);
}

/// Tabla por equipo con su burn rate, la linea base de su categoria y la marca
/// de anomalo. Incluye TODOS los equipos con al menos una muestra: la marca
/// solo se aplica a los confiables, pero el resto tambien se muestra para que
/// el auditor vea de quien aun no hay evidencia suficiente.
List<EquipmentBurnRate> equipmentTable(
  List<EquipmentStats> stats,
  List<CategoryBaseline> baselines,
) {
  final byCategory = {for (final b in baselines) b.category: b};
  final rows = stats.map((s) {
    final base = byCategory[s.category];
    final baseline = base?.baseline;
    final sigma = base?.sigma ?? 0;
    final delta = baseline == null ? null : s.burnRate - baseline;
    final devPct = (baseline == null || baseline == 0 || delta == null)
        ? null
        : roundTo(delta / baseline * 100, 1);
    final hasSigma = sigma > 0;
    final z = (delta == null || !hasSigma) ? null : roundTo(delta / sigma, 2);
    final reliable = s.samples >= burnRateMinSamples;

    // Significancia: |z| sobre el umbral. Si la categoria es degenerada
    // (sigma 0, todos sus equipos casi identicos) no hay z que calcular y basta
    // la desviacion relativa — de lo contrario esas categorias nunca marcarian.
    final significant =
        hasSigma ? (z != null && z.abs() >= burnRateZThreshold) : baseline != null;
    final relevant = devPct != null && devPct.abs() >= burnRateMinDeviationPct;

    return EquipmentBurnRate(
      equipmentId: s.equipmentId,
      equipmentDescription: s.description,
      category: s.category,
      product: s.product,
      smuType: s.smuType,
      samples: s.samples,
      burnRate: roundTo(s.burnRate, 2),
      baseline: baseline == null ? null : roundTo(baseline, 2),
      deviationPct: devPct,
      z: z,
      direction:
          (reliable && baseline != null) ? Deviation.of(delta) : Deviation.none,
      totalLitres: s.totalLitres,
      anomalous: reliable && baseline != null && relevant && significant,
    );
  }).toList()
    // Anomalos primero, luego por magnitud de la desviacion.
    ..sort((a, b) {
      if (a.anomalous != b.anomalous) return a.anomalous ? -1 : 1;
      return (b.deviationPct?.abs() ?? -1).compareTo(a.deviationPct?.abs() ?? -1);
    });
  return List.unmodifiable(rows);
}

/// Resumen por categoria. Solo las que tienen linea base confiable.
List<CategoryBurnRate> categoriesTable(
  List<EquipmentBurnRate> table,
  List<CategoryBaseline> baselines,
) {
  final rows = baselines.map((b) {
    final members = table.where((e) => e.category == b.category);
    return CategoryBurnRate(
      category: b.category,
      equipmentCount: b.equipmentCount,
      samples: members.fold<int>(0, (acc, e) => acc + e.samples),
      baseline: roundTo(b.baseline, 2),
      dispersion: roundTo(b.sigma, 2),
      min: roundTo(b.min, 2),
      max: roundTo(b.max, 2),
      anomalous: members.where((e) => e.anomalous).length,
    );
  }).toList()
    ..sort((a, b) => b.baseline.compareTo(a.baseline));
  return List.unmodifiable(rows);
}

// ===========================================================================
// 3. Intervalos atipicos
// ===========================================================================

/// Despachos cuyo burn rate se aparta del historial del PROPIO equipo.
///
/// La referencia es por (equipo, producto), no la categoria: aqui no interesa
/// si el equipo consume mas que sus pares, sino si HOY consumio distinto a como
/// consume el mismo.
List<IntervalAnomaly> intervalAnomaliesOf(List<BurnRateSample> samples) {
  final byKey = <String, List<BurnRateSample>>{};
  for (final s in samples) {
    byKey.putIfAbsent(s.seriesKey, () => <BurnRateSample>[]).add(s);
  }
  final out = <IntervalAnomaly>[];
  for (final chain in byKey.values) {
    if (chain.length < burnRateMinSamples) continue;
    final values = chain.map((s) => s.burnRate);
    final center = median(values)!;
    final sigma = robustSigma(values, center: center);
    if (sigma <= 0) continue; // serie plana: no hay dispersion contra la que medir
    for (final s in chain) {
      final delta = s.burnRate - center;
      final z = roundTo(delta / sigma, 2);
      final devPct = center == 0 ? null : roundTo(delta / center * 100, 1);
      if (z.abs() < burnRateIntervalZ) continue;
      if (devPct == null || devPct.abs() < burnRateMinDeviationPct) continue;
      out.add(IntervalAnomaly(
        sample: s,
        typicalBurnRate: roundTo(center, 2),
        deviationPct: devPct,
        z: z,
        direction: Deviation.of(delta),
      ));
    }
  }
  out.sort((a, b) => (b.z?.abs() ?? 0).compareTo(a.z?.abs() ?? 0));
  return List.unmodifiable(out);
}

// ===========================================================================
// 4. KPIs y utilidades
// ===========================================================================

BurnRateKpis summaryKpis(
  List<EquipmentBurnRate> table,
  List<BurnRateSample> samples,
  List<IntervalAnomaly> intervals,
) {
  final reliable = table.where((e) => e.isReliable).toList();
  final anomalies = table.where((e) => e.anomalous).toList();
  return BurnRateKpis(
    equipmentAnalysed: reliable.length,
    anomalousEquipment: anomalies.length,
    intervals: samples.length,
    atypicalIntervals: intervals.length,
    fleetBurnRate: reliable.isEmpty
        ? 0
        : roundTo(median(reliable.map((e) => e.burnRate))!, 2),
    worstDeviationPct: anomalies.isEmpty
        ? 0
        : anomalies
            .map((e) => (e.deviationPct ?? 0).abs())
            .reduce((a, b) => a > b ? a : b),
  );
}

/// Productos consumidos, ordenados por litros totales descendente.
List<String> _productsByVolume(List<BurnRateSample> samples) {
  final litresByProduct = <String, double>{};
  for (final s in samples) {
    if (s.product == noProductLabel) continue;
    litresByProduct[s.product] = (litresByProduct[s.product] ?? 0) + s.litres;
  }
  final products = litresByProduct.keys.toList()
    ..sort((a, b) => litresByProduct[b]!.compareTo(litresByProduct[a]!));
  return List.unmodifiable(products);
}

/// Ordena descendente dejando las fechas ausentes al final.
int _compareDatesDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}
