import 'package:adapt_mac_notifier/src/msgq/analytics/volume_deviation.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

Movement delivery(
  String id, {
  required double? measured,
  required double? field,
  String tank = 'T1',
  String product = 'Diesel',
  DateTime? at,
}) =>
    Movement(
      id: id,
      kind: MovementKind.delivery,
      volume: measured,
      secondaryVolume: field,
      tank: tank,
      product: product,
      recordCollectedAt: at ?? DateTime.utc(2026, 6, 15),
    );

void main() {
  group('deteccion', () {
    test('la guia sobre lo medido es sobre-facturacion, con signo positivo', () {
      final d = deviationsOf([
        delivery('a', measured: 20000, field: 20400),
      ]).single;
      expect(d.deviationL, 400);
      expect(d.deviationPct, 2.0);
      expect(d.direction, DeviationDirection.overbilled);
      expect(d.flagged, isTrue);
    });

    test('la guia bajo lo medido va con signo negativo', () {
      final d = deviationsOf([
        delivery('a', measured: 20000, field: 19600),
      ]).single;
      expect(d.deviationL, -400);
      expect(d.direction, DeviationDirection.underbilled);
      expect(d.flagged, isTrue);
    });

    test('una desviacion bajo el umbral no se marca', () {
      // 0,48%: el caso real de Merian que SI esta dentro de tolerancia.
      final d = deviationsOf([
        delivery('a', measured: 39810.5, field: 40000),
      ]).single;
      expect(d.flagged, isFalse);
      expect(d.deviationPct, lessThan(deliveryVolumeDeviationPct));
    });

    test('una entrega pequena no se marca aunque el % sea enorme', () {
      // 20 L medidos contra 40 de guia: 100% de desviacion sobre nada.
      final d = deviationsOf([delivery('a', measured: 20, field: 40)]).single;
      expect(d.deviationPct, 100);
      expect(d.flagged, isFalse);
    });

    test('sin uno de los dos volumenes la entrega se descarta', () {
      expect(
        deviationsOf([
          delivery('a', measured: 20000, field: null),
          delivery('b', measured: null, field: 20000),
          delivery('c', measured: 0, field: 20000),
        ]),
        isEmpty,
      );
    });

    test('los despachos y transferencias no participan', () {
      final rows = deviationsOf([
        Movement(
          id: 'd',
          kind: MovementKind.dispense,
          volume: 500,
          secondaryVolume: 600,
        ),
      ]);
      expect(rows, isEmpty);
    });

    test('una desviacion grande escala a critica', () {
      final d = deviationsOf([
        delivery('a', measured: 20000, field: 22000), // 10%
      ]).single;
      expect(d.flagged, isTrue);
      expect(d.isCritical, isTrue);
    });

    test('las marcadas van primero, luego por magnitud', () {
      final rows = deviationsOf([
        delivery('ok', measured: 20000, field: 20050), // 0,25%: no marcada
        delivery('leve', measured: 20000, field: 20400), // 2%
        delivery('grave', measured: 20000, field: 23000), // 15%
      ]);
      expect(rows.map((d) => d.sourceId), ['grave', 'leve', 'ok']);
    });
  });

  group('resumen por tanque', () {
    test('el saldo es la RESTA con signo, no la suma de magnitudes', () {
      // Una entrega cobra 400 de mas y otra 300 de menos: el saldo es 100, no
      // 700. Es la cifra que se lleva a una reclamacion.
      final rows = byTankOf(deviationsOf([
        delivery('a', measured: 20000, field: 20400),
        delivery('b', measured: 20000, field: 19700),
      ]));
      final t = rows.single;
      expect(t.tank, 'T1');
      expect(t.deliveries, 2);
      expect(t.flagged, 2);
      expect(t.netOverbilledL, 100);
      expect(t.measuredL, 40000);
      expect(t.fieldL, 40100);
    });

    test('los tanques se ordenan por la peor desviacion', () {
      final rows = byTankOf(deviationsOf([
        delivery('a', measured: 20000, field: 20400, tank: 'T1'), // 2%
        delivery('b', measured: 20000, field: 23000, tank: 'T2'), // 15%
      ]));
      expect(rows.first.tank, 'T2');
    });

    test('un tanque sin nombre cae en (sin dato)', () {
      final rows = byTankOf(deviationsOf([
        Movement(
          id: 'a',
          kind: MovementKind.delivery,
          volume: 20000,
          secondaryVolume: 20400,
          recordCollectedAt: DateTime.utc(2026, 6, 1),
        ),
      ]));
      expect(rows.single.tank, noDataLabel);
    });
  });

  group('auditoria completa', () {
    final audit = VolumeDeviationAudit.run(movements: [
      delivery('a', measured: 20000, field: 20400, at: DateTime.utc(2026, 6, 1)),
      delivery('b', measured: 20000, field: 19700, at: DateTime.utc(2026, 6, 2)),
      delivery('ok', measured: 20000, field: 20050,
          at: DateTime.utc(2026, 6, 3)),
    ]);

    test('separa lo en disputa del saldo', () {
      expect(audit.kpis.analysed, 3);
      expect(audit.kpis.flagged, 2);
      // En disputa suma magnitudes (400 + 300); el saldo las resta.
      expect(audit.kpis.disputedL, 700);
      expect(audit.kpis.netOverbilledL, 100);
      expect(audit.kpis.worstDeviationPct, 2.0);
    });

    test('flaggedDeliveries es el subconjunto marcado', () {
      expect(audit.flaggedDeliveries, hasLength(2));
      expect(audit.flaggedDeliveries.every((d) => d.flagged), isTrue);
    });

    test('sin entregas comparables los KPIs son ceros', () {
      final vacio = VolumeDeviationAudit.run(movements: const []);
      expect(vacio.kpis.analysed, 0);
      expect(vacio.kpis.worstDeviationPct, 0);
      expect(vacio.byTank, isEmpty);
    });
  });

  group('serie temporal', () {
    test('agrega el saldo por periodo', () {
      final rows = deviationsOf([
        delivery('a', measured: 20000, field: 20400, at: DateTime.utc(2026, 6, 1)),
        delivery('b', measured: 20000, field: 20200, at: DateTime.utc(2026, 6, 1)),
        delivery('c', measured: 20000, field: 19500, at: DateTime.utc(2026, 6, 5)),
      ]);
      final series = deviationOverTime(rows);
      expect(series, hasLength(2));
      expect(series.first.netOverbilledL, 600);
      expect(series.last.netOverbilledL, -500);
    });
  });
}
