import 'package:adapt_mac_notifier/src/msgq/analytics/burn_rate.dart';
import 'package:adapt_mac_notifier/src/msgq/analytics/grouping.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

/// Despacho con lectura de SMU: el insumo del burn rate.
Movement disp(
  String id, {
  required String equipmentId,
  required double litres,
  required double smu,
  String product = 'Diesel',
  DateTime? at,
}) =>
    Movement(
      id: id,
      kind: MovementKind.dispense,
      equipmentId: equipmentId,
      volume: litres,
      smuValue: smu,
      product: product,
      recordCollectedAt: at ?? DateTime.utc(2026, 7, 1),
    );

/// Cadena de despachos de un equipo: litros constantes cada `smuStep` de SMU
/// produce un burn rate estable de litres/smuStep.
List<Movement> chain(
  String equipmentId, {
  required int count,
  required double litres,
  required double smuStep,
  String product = 'Diesel',
  double smuStart = 100,
  DateTime? from,
}) {
  final start = from ?? DateTime.utc(2026, 6, 1);
  return List.generate(
    count,
    (i) => disp(
      '$equipmentId-$i',
      equipmentId: equipmentId,
      litres: litres,
      smu: smuStart + i * smuStep,
      product: product,
      at: start.add(Duration(days: i)),
    ),
  );
}

void main() {
  group('muestras por intervalo', () {
    test('encadena despachos consecutivos: litros sobre avance de SMU', () {
      final samples = intervalSamples(movements: [
        disp('a', equipmentId: 'EX01', litres: 500, smu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', litres: 600, smu: 1010,
            at: DateTime.utc(2026, 6, 2)),
      ]);
      expect(samples, hasLength(1));
      final s = samples.single;
      // El despacho POSTERIOR repone lo quemado: 600 L sobre 10 h = 60 L/h.
      expect(s.litres, 600);
      expect(s.smuDelta, 10);
      expect(s.burnRate, 60);
      expect(s.smuPrev, 1000);
      expect(s.smuCurr, 1010);
    });

    test('un solo despacho no produce intervalo', () {
      expect(
        intervalSamples(movements: [
          disp('a', equipmentId: 'EX01', litres: 500, smu: 1000),
        ]),
        isEmpty,
      );
    });

    test('descarta el avance de SMU insuficiente (division entre casi-cero)', () {
      final samples = intervalSamples(movements: [
        disp('a', equipmentId: 'EX01', litres: 500, smu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', litres: 600, smu: 1000.05,
            at: DateTime.utc(2026, 6, 2)),
      ]);
      expect(samples, isEmpty);
    });

    test('descarta el burn rate no plausible (artefacto del dato)', () {
      final samples = intervalSamples(movements: [
        disp('a', equipmentId: 'TANK', litres: 100, smu: 1,
            at: DateTime.utc(2026, 6, 1)),
        // 9000 L sobre 1 unidad de SMU: no es una maquina, es un tanque.
        disp('b', equipmentId: 'TANK', litres: 9000, smu: 2,
            at: DateTime.utc(2026, 6, 2)),
      ]);
      expect(samples, isEmpty);
    });

    test('NO mezcla productos de un mismo equipo en la misma cadena', () {
      final samples = intervalSamples(movements: [
        disp('d1', equipmentId: 'EX01', litres: 500, smu: 1000,
            product: 'Diesel', at: DateTime.utc(2026, 6, 1)),
        disp('c1', equipmentId: 'EX01', litres: 20, smu: 1005,
            product: 'Coolant', at: DateTime.utc(2026, 6, 2)),
        disp('d2', equipmentId: 'EX01', litres: 600, smu: 1010,
            product: 'Diesel', at: DateTime.utc(2026, 6, 3)),
      ]);
      // Solo el par Diesel->Diesel; el coolant no cierra intervalo con diesel.
      expect(samples, hasLength(1));
      expect(samples.single.product, 'Diesel');
      expect(samples.single.smuDelta, 10);
    });

    test('un despacho sin equipo real (Unauthorised) no encadena nada', () {
      final samples = intervalSamples(movements: [
        disp('a', equipmentId: 'Unauthorised', litres: 500, smu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'Unauthorised', litres: 600, smu: 1010,
            at: DateTime.utc(2026, 6, 2)),
      ]);
      expect(samples, isEmpty);
    });

    test('resuelve categoria y descripcion desde el maestro', () {
      final samples = intervalSamples(
        movements: chain('EX01', count: 2, litres: 600, smuStep: 10),
        equipment: const [
          Equipment(
            equipmentId: 'EX01',
            category: 'Excavadoras',
            description: 'Excavadora 01',
          ),
        ],
      );
      expect(samples.single.category, 'Excavadoras');
      expect(samples.single.equipmentDescription, 'Excavadora 01');
    });

    test('sin maestro la categoria cae en (sin dato)', () {
      final samples =
          intervalSamples(movements: chain('EX01', count: 2, litres: 600, smuStep: 10));
      expect(samples.single.category, noDataLabel);
    });
  });

  group('linea base por categoria', () {
    /// Categoria con tres equipos normales (60 L/h) y uno que consume el doble.
    BurnRateAudit auditWithOutlier() => BurnRateAudit.run(
          movements: [
            ...chain('A', count: 5, litres: 600, smuStep: 10),
            ...chain('B', count: 5, litres: 606, smuStep: 10),
            ...chain('C', count: 5, litres: 594, smuStep: 10),
            ...chain('D', count: 5, litres: 1200, smuStep: 10),
          ],
          equipment: const [
            Equipment(equipmentId: 'A', category: 'Excavadoras'),
            Equipment(equipmentId: 'B', category: 'Excavadoras'),
            Equipment(equipmentId: 'C', category: 'Excavadoras'),
            Equipment(equipmentId: 'D', category: 'Excavadoras'),
          ],
        );

    test('marca el equipo que se desvia de su categoria', () {
      final audit = auditWithOutlier();
      final anomalies = audit.equipmentAnomalies;
      expect(anomalies, hasLength(1));
      expect(anomalies.single.equipmentId, 'D');
      expect(anomalies.single.direction, Deviation.high);
      // 120 vs una base de ~60: el doble.
      expect(anomalies.single.deviationPct, greaterThan(90));
      expect(anomalies.single.baseline, closeTo(60.6, 0.7));
    });

    test('la mediana NO se deja arrastrar por el outlier', () {
      final audit = auditWithOutlier();
      final category = audit.categories.single;
      // Con media aritmetica la base seria ~76 y D dejaria de parecer anomalo.
      expect(category.baseline, lessThan(65));
      expect(category.equipmentCount, 4);
      expect(category.anomalous, 1);
    });

    test('una categoria con menos de 3 equipos confiables no fija base', () {
      final audit = BurnRateAudit.run(
        movements: [
          ...chain('A', count: 5, litres: 600, smuStep: 10),
          ...chain('B', count: 5, litres: 3000, smuStep: 10),
        ],
        equipment: const [
          Equipment(equipmentId: 'A', category: 'Raros'),
          Equipment(equipmentId: 'B', category: 'Raros'),
        ],
      );
      expect(audit.categories, isEmpty);
      expect(audit.equipmentAnomalies, isEmpty);
      // Los equipos siguen apareciendo, solo que sin base con que compararlos.
      expect(audit.equipment, hasLength(2));
      expect(audit.equipment.every((e) => e.baseline == null), isTrue);
    });

    test('un equipo con pocas muestras no se marca aunque se desvie', () {
      final audit = BurnRateAudit.run(
        movements: [
          ...chain('A', count: 5, litres: 600, smuStep: 10),
          ...chain('B', count: 5, litres: 606, smuStep: 10),
          ...chain('C', count: 5, litres: 594, smuStep: 10),
          // Un solo intervalo: la mediana de una muestra no es evidencia.
          ...chain('E', count: 2, litres: 2000, smuStep: 10),
        ],
        equipment: const [
          Equipment(equipmentId: 'A', category: 'Excavadoras'),
          Equipment(equipmentId: 'B', category: 'Excavadoras'),
          Equipment(equipmentId: 'C', category: 'Excavadoras'),
          Equipment(equipmentId: 'E', category: 'Excavadoras'),
        ],
      );
      final e = audit.equipment.firstWhere((x) => x.equipmentId == 'E');
      expect(e.isReliable, isFalse);
      expect(e.anomalous, isFalse);
    });
  });

  group('intervalos atipicos', () {
    /// Serie con variacion natural (58..63 L/h) y un pico al final.
    List<Movement> variedChain(List<double> litresPerInterval) {
      final start = DateTime.utc(2026, 6, 1);
      // El primer despacho solo abre la cadena: no produce intervalo.
      final movements = <Movement>[
        disp('EX01-0', equipmentId: 'EX01', litres: 600, smu: 100, at: start),
      ];
      for (var i = 0; i < litresPerInterval.length; i++) {
        movements.add(disp(
          'EX01-${i + 1}',
          equipmentId: 'EX01',
          litres: litresPerInterval[i],
          smu: 100 + (i + 1) * 10,
          at: start.add(Duration(days: i + 1)),
        ));
      }
      return movements;
    }

    test('marca el despacho que se aparta del historial del propio equipo', () {
      final audit = BurnRateAudit.run(
        // 58, 60, 62, 59, 61, 60, 63, 57 L/h ... y un pico de 180 L/h.
        movements: variedChain(
            [580, 600, 620, 590, 610, 600, 630, 570, 1800]),
      );
      expect(audit.intervalAnomalies, isNotEmpty);
      final hit = audit.intervalAnomalies.first;
      expect(hit.sample.sourceId, 'EX01-9');
      expect(hit.sample.burnRate, 180);
      expect(hit.direction, Deviation.high);
      expect(hit.typicalBurnRate, 60);
      expect(hit.z!.abs(), greaterThan(burnRateIntervalZ));
    });

    test('la variacion normal de la serie no se marca', () {
      final audit = BurnRateAudit.run(
        movements: variedChain([580, 600, 620, 590, 610, 600, 630, 570]),
      );
      expect(audit.intervalAnomalies, isEmpty);
    });

    test('una serie SIN dispersion no se evalua: no hay contra que medir', () {
      // MAD 0 -> sigma 0. Marcar aqui seria dividir por cero; MSGQ descarta
      // estas series igual, y por eso el pico necesita una serie con variacion.
      final audit = BurnRateAudit.run(
        movements: chain('EX01', count: 10, litres: 600, smuStep: 10),
      );
      expect(audit.intervalAnomalies, isEmpty);
    });
  });

  group('proyeccion por producto', () {
    final audit = BurnRateAudit.run(movements: [
      ...chain('EX01', count: 5, litres: 600, smuStep: 10, product: 'Diesel'),
      ...chain('EX01', count: 5, litres: 20, smuStep: 10, product: 'Coolant',
          smuStart: 500, from: DateTime.utc(2026, 6, 20)),
    ]);

    test('lista los productos ordenados por litros totales', () {
      expect(audit.products, ['Diesel', 'Coolant']);
    });

    test('re-proyectar filtra las muestras sin recomputarlas', () {
      final onlyDiesel = audit.forProduct('Diesel');
      expect(onlyDiesel.product, 'Diesel');
      expect(onlyDiesel.samples.every((s) => s.product == 'Diesel'), isTrue);
      // `samplesAll` se conserva intacto: por eso el cambio es en memoria.
      expect(onlyDiesel.samplesAll.length, audit.samplesAll.length);
      expect(onlyDiesel.kpis.intervals, lessThan(audit.kpis.intervals));
    });
  });

  group('cobertura temporal', () {
    test('avisa cuando las muestras cubren solo un tramo del rango', () {
      // 4 dias de datos dentro de un rango de 90.
      final audit = BurnRateAudit.run(
        movements: chain('EX01', count: 5, litres: 600, smuStep: 10,
            from: DateTime.utc(2026, 6, 1)),
      );
      final coverage = audit.coverage(
          DateTime.utc(2026, 4, 1), DateTime.utc(2026, 6, 30));
      expect(coverage.partial, isTrue);
      expect(coverage.spanDays, 4);
      expect(coverage.daysWithData, 4);
      expect(coverage.first, DateTime.utc(2026, 6, 2));
    });

    test('sin muestras el rango se reporta como ciego, no como completo', () {
      final audit = BurnRateAudit.run(movements: const []);
      final coverage = audit.coverage(
          DateTime.utc(2026, 6, 1), DateTime.utc(2026, 6, 30));
      expect(coverage.partial, isTrue);
      expect(coverage.first, isNull);
      expect(coverage.rangeDays, 30);
    });
  });

  group('KPIs', () {
    test('el burn rate de flota es la mediana de los equipos confiables', () {
      final audit = BurnRateAudit.run(
        movements: [
          ...chain('A', count: 5, litres: 600, smuStep: 10), // 60 L/h
          ...chain('B', count: 5, litres: 800, smuStep: 10), // 80 L/h
          ...chain('C', count: 5, litres: 1000, smuStep: 10), // 100 L/h
        ],
      );
      expect(audit.kpis.equipmentAnalysed, 3);
      expect(audit.kpis.fleetBurnRate, 80);
    });
  });
}
