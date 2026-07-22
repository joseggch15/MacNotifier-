import 'package:adapt_mac_notifier/src/msgq/analytics/grouping.dart';
import 'package:adapt_mac_notifier/src/msgq/analytics/tank_analytics.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/tank.dart';
import 'package:flutter_test/flutter_test.dart';

Movement mv(
  String id, {
  MovementKind kind = MovementKind.dispense,
  double? volume,
  String? product,
  String? tank,
  String? equipmentId,
  String? equipmentDescription,
  String? costCentre,
  DateTime? updatedAt,
}) =>
    Movement(
      id: id,
      kind: kind,
      volume: volume,
      product: product,
      tank: tank,
      equipmentId: equipmentId,
      equipmentDescription: equipmentDescription,
      costCentre: costCentre,
      updatedAt: updatedAt ?? DateTime.utc(2026, 7, 1, 8),
    );

Reconciliation rec(
  String id, {
  required String tank,
  required DateTime periodEnd,
  double? opening,
  double? closing,
  double? inflow,
  double? outflow,
  String? product,
}) =>
    Reconciliation(
      id: id,
      tank: tank,
      periodEnd: periodEnd,
      openingStock: opening,
      closingStock: closing,
      inflow: inflow,
      outflow: outflow,
      product: product,
    );

void main() {
  group('clasificacion de circuito', () {
    test('reconoce diesel, gasolina y manda el resto a lubricantes', () {
      expect(classifyCircuit('Diesel LFO'), Circuit.diesel);
      expect(classifyCircuit('UNLEADED 95'), Circuit.gasolina);
      expect(classifyCircuit('Hydraulic Oil 68'), Circuit.lubricantes);
      expect(classifyCircuit('   '), isNull);
      expect(classifyCircuit(null), isNull);
    });

    test('filterCircuit deja fuera los movimientos de otro circuito', () {
      final analytics = TankAnalytics(movements: [
        mv('a', volume: 100, product: 'Diesel'),
        mv('b', volume: 50, product: 'Coolant'),
      ]);
      final diesel = analytics.filterCircuit(Circuit.diesel);
      expect(diesel.movements, hasLength(1));
      expect(diesel.movements.single.id, 'a');
    });
  });

  group('consumo', () {
    final analytics = TankAnalytics(
      movements: [
        mv('a', volume: 100, product: 'Diesel', tank: 'T1', costCentre: 'CC1'),
        mv('b', volume: 250.44, product: 'Diesel', tank: 'T2'),
        mv('c', volume: 30, product: 'Coolant', tank: 'T1'),
        // Las entregas NO son consumo: solo cuentan los despachos.
        mv('d',
            kind: MovementKind.delivery,
            volume: 9000,
            product: 'Diesel',
            tank: 'T1'),
      ],
    );

    test('agrupa por producto ordenando por volumen y redondea a 1 decimal', () {
      final rows = analytics.consumptionByProduct();
      expect(rows.map((r) => r.key), ['Diesel', 'Coolant']);
      expect(rows.first.volumeL, 350.4);
      expect(rows.first.count, 2);
    });

    test('el cost centre ausente cae en (sin dato), no se descarta', () {
      final rows = analytics.consumptionByCostCentre();
      expect(rows.map((r) => r.key), containsAll(['CC1', noDataLabel]));
      expect(rows.fold<int>(0, (a, r) => a + r.count), 3);
    });

    test('agrupa por tanque sumando productos distintos', () {
      final rows = analytics.consumptionByTank();
      final t1 = rows.firstWhere((r) => r.key == 'T1');
      expect(t1.volumeL, 130.0);
    });
  });

  group('consumo por dimension del equipo', () {
    test('une los despachos al maestro por equipment id', () {
      final analytics = TankAnalytics(
        movements: [
          mv('a', volume: 100, equipmentId: 'EX01'),
          mv('b', volume: 60, equipmentId: 'LV02'),
          mv('c', volume: 40, equipmentId: 'EX01'),
        ],
        equipment: const [
          Equipment(equipmentId: 'EX01', group: 'Excavadoras'),
          Equipment(equipmentId: 'LV02', group: 'Livianos'),
        ],
      );
      final rows = analytics.consumptionByDimension(EquipmentDimension.group);
      expect(rows.first.key, 'Excavadoras');
      expect(rows.first.volumeL, 140.0);
    });

    test('sin maestro devuelve vacio en vez de imputar todo a (sin dato)', () {
      final analytics =
          TankAnalytics(movements: [mv('a', volume: 100, equipmentId: 'EX01')]);
      expect(analytics.consumptionByDimension(EquipmentDimension.group),
          isEmpty);
    });
  });

  group('series temporales', () {
    final analytics = TankAnalytics(movements: [
      mv('a', volume: 10, updatedAt: DateTime.utc(2026, 7, 1, 6)),
      mv('b', volume: 20, updatedAt: DateTime.utc(2026, 7, 1, 23)),
      mv('c', volume: 5, updatedAt: DateTime.utc(2026, 7, 3, 12)),
    ]);

    test('el burn rate diario colapsa el mismo dia en una cubeta', () {
      final series = analytics.burnRate(period: AnalyticsPeriod.daily);
      expect(series, hasLength(2));
      expect(series.first.period, DateTime.utc(2026, 7, 1));
      expect(series.first.volumeL, 30.0);
      expect(series.first.dispenses, 2);
    });

    test('el periodo mensual agrupa todo el mes', () {
      final series = analytics.burnRate(period: AnalyticsPeriod.monthly);
      expect(series, hasLength(1));
      expect(series.single.volumeL, 35.0);
    });

    test('un movimiento sin updatedAt no entra en ninguna cubeta', () {
      final withoutDate = TankAnalytics(movements: [
        Movement(id: 'x', kind: MovementKind.dispense, volume: 99),
      ]);
      expect(withoutDate.burnRate(), isEmpty);
    });
  });

  group('flujo por tanque', () {
    test('las transferencias restan del tanque origen', () {
      final analytics = TankAnalytics(movements: [
        mv('in', kind: MovementKind.delivery, volume: 1000, tank: 'T1'),
        mv('out', volume: 300, tank: 'T1'),
        mv('tr', kind: MovementKind.transfer, volume: 200, tank: 'T1'),
      ]);
      final flow = analytics.flowByTank().single;
      expect(flow.deliveriesL, 1000.0);
      expect(flow.dispensesL, 300.0);
      expect(flow.transfersOutL, 200.0);
      expect(flow.netL, 500.0);
    });

    test('flowOverTime omite los periodos totalmente vacios', () {
      final analytics = TankAnalytics(movements: [
        mv('a', volume: 0, updatedAt: DateTime.utc(2026, 7, 1)),
        mv('b', volume: 100, updatedAt: DateTime.utc(2026, 7, 2)),
      ]);
      final series = analytics.flowOverTime();
      expect(series, hasLength(1));
      expect(series.single.outflowL, 100.0);
      expect(series.single.netL, -100.0);
    });
  });

  group('reconciliacion', () {
    final analytics = TankAnalytics(
      movements: const [],
      reconciliations: [
        rec('r1',
            tank: 'T1',
            periodEnd: DateTime.utc(2026, 7, 1),
            opening: 10000,
            closing: 9000,
            inflow: 0,
            outflow: 900,
            product: 'Diesel'),
        rec('r2',
            tank: 'T1',
            periodEnd: DateTime.utc(2026, 7, 2),
            opening: 9000,
            closing: 8500,
            inflow: 0,
            outflow: 500,
            product: 'Diesel'),
      ],
    );

    test('toma opening del primer dia y closing del ultimo, no los suma', () {
      final row = analytics.reconciliationDetail().single;
      expect(row.openingStockL, 10000.0);
      expect(row.closingStockL, 8500.0);
      expect(row.inflowL, 0.0);
      expect(row.outflowL, 1400.0);
      // Stock cayo 1500 pero solo se registraron 1400 de salida: faltan 100 L.
      expect(row.stockChangeL, -1500.0);
      expect(row.movementChangeL, -1400.0);
      expect(row.errorL, -100.0);
      expect(row.errorPctOfOutflow, closeTo(-7.14, 0.01));
    });

    test('los KPIs sacan el peor tanque por magnitud del error', () {
      final kpis = analytics.reconciliationKpis()!;
      expect(kpis.tanks, 1);
      expect(kpis.totalErrorL, -100.0);
      expect(kpis.worstTank, 'T1');
    });

    test('sin outflow el porcentaje es null y no infinito', () {
      final sinSalidas = TankAnalytics(movements: const [], reconciliations: [
        rec('r',
            tank: 'T9',
            periodEnd: DateTime.utc(2026, 7, 1),
            opening: 100,
            closing: 90,
            inflow: 0,
            outflow: 0),
      ]);
      expect(sinSalidas.reconciliationDetail().single.errorPctOfOutflow, isNull);
    });

    test('la serie de stock deja hueco el dia sin medicion de un tanque', () {
      final mixto = TankAnalytics(movements: const [], reconciliations: [
        rec('a', tank: 'T1', periodEnd: DateTime.utc(2026, 7, 1), closing: 100),
        rec('b', tank: 'T2', periodEnd: DateTime.utc(2026, 7, 2), closing: 200),
      ]);
      final series = mixto.stockSeries();
      expect(series.periods, hasLength(2));
      expect(series.seriesByTank['T1'], [100.0, null]);
      expect(series.seriesByTank['T2'], [null, 200.0]);
    });

    test('sin reconciliaciones los KPIs son null, no ceros', () {
      expect(const TankAnalytics(movements: []).reconciliationKpis(), isNull);
    });
  });

  group('validacion de entradas', () {
    test('un tope no positivo lanza AnalyticsException', () {
      final analytics =
          TankAnalytics(movements: [mv('a', volume: 1, equipmentId: 'E1')]);
      expect(() => analytics.topConsumers(n: 0),
          throwsA(isA<AnalyticsException>()));
    });
  });

  group('resumen por circuito', () {
    test('separa combustible de lubricantes y suma entregas aparte', () {
      final analytics = TankAnalytics(movements: [
        mv('a', volume: 500, product: 'Diesel'),
        mv('b', kind: MovementKind.delivery, volume: 20000, product: 'Diesel'),
        mv('c', volume: 40, product: 'Hydraulic Oil'),
      ]);
      final rows = analytics.circuitSummary();
      final diesel = rows.firstWhere((r) => r.circuit == Circuit.diesel);
      expect(diesel.dispenses, 1);
      expect(diesel.dispensedVolumeL, 500.0);
      expect(diesel.deliveredVolumeL, 20000.0);
      expect(rows.any((r) => r.circuit == Circuit.lubricantes), isTrue);
    });
  });
}
