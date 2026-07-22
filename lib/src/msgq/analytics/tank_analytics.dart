/// Analitica de tanques y consumo — port de `msgq/core/tank_analytics.py`.
///
/// Reproduce las dos mitades del Tank Analyzer sobre los datos que la app ya
/// replica del endpoint:
///
///   * TRANSACCIONES: consumo por producto / tanque / cost centre / dimension
///     del equipo, burn rate por periodo, top consumidores y el flujo
///     inflow-vs-outflow por tanque y en el tiempo.
///   * STOCK MEDIDO: la reconciliacion diaria ('Detailed Reconciliation'), que
///     la API pre-calcula por tanque y dia.
///
/// Separacion por CIRCUITO (Diesel / Gasolina / Lubricantes): nunca se mezclan
/// productos. El producto viaja por-movimiento (en el maestro de equipos queda
/// vacio), asi que la clasificacion se hace siempre sobre [Movement.product].
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import '../domain/tank.dart';
import 'grouping.dart';

/// Servicio de analitica de tanques sobre un conjunto ya cargado de datos.
///
/// Se construye con las colecciones y expone los calculos como metodos: asi la
/// UI arma el servicio UNA vez por refresco y pide las vistas que necesite, sin
/// volver a recorrer la replica en cada una.
class TankAnalytics {
  const TankAnalytics({
    required this.movements,
    this.equipment = const [],
    this.reconciliations = const [],
    this.tanks = const [],
  });

  final List<Movement> movements;
  final List<Equipment> equipment;
  final List<Reconciliation> reconciliations;
  final List<Tank> tanks;

  // -- filtros -------------------------------------------------------------

  /// Vista restringida a un circuito. `null` = todos (sin filtrar).
  ///
  /// Filtra movimientos y reconciliaciones por el circuito de SU producto; el
  /// maestro de equipos y tanques se conserva intacto porque son catalogos, no
  /// transacciones.
  TankAnalytics filterCircuit(Circuit? circuit) {
    if (circuit == null) return this;
    return TankAnalytics(
      movements: movements.where((m) => m.circuit == circuit).toList(),
      equipment: equipment,
      reconciliations:
          reconciliations.where((r) => r.circuit == circuit).toList(),
      tanks: tanks,
    );
  }

  /// Vista restringida a un rango de fechas sobre [Movement.updatedAt] y
  /// [Reconciliation.periodEnd]. Ambos limites son inclusivos y opcionales.
  TankAnalytics filterDates({DateTime? start, DateTime? end}) {
    if (start == null && end == null) return this;
    bool inRange(DateTime? dt) {
      if (dt == null) return false;
      final utc = dt.toUtc();
      if (start != null && utc.isBefore(start.toUtc())) return false;
      if (end != null && utc.isAfter(end.toUtc())) return false;
      return true;
    }

    return TankAnalytics(
      movements: movements.where((m) => inRange(m.updatedAt)).toList(),
      equipment: equipment,
      reconciliations:
          reconciliations.where((r) => inRange(r.periodEnd)).toList(),
      tanks: tanks,
    );
  }

  List<Movement> get _dispenses =>
      movements.where((m) => m.isDispense).toList(growable: false);

  // =========================================================================
  // Consumo / despachos (solo movimientos DISPENSE)
  // =========================================================================

  List<VolumeGroup> consumptionByProduct() => groupVolume(
        _dispenses,
        keyOf: (m) => m.product,
        volumeOf: (m) => m.volume,
      );

  List<VolumeGroup> consumptionByTank() => groupVolume(
        _dispenses,
        keyOf: (m) => m.tank,
        volumeOf: (m) => m.volume,
      );

  List<VolumeGroup> consumptionByCostCentre() => groupVolume(
        _dispenses,
        keyOf: (m) => m.costCentre,
        volumeOf: (m) => m.volume,
      );

  /// Consumo agrupado por una dimension del EQUIPO (grupo / categoria /
  /// departamento / cost centre / marca).
  ///
  /// Requiere el maestro de equipos porque esas dimensiones NO viajan en el
  /// movimiento: se resuelven uniendo por `equipmentId`. Sin maestro cargado
  /// devuelve vacio en vez de imputarlo todo a `(sin dato)`, que se leeria como
  /// "la flota no tiene grupos" en lugar de "falta el inventario".
  List<VolumeGroup> consumptionByDimension(EquipmentDimension dimension) {
    if (equipment.isEmpty) return const [];
    final lut = _equipmentById();
    return groupVolume(
      _dispenses.where((m) => m.equipmentId != null),
      keyOf: (m) => lut[m.equipmentId!]?.dimension(dimension),
      volumeOf: (m) => m.volume,
    );
  }

  /// Equipos que mas combustible consumen, por volumen despachado.
  List<TopConsumer> topConsumers({int n = 25}) {
    final byEquipment = <String, List<Movement>>{};
    for (final m in _dispenses) {
      final id = m.equipmentId;
      if (id == null) continue;
      byEquipment.putIfAbsent(id, () => <Movement>[]).add(m);
    }
    final rows = byEquipment.entries
        .map((e) => TopConsumer(
              equipmentId: e.key,
              description: e.value
                  .map((m) => m.equipmentDescription)
                  .firstWhere((d) => d != null, orElse: () => null),
              dispenses: e.value.length,
              volumeL: roundTo(sumOf(e.value, (m) => m.volume)),
            ))
        .toList()
      ..sort((a, b) => b.volumeL.compareTo(a.volumeL));
    return takeTop(rows, n);
  }

  /// Volumen despachado por periodo (el consumo en el tiempo).
  List<BurnRatePoint> burnRate({
    AnalyticsPeriod period = AnalyticsPeriod.daily,
  }) {
    final buckets =
        bucketByPeriod(_dispenses, period, dateOf: (m) => m.updatedAt);
    return List.unmodifiable(buckets.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => BurnRatePoint(
              period: e.key,
              dispenses: e.value.length,
              volumeL: roundTo(sumOf(e.value, (m) => m.volume)),
            )));
  }

  // =========================================================================
  // Flujo (lado transacciones de la reconciliacion)
  // =========================================================================

  /// Por tanque: entregas (inflow), despachos y transferencias de salida.
  ///
  /// La replica conserva el tanque de ORIGEN de cada transaccion; el tanque
  /// DESTINO de una transferencia no se retiene, asi que las transferencias
  /// cuentan solo como salida del tanque origen (igual que en MSGQ). El neto,
  /// por tanto, subestima el saldo de un tanque que recibe transferencias.
  List<TankFlow> flowByTank() {
    final byTank = <String, List<Movement>>{};
    for (final m in movements) {
      byTank.putIfAbsent(categoryKey(m.tank), () => <Movement>[]).add(m);
    }
    double totalOf(List<Movement> rows, MovementKind kind) =>
        sumOf(rows.where((m) => m.kind == kind), (m) => m.volume);

    final flows = byTank.entries.map((e) {
      final deliveries = totalOf(e.value, MovementKind.delivery);
      final dispenses = totalOf(e.value, MovementKind.dispense);
      final transfers = totalOf(e.value, MovementKind.transfer);
      return TankFlow(
        tank: e.key,
        deliveriesL: roundTo(deliveries),
        dispensesL: roundTo(dispenses),
        transfersOutL: roundTo(transfers),
        netL: roundTo(deliveries - dispenses - transfers),
      );
    }).toList()
      ..sort((a, b) => b.dispensesL.compareTo(a.dispensesL));
    return List.unmodifiable(flows);
  }

  /// Inflow (entregas) vs outflow (despachos + transferencias) por periodo.
  List<FlowPoint> flowOverTime({
    AnalyticsPeriod period = AnalyticsPeriod.daily,
  }) {
    final buckets =
        bucketByPeriod(movements, period, dateOf: (m) => m.updatedAt);
    return List.unmodifiable(buckets.entries
        .map((e) {
          final inflow =
              sumOf(e.value.where((m) => m.isDelivery), (m) => m.volume);
          final outflow = sumOf(
              e.value.where((m) => m.isDispense || m.isTransfer),
              (m) => m.volume);
          return FlowPoint(
            period: e.key,
            inflowL: roundTo(inflow),
            outflowL: roundTo(outflow),
            netL: roundTo(inflow - outflow),
          );
        })
        // Un periodo con inflow y outflow nulos no aporta nada a la grafica.
        .where((p) => p.inflowL != 0 || p.outflowL != 0));
  }

  /// Resumen por circuito: despachos (n y volumen) y entregas.
  List<CircuitSummary> circuitSummary() {
    final byCircuit = <Circuit, List<Movement>>{};
    for (final m in movements) {
      final circuit = m.circuit;
      if (circuit == null) continue;
      byCircuit.putIfAbsent(circuit, () => <Movement>[]).add(m);
    }
    final rows = byCircuit.entries.map((e) {
      final dispenses = e.value.where((m) => m.isDispense).toList();
      final deliveries = e.value.where((m) => m.isDelivery);
      return CircuitSummary(
        circuit: e.key,
        dispenses: dispenses.length,
        dispensedVolumeL: roundTo(sumOf(dispenses, (m) => m.volume)),
        deliveredVolumeL: roundTo(sumOf(deliveries, (m) => m.volume)),
      );
    }).toList()
      ..sort((a, b) => b.dispensedVolumeL.compareTo(a.dispensedVolumeL));
    return List.unmodifiable(rows);
  }

  // =========================================================================
  // Reconciliacion (stock medido vs movimiento)
  // =========================================================================

  /// Reconciliacion agregada por tanque sobre el periodo cargado.
  ///
  /// El stock inicial es el de la PRIMERA fila del periodo y el final el de la
  /// ULTIMA (no se suman: son niveles, no flujos); inflow y outflow si se
  /// acumulan. Ordena por |error| descendente: lo mas descuadrado primero.
  List<ReconciliationSummary> reconciliationDetail() {
    final byTank = <String, List<Reconciliation>>{};
    for (final r in reconciliations) {
      if (r.periodEnd == null) continue;
      byTank.putIfAbsent(categoryKey(r.tank), () => <Reconciliation>[]).add(r);
    }
    final rows = byTank.entries.map((e) {
      final chunk = e.value
        ..sort((a, b) => a.periodEnd!.compareTo(b.periodEnd!));
      final opening = chunk.first.openingStock ?? 0;
      final closing = chunk.last.closingStock ?? 0;
      final inflow = sumOf(chunk, (r) => r.inflow);
      final outflow = sumOf(chunk, (r) => r.outflow);
      final stockChange = closing - opening;
      final movementChange = inflow - outflow;
      final error = stockChange - movementChange;
      return ReconciliationSummary(
        tank: e.key,
        product: chunk.first.product,
        openingStockL: roundTo(opening),
        closingStockL: roundTo(closing),
        stockChangeL: roundTo(stockChange),
        inflowL: roundTo(inflow),
        outflowL: roundTo(outflow),
        movementChangeL: roundTo(movementChange),
        errorL: roundTo(error),
        errorPctOfOutflow:
            outflow == 0 ? null : roundTo(error / outflow * 100, 2),
      );
    }).toList()
      ..sort((a, b) => b.errorL.abs().compareTo(a.errorL.abs()));
    return List.unmodifiable(rows);
  }

  /// Reconciliacion dia por dia y por tanque (las filas tal cual, con error %).
  List<Reconciliation> reconciliationDaily() {
    final rows = reconciliations.where((r) => r.periodEnd != null).toList()
      ..sort((a, b) {
        final byDate = b.periodEnd!.compareTo(a.periodEnd!);
        return byDate != 0
            ? byDate
            : categoryKey(a.tank).compareTo(categoryKey(b.tank));
      });
    return List.unmodifiable(rows);
  }

  /// Serie de stock final (closing) por dia y por tanque, para graficar el
  /// nivel en el tiempo. El valor de un dia es el ULTIMO cierre de ese dia.
  StockSeries stockSeries() {
    final byDay = <DateTime, Map<String, double>>{};
    final withClosing = reconciliations
        .where((r) => r.periodEnd != null && r.closingStock != null)
        .toList()
      ..sort((a, b) => a.periodEnd!.compareTo(b.periodEnd!));
    for (final r in withClosing) {
      final day = AnalyticsPeriod.daily.bucket(r.periodEnd!);
      // Al venir ordenado por fecha, la ultima escritura gana (= `aggfunc last`).
      byDay.putIfAbsent(day, () => <String, double>{})[categoryKey(r.tank)] =
          r.closingStock!;
    }
    final days = byDay.keys.toList()..sort();
    final tankCodes = byDay.values
        .expand((row) => row.keys)
        .toSet()
        .toList()
      ..sort();
    return StockSeries(
      periods: List.unmodifiable(days),
      seriesByTank: Map.unmodifiable({
        for (final code in tankCodes)
          code: List<double?>.unmodifiable(
              days.map((d) => byDay[d]?[code]).toList()),
      }),
    );
  }

  /// KPIs de reconciliacion: error total, % sobre outflow y peor tanque.
  /// `null` cuando no hay reconciliaciones en el periodo.
  ReconciliationKpis? reconciliationKpis() {
    final detail = reconciliationDetail();
    if (detail.isEmpty) return null;
    final totalError = sumOf(detail, (r) => r.errorL);
    final totalOutflow = sumOf(detail, (r) => r.outflowL);
    final worst = detail.first; // ya ordenado por |error| descendente
    return ReconciliationKpis(
      tanks: detail.length,
      totalErrorL: roundTo(totalError),
      errorPctOfOutflow:
          totalOutflow == 0 ? 0 : roundTo(totalError / totalOutflow * 100, 2),
      worstTank: worst.tank,
      worstErrorL: worst.errorL,
    );
  }

  Map<String, Equipment> _equipmentById() => {
        for (final e in equipment)
          if (e.equipmentId != null) e.equipmentId!: e,
      };
}

// ===========================================================================
// Filas de resultado
// ===========================================================================

/// Un equipo del ranking de consumo.
class TopConsumer {
  const TopConsumer({
    required this.equipmentId,
    this.description,
    required this.dispenses,
    required this.volumeL,
  });

  final String equipmentId;
  final String? description;
  final int dispenses;
  final double volumeL;
}

/// Consumo de un periodo (punto de la serie de burn rate).
class BurnRatePoint {
  const BurnRatePoint({
    required this.period,
    required this.dispenses,
    required this.volumeL,
  });

  final DateTime period;
  final int dispenses;
  final double volumeL;
}

/// Flujo acumulado de un tanque en el periodo cargado.
class TankFlow {
  const TankFlow({
    required this.tank,
    required this.deliveriesL,
    required this.dispensesL,
    required this.transfersOutL,
    required this.netL,
  });

  final String tank;
  final double deliveriesL;
  final double dispensesL;
  final double transfersOutL;

  /// Entregas - despachos - transferencias de salida.
  final double netL;
}

/// Inflow vs outflow de un periodo.
class FlowPoint {
  const FlowPoint({
    required this.period,
    required this.inflowL,
    required this.outflowL,
    required this.netL,
  });

  final DateTime period;
  final double inflowL;
  final double outflowL;
  final double netL;
}

/// Resumen de un circuito de producto.
class CircuitSummary {
  const CircuitSummary({
    required this.circuit,
    required this.dispenses,
    required this.dispensedVolumeL,
    required this.deliveredVolumeL,
  });

  final Circuit circuit;
  final int dispenses;
  final double dispensedVolumeL;
  final double deliveredVolumeL;
}

/// Reconciliacion agregada de UN tanque sobre el periodo.
class ReconciliationSummary {
  const ReconciliationSummary({
    required this.tank,
    this.product,
    required this.openingStockL,
    required this.closingStockL,
    required this.stockChangeL,
    required this.inflowL,
    required this.outflowL,
    required this.movementChangeL,
    required this.errorL,
    this.errorPctOfOutflow,
  });

  final String tank;
  final String? product;
  final double openingStockL;
  final double closingStockL;

  /// closing - opening (lo que dice el SENSOR que cambio el nivel).
  final double stockChangeL;

  final double inflowL;
  final double outflowL;

  /// inflow - outflow (lo que dicen las TRANSACCIONES que cambio el nivel).
  final double movementChangeL;

  /// Descuadre entre ambas mitades: litros sin explicacion.
  final double errorL;

  /// `null` cuando no hubo outflow (el porcentaje seria infinito).
  final double? errorPctOfOutflow;
}

/// Serie de nivel de stock por dia, una lista de valores por tanque.
///
/// Un `null` en la serie es un dia SIN medicion de ese tanque; hay que dejar el
/// hueco en la grafica en vez de interpolarlo, porque un tanque sin lectura no
/// es un tanque cuyo nivel no cambio.
class StockSeries {
  const StockSeries({required this.periods, required this.seriesByTank});

  final List<DateTime> periods;
  final Map<String, List<double?>> seriesByTank;

  bool get isEmpty => periods.isEmpty;
}

/// Indicadores de cabecera de la reconciliacion.
class ReconciliationKpis {
  const ReconciliationKpis({
    required this.tanks,
    required this.totalErrorL,
    required this.errorPctOfOutflow,
    required this.worstTank,
    required this.worstErrorL,
  });

  final int tanks;
  final double totalErrorL;
  final double errorPctOfOutflow;
  final String worstTank;
  final double worstErrorL;
}
