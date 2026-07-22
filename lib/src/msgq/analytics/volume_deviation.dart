/// Auditoria de Desviacion de Volumen en Entregas (medidor vs guia) — port de
/// `msgq/core/volume_deviation.py`.
///
/// En cada entrega el FMS guarda DOS volumenes: el MEDIDO (`volume`, del medidor
/// digital de la linea o del gauge del tanque) y el DIGITADO en campo desde la
/// guia del camion (`secondaryVolume`). Una diferencia sostenida significa que
/// el proveedor factura litros que nunca entraron al tanque, o que el medidor
/// esta descalibrado.
///
/// El SIGNO es la mitad del hallazgo: positivo = la guia reclama MAS de lo
/// medido (sobre-facturacion, el caso de fraude); negativo = la guia reclama
/// menos (sub-registro o medidor leyendo de mas). Reportar solo la magnitud
/// borraria justamente la distincion que decide a quien se reclama.
///
/// Relacion con el notificador: `delivery_check.dart` ya detecta esta misma
/// varianza para NOTIFICAR una entrega concreta. Esto es la vista de auditoria
/// —el acumulado por tanque, el saldo neto, el ranking— que responde "cuanto
/// nos han cobrado de mas este trimestre".
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import 'grouping.dart';

/// Hacia donde va la diferencia.
enum DeviationDirection {
  overbilled('Guia sobre lo medido'),
  underbilled('Guia bajo lo medido'),
  none('Sin diferencia');

  const DeviationDirection(this.label);

  final String label;
}

/// Desviacion relativa minima (%) para marcar una entrega.
const double deliveryVolumeDeviationPct = 1.0;

/// Desviacion a partir de la cual escala a critica: ya no es ruido de medicion,
/// hay una discrepancia grande de volumen y de dinero con el proveedor.
const double deliveryVolumeDeviationCriticalPct = 5.0;

/// Entregas por debajo de este volumen se ignoran: una guia de pocos litros con
/// una diferencia absoluta minima dispara un porcentaje enorme sin relevancia.
const double deliveryMinVolumeL = 100.0;

/// Una entrega con sus dos volumenes y la diferencia entre ambos.
class VolumeDeviation {
  const VolumeDeviation({
    this.date,
    this.tank,
    this.product,
    this.transactionType,
    required this.measuredVolume,
    required this.fieldVolume,
    required this.deviationL,
    required this.deviationPct,
    required this.direction,
    this.measuredSource,
    this.fieldSource,
    this.sourceId,
    required this.flagged,
  });

  final DateTime? date;
  final String? tank;
  final String? product;
  final String? transactionType;

  /// Volumen del medidor o del gauge: la referencia fisica.
  final double measuredVolume;

  /// Volumen digitado desde la guia del camion.
  final double fieldVolume;

  /// guia - medido. Positivo = el proveedor cobra de mas.
  final double deviationL;

  final double deviationPct;
  final DeviationDirection direction;

  /// De donde sale cada volumen (`METER`, `DOCKET`...). Importa para juzgar:
  /// una diferencia entre gauge y guia es mas esperable que entre medidor y guia.
  final String? measuredSource;
  final String? fieldSource;

  final String? sourceId;

  /// Supera el umbral y el volumen minimo.
  final bool flagged;

  bool get isCritical =>
      flagged && deviationPct.abs() >= deliveryVolumeDeviationCriticalPct;
}

/// Acumulado por tanque de destino.
class TankDeviationSummary {
  const TankDeviationSummary({
    required this.tank,
    required this.deliveries,
    required this.flagged,
    required this.measuredL,
    required this.fieldL,
    required this.netOverbilledL,
    required this.worstDeviationPct,
  });

  final String tank;
  final int deliveries;
  final int flagged;
  final double measuredL;
  final double fieldL;

  /// Saldo: litros reclamados de mas menos los reclamados de menos. Es la cifra
  /// que se lleva a una reclamacion, no la suma de magnitudes.
  final double netOverbilledL;

  final double worstDeviationPct;
}

class VolumeDeviationKpis {
  const VolumeDeviationKpis({
    required this.analysed,
    required this.flagged,
    required this.worstDeviationPct,
    required this.disputedL,
    required this.netOverbilledL,
  });

  final int analysed;
  final int flagged;
  final double worstDeviationPct;

  /// Suma de MAGNITUDES de las marcadas: cuanto volumen esta en discusion.
  final double disputedL;

  /// Saldo con signo de las marcadas.
  final double netOverbilledL;
}

class VolumeDeviationAudit {
  const VolumeDeviationAudit._({
    required this.deviations,
    required this.byTank,
    required this.kpis,
  });

  final List<VolumeDeviation> deviations;
  final List<TankDeviationSummary> byTank;
  final VolumeDeviationKpis kpis;

  List<VolumeDeviation> get flaggedDeliveries =>
      deviations.where((d) => d.flagged).toList(growable: false);

  static VolumeDeviationAudit run({required List<Movement> movements}) {
    final rows = deviationsOf(movements);
    final flagged = rows.where((d) => d.flagged).toList();
    return VolumeDeviationAudit._(
      deviations: rows,
      byTank: byTankOf(rows),
      kpis: VolumeDeviationKpis(
        analysed: rows.length,
        flagged: flagged.length,
        worstDeviationPct: rows.isEmpty
            ? 0
            : rows
                .map((d) => d.deviationPct.abs())
                .reduce((a, b) => a > b ? a : b),
        disputedL: roundTo(sumOf(flagged, (d) => d.deviationL.abs())),
        netOverbilledL: roundTo(sumOf(flagged, (d) => d.deviationL)),
      ),
    );
  }
}

/// Una fila por entrega que trae AMBOS volumenes.
///
/// Se descartan las que no traen los dos —sin comparacion no hay hallazgo— y
/// las de volumen minimo, donde un porcentaje grande no significa nada.
List<VolumeDeviation> deviationsOf(List<Movement> movements) {
  final out = <VolumeDeviation>[];
  for (final m in movements) {
    if (!m.isDelivery) continue;
    final measured = m.volume;
    final field = m.secondaryVolume;
    if (measured == null || field == null || measured <= 0 || field <= 0) {
      continue;
    }
    final deviationL = field - measured;
    final deviationPct = deviationL / measured * 100.0;
    out.add(VolumeDeviation(
      date: m.recordCollectedAt ?? m.updatedAt,
      tank: asText(m.tank),
      product: asText(m.product),
      transactionType: asText(m.type),
      measuredVolume: roundTo(measured),
      fieldVolume: roundTo(field),
      deviationL: roundTo(deviationL),
      deviationPct: roundTo(deviationPct, 2),
      direction: deviationL > 0
          ? DeviationDirection.overbilled
          : deviationL < 0
              ? DeviationDirection.underbilled
              : DeviationDirection.none,
      measuredSource: asText(m.primaryVolumeSource),
      fieldSource: asText(m.secondaryVolumeSource),
      sourceId: m.id,
      flagged: measured >= deliveryMinVolumeL &&
          deviationPct.abs() >= deliveryVolumeDeviationPct,
    ));
  }
  // Marcadas primero, luego por magnitud de la desviacion.
  out.sort((a, b) {
    if (a.flagged != b.flagged) return a.flagged ? -1 : 1;
    return b.deviationPct.abs().compareTo(a.deviationPct.abs());
  });
  return List.unmodifiable(out);
}

/// Resumen por tanque de destino.
List<TankDeviationSummary> byTankOf(List<VolumeDeviation> deviations) {
  final byTank = <String, List<VolumeDeviation>>{};
  for (final d in deviations) {
    byTank.putIfAbsent(categoryKey(d.tank), () => <VolumeDeviation>[]).add(d);
  }
  final out = byTank.entries.map((e) {
    return TankDeviationSummary(
      tank: e.key,
      deliveries: e.value.length,
      flagged: e.value.where((d) => d.flagged).length,
      measuredL: roundTo(sumOf(e.value, (d) => d.measuredVolume)),
      fieldL: roundTo(sumOf(e.value, (d) => d.fieldVolume)),
      netOverbilledL: roundTo(sumOf(e.value, (d) => d.deviationL)),
      worstDeviationPct: e.value
          .map((d) => d.deviationPct.abs())
          .reduce((a, b) => a > b ? a : b),
    );
  }).toList()
    ..sort((a, b) => b.worstDeviationPct.compareTo(a.worstDeviationPct));
  return List.unmodifiable(out);
}

/// Serie temporal del saldo de sobre-facturacion.
List<VolumeDeviationPoint> deviationOverTime(
  List<VolumeDeviation> deviations, {
  AnalyticsPeriod period = AnalyticsPeriod.daily,
}) {
  final buckets = bucketByPeriod(deviations, period, dateOf: (d) => d.date);
  return List.unmodifiable(buckets.entries.map((e) => VolumeDeviationPoint(
        period: e.key,
        deliveries: e.value.length,
        flagged: e.value.where((d) => d.flagged).length,
        netOverbilledL: roundTo(sumOf(e.value, (d) => d.deviationL)),
      )));
}

class VolumeDeviationPoint {
  const VolumeDeviationPoint({
    required this.period,
    required this.deliveries,
    required this.flagged,
    required this.netOverbilledL,
  });

  final DateTime period;
  final int deliveries;
  final int flagged;
  final double netOverbilledL;
}

/// Categoria canonica de la alerta.
const String alertVolumeDeviation =
    'Desviacion de volumen en entrega (medidor vs guia)';

/// Etiqueta del circuito de una entrega, para agrupar el reporte.
Circuit? deviationCircuit(VolumeDeviation deviation) =>
    classifyCircuit(deviation.product);
