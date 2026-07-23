import 'package:adapt_mac_notifier/src/msgq/analytics/sfl_audit.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

Movement disp(
  String id, {
  String? equipmentId,
  required double volume,
  String product = 'Diesel',
  String? status,
  String? type,
  String? fieldUser,
  DateTime? at,
}) =>
    Movement(
      id: id,
      kind: MovementKind.dispense,
      equipmentId: equipmentId,
      volume: volume,
      product: product,
      status: status,
      type: type,
      fieldUser: fieldUser,
      recordCollectedAt: at ?? DateTime.utc(2026, 6, 15),
    );

const _limits = [
  ConsumptionLimit(id: 'c1', equipmentId: 'EX01', product: 'Diesel', sfl: 1000),
  ConsumptionLimit(id: 'c2', equipmentId: 'LV02', product: 'Diesel', sfl: 80),
];

void main() {
  group('excesos', () {
    test('marca el despacho que supera el SFL mas la tolerancia', () {
      final audit = SflAudit.run(
        movements: [disp('a', equipmentId: 'EX01', volume: 1200)],
        limits: _limits,
      );
      final e = audit.exceedances.single;
      expect(e.equipmentId, 'EX01');
      expect(e.sfl, 1000);
      expect(e.excess, 200);
      expect(e.excessPct, 20);
    });

    test('un exceso dentro de la tolerancia no se marca', () {
      // 1015 sobre SFL 1000 = 1,5%, bajo el 2% de tolerancia.
      final audit = SflAudit.run(
        movements: [disp('a', equipmentId: 'EX01', volume: 1015)],
        limits: _limits,
      );
      expect(audit.exceedances, isEmpty);
    });

    test('sin limite para el par (equipo, producto) no hay exceso', () {
      final audit = SflAudit.run(
        movements: [disp('a', equipmentId: 'EX01', volume: 5000,
            product: 'Gasolina')],
        limits: _limits,
      );
      expect(audit.exceedances, isEmpty);
    });

    test('el cruce por producto es case-insensitive', () {
      final audit = SflAudit.run(
        movements: [disp('a', equipmentId: 'EX01', volume: 1200,
            product: 'DIESEL')],
        limits: _limits,
      );
      expect(audit.exceedances, hasLength(1));
    });

    test('los KPIs agregan exceso total, peor y % de despachos', () {
      final audit = SflAudit.run(
        movements: [
          disp('a', equipmentId: 'EX01', volume: 1200), // exceso 200
          disp('b', equipmentId: 'EX01', volume: 1500), // exceso 500
          disp('c', equipmentId: 'EX01', volume: 500), // normal
          disp('d', equipmentId: 'LV02', volume: 90), // exceso 10
        ],
        limits: _limits,
      );
      expect(audit.kpis.exceedances, 3);
      expect(audit.kpis.totalExcessL, 710);
      expect(audit.kpis.worstExcessL, 500);
      expect(audit.kpis.equipmentAffected, 2);
      expect(audit.kpis.pctOfDispenses, 75); // 3 de 4
    });
  });

  group('conflictos sin equipo', () {
    test('un Unauthorised sobre el SFL maximo de la flota es over_max', () {
      final audit = SflAudit.run(
        movements: [
          disp('a', equipmentId: 'Unauthorised', volume: 2000,
              type: typeUnauthorised),
        ],
        limits: _limits,
      );
      final c = audit.conflicts.single;
      expect(c.overMax, isTrue);
      expect(c.fleetMaxSfl, 1000); // el maximo de la flota para Diesel
    });

    test('un despacho no_equip bajo el maximo es conflicto pero no over_max', () {
      final audit = SflAudit.run(
        movements: [disp('a', volume: 500, status: 'no_equip')],
        limits: _limits,
      );
      expect(audit.conflicts.single.overMax, isFalse);
    });

    test('un despacho con equipo valido no es conflicto', () {
      final audit = SflAudit.run(
        movements: [disp('a', equipmentId: 'EX01', volume: 500)],
        limits: _limits,
      );
      expect(audit.conflicts, isEmpty);
    });
  });

  group('desgloses', () {
    final audit = SflAudit.run(
      movements: [
        disp('a', equipmentId: 'EX01', volume: 1200, fieldUser: 'jgomez'),
        disp('b', equipmentId: 'EX01', volume: 1500, fieldUser: 'jgomez'),
        disp('c', equipmentId: 'LV02', volume: 200, fieldUser: 'mlopez'),
      ],
      limits: _limits,
      equipment: const [
        Equipment(equipmentId: 'EX01', category: 'Excavadora', group: 'Newmont'),
        Equipment(equipmentId: 'LV02', category: 'Liviano', group: 'AP&G'),
      ],
    );

    test('por operador agrupa los excesos', () {
      final rows = audit.byFieldUser();
      expect(rows.first.key, 'jgomez');
      expect(rows.first.exceedances, 2);
      expect(rows.first.totalExcessL, 700);
    });

    test('por categoria resuelve la dimension desde el maestro', () {
      final rows = audit.byCategory();
      final exc = rows.firstWhere((r) => r.key == 'Excavadora');
      expect(exc.exceedances, 2);
      expect(exc.equipmentCount, 1);
    });

    test('por grupo separa Newmont de los BP', () {
      final rows = audit.byGroup();
      expect(rows.map((r) => r.key), containsAll(['Newmont', 'AP&G']));
    });
  });

  group('reporte por equipo', () {
    test('clasifica Normal / Over y calcula el % Over', () {
      final audit = SflAudit.run(
        movements: [
          disp('a', equipmentId: 'EX01', volume: 1200),
          disp('b', equipmentId: 'EX01', volume: 500),
          disp('c', equipmentId: 'EX01', volume: 800),
        ],
        limits: _limits,
        equipment: const [Equipment(equipmentId: 'EX01', description: 'Exc 01')],
      );
      final row = audit.equipmentSummary().single;
      expect(row.dispenses, 3);
      expect(row.overSfl, 1);
      expect(row.normal, 2);
      expect(row.overPct, closeTo(33.33, 0.01));
      expect(row.sfl, 1000);
      expect(row.sflSource, SflSource.limit);
      expect(row.maxVolumeL, 1200);
    });

    test('un equipo sin SFL resuelto no cuenta excesos', () {
      final audit = SflAudit.run(
        movements: [disp('a', equipmentId: 'XX', volume: 9000,
            product: 'Rara')],
        equipment: const [Equipment(equipmentId: 'XX', category: 'Rara')],
      );
      final row = audit.equipmentSummary().single;
      expect(row.overSfl, 0);
      expect(row.sflSource, SflSource.none);
    });
  });
}
