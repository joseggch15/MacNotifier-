/// Primitivas de agregacion compartidas por la analitica portada de MSGQ.
///
/// En Python esas agregaciones las resuelve pandas (`groupby().agg()`,
/// `pd.Grouper(freq=...)`, `.round(1)`). Aqui se reconstruyen con las
/// operaciones funcionales de Dart (`fold`, `map`, `where`) sobre listas
/// tipadas, conservando DOS decisiones de MSGQ que no son cosmeticas:
///
///   * Las claves vacias se agrupan bajo `(sin dato)` en vez de descartarse: un
///     grupo sin nombre sigue consumiendo combustible y debe verse.
///   * Los volumenes se redondean a 1 decimal al AGREGAR, no al mostrar, para
///     que la app y los exports de escritorio den exactamente la misma cifra.
///
/// Dart puro: sin dependencias de UI, testeable sin emulador.
library;

import '../domain/fms_vocabulary.dart';
import '../domain/node_parsing.dart';

/// Datos de entrada invalidos para un calculo (p. ej. un `topN` no positivo).
///
/// Se prefiere fallar ruidosamente a devolver una lista vacia: una tabla vacia
/// se confunde con "no hay consumo", que es justo la conclusion contraria.
class AnalyticsException implements Exception {
  const AnalyticsException(this.message);

  final String message;

  @override
  String toString() => 'AnalyticsException: $message';
}

/// Granularidad temporal de las series (equivalente al `freq` de pandas).
enum AnalyticsPeriod {
  daily('D', 'Diario'),
  weekly('W', 'Semanal'),
  monthly('ME', 'Mensual');

  const AnalyticsPeriod(this.freq, this.label);

  /// Codigo `freq` equivalente en MSGQ, para poder rastrear la equivalencia.
  final String freq;
  final String label;

  /// Inicio del periodo al que pertenece [dt] (en UTC, sin hora).
  ///
  /// Es el equivalente de `pd.Grouper`: todos los instantes del mismo dia /
  /// semana / mes colapsan al mismo instante representante.
  DateTime bucket(DateTime dt) {
    final utc = dt.toUtc();
    return switch (this) {
      AnalyticsPeriod.daily => DateTime.utc(utc.year, utc.month, utc.day),
      // Semana ISO: lunes como primer dia (weekday 1..7).
      AnalyticsPeriod.weekly => DateTime.utc(utc.year, utc.month, utc.day)
          .subtract(Duration(days: utc.weekday - 1)),
      AnalyticsPeriod.monthly => DateTime.utc(utc.year, utc.month),
    };
  }
}

/// Un grupo con su conteo y su volumen acumulado. Es la fila que devuelven
/// todos los "consumo por X" (`_group_volume` de MSGQ).
class VolumeGroup {
  const VolumeGroup({
    required this.key,
    required this.count,
    required this.volumeL,
  });

  /// Etiqueta del grupo (nunca vacia: `(sin dato)` cuando falta).
  final String key;

  /// Cantidad de movimientos del grupo.
  final int count;

  /// Volumen total en litros, redondeado a 1 decimal.
  final double volumeL;

  Map<String, dynamic> toJson() => {
        'key': key,
        'count': count,
        'volume_l': volumeL,
      };

  @override
  String toString() => 'VolumeGroup($key, n=$count, $volumeL L)';
}

/// Agrupa [items] por la clave que devuelve [keyOf] y suma [volumeOf].
///
/// Las filas cuya clave es nula o vacia caen en `(sin dato)`. El resultado
/// viene ordenado por volumen descendente, como todas las tablas de MSGQ.
List<VolumeGroup> groupVolume<T>(
  Iterable<T> items, {
  required String? Function(T) keyOf,
  required double? Function(T) volumeOf,
}) {
  final counts = <String, int>{};
  final volumes = <String, double>{};
  for (final item in items) {
    final key = categoryKey(keyOf(item));
    counts[key] = (counts[key] ?? 0) + 1;
    volumes[key] = (volumes[key] ?? 0) + (volumeOf(item) ?? 0);
  }
  final groups = counts.keys
      .map((key) => VolumeGroup(
            key: key,
            count: counts[key]!,
            volumeL: roundTo(volumes[key]!),
          ))
      .toList();
  groups.sort((a, b) => b.volumeL.compareTo(a.volumeL));
  return List.unmodifiable(groups);
}

/// Agrupa [items] en cubetas temporales de [period] segun [dateOf].
///
/// Los elementos sin fecha se descartan (no se pueden ubicar en el tiempo).
/// Devuelve las cubetas ordenadas cronologicamente; las vacias no existen,
/// igual que en MSGQ, donde se filtran los periodos sin movimientos.
Map<DateTime, List<T>> bucketByPeriod<T>(
  Iterable<T> items,
  AnalyticsPeriod period, {
  required DateTime? Function(T) dateOf,
}) {
  final buckets = <DateTime, List<T>>{};
  for (final item in items) {
    final date = dateOf(item);
    if (date == null) continue;
    buckets.putIfAbsent(period.bucket(date), () => <T>[]).add(item);
  }
  final ordered = buckets.keys.toList()..sort();
  return Map.unmodifiable({for (final k in ordered) k: buckets[k]!});
}

/// Suma funcional de una proyeccion numerica, tratando `null` como 0.
double sumOf<T>(Iterable<T> items, double? Function(T) valueOf) =>
    items.fold<double>(0, (acc, item) => acc + (valueOf(item) ?? 0));

/// Recorta a los primeros [n] elementos. Lanza si [n] no es positivo: pedir
/// "los 0 mayores consumidores" siempre es un error del llamador.
List<T> takeTop<T>(List<T> items, int n) {
  if (n <= 0) {
    throw AnalyticsException('El tope de filas debe ser positivo (recibido: $n).');
  }
  return List.unmodifiable(items.take(n));
}

// ===========================================================================
// Estadistica robusta
// ===========================================================================
// Las auditorias de burn rate y de hardware resumen SIEMPRE con mediana y MAD,
// nunca con media y desviacion tipica. La razon no es estilistica: la media y la
// sigma clasica las arrastra el propio outlier que se quiere detectar, asi que
// un equipo con una fuga elevaria la linea base de su categoria hasta dejar de
// parecer anomalo. La mediana no se mueve.

/// Mediana de una muestra. `null` si esta vacia.
double? median(Iterable<double> values) {
  final sorted = values.where((v) => v.isFinite).toList()..sort();
  if (sorted.isEmpty) return null;
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Desviacion absoluta mediana: la mediana de |x - mediana(x)|.
double? medianAbsoluteDeviation(Iterable<double> values, {double? center}) {
  final list = values.where((v) => v.isFinite).toList();
  if (list.isEmpty) return null;
  final c = center ?? median(list)!;
  return median(list.map((v) => (v - c).abs()));
}

/// Sigma robusto = MAD escalado. `0` cuando la muestra es degenerada (todos los
/// valores identicos); el llamador debe tratar ese caso aparte, porque dividir
/// por el daria un z infinito.
double robustSigma(Iterable<double> values, {double? center}) {
  final mad = medianAbsoluteDeviation(values, center: center);
  return mad == null ? 0 : madToSigma * mad;
}

/// Direccion de una desviacion respecto a su referencia.
enum Deviation {
  high('Alto'),
  low('Bajo'),
  none('');

  const Deviation(this.label);

  final String label;

  /// 'Alto' si supera la referencia, 'Bajo' si queda por debajo, ninguna si no
  /// hay con que comparar.
  static Deviation of(double? delta) {
    if (delta == null || !delta.isFinite || delta == 0) return Deviation.none;
    return delta > 0 ? Deviation.high : Deviation.low;
  }
}
