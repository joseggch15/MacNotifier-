import 'package:adapt_mac_notifier/src/msgq/analytics/activity_audit.dart';
import 'package:adapt_mac_notifier/src/msgq/analytics/sfl_resolution.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

Movement disp(
  String id, {
  required String equipmentId,
  required DateTime at,
  double litres = 100,
  double? smu,
  String product = 'Diesel',
  String? smuType = 'Hours',
}) =>
    Movement(
      id: id,
      kind: MovementKind.dispense,
      equipmentId: equipmentId,
      volume: litres,
      smuValue: smu,
      smuType: smuType,
      product: product,
      recordCollectedAt: at,
    );

const _limits = [
  ConsumptionLimit(
      id: 'c1', equipmentId: 'EX01', product: 'Diesel', sfl: 1000),
];

void main() {
  group('resolucion del SFL', () {
    test('el limite del FMS gana, priorizando el producto dominante', () {
      final sfl = resolveSfl(
        movements: [
          disp('a', equipmentId: 'EX01', at: DateTime.utc(2026, 6, 1)),
          disp('b', equipmentId: 'EX01', at: DateTime.utc(2026, 6, 2)),
          disp('c',
              equipmentId: 'EX01',
              at: DateTime.utc(2026, 6, 3),
              product: 'Coolant'),
        ],
        limits: const [
          ConsumptionLimit(
              id: 'c1', equipmentId: 'EX01', product: 'Diesel', sfl: 7450),
          ConsumptionLimit(
              id: 'c2', equipmentId: 'EX01', product: 'Coolant', sfl: 40),
        ],
      );
      // Diesel es el mas despachado: su SFL es el pertinente, no el del coolant.
      expect(sfl['EX01']!.sfl, 7450);
      expect(sfl['EX01']!.source, SflSource.limit);
    });

    test('sin limite cae al respaldo por palabra clave de categoria', () {
      final sfl = resolveSfl(
        movements: [disp('a', equipmentId: 'LV02', at: DateTime.utc(2026, 6, 1))],
        equipment: const [
          Equipment(equipmentId: 'LV02', category: 'LIGHT VEHICLE - 4x4'),
        ],
      );
      expect(sfl['LV02']!.sfl, 80);
      expect(sfl['LV02']!.source, SflSource.fallback);
    });

    test('sin limite ni categoria conocida queda sin dato', () {
      final sfl = resolveSfl(
        movements: [disp('a', equipmentId: 'XX', at: DateTime.utc(2026, 6, 1))],
        equipment: const [Equipment(equipmentId: 'XX', category: 'Rara')],
      );
      expect(sfl['XX']!.isKnown, isFalse);
      expect(sfl['XX']!.source, SflSource.none);
    });
  });

  group('equipos fantasma', () {
    final now = DateTime.utc(2026, 7, 1);

    test('marca al que lleva mas del umbral sin despachar', () {
      final rows = idleAssetsOf(
        equipment: const [
          Equipment(equipmentId: 'EX01', status: statusInService),
        ],
        movements: [
          disp('a', equipmentId: 'EX01', at: DateTime.utc(2026, 6, 1)),
        ],
        now: now,
        minDays: 15,
      );
      final a = rows.single;
      expect(a.idleClass, IdleClass.idle);
      expect(a.daysIdle, 30);
      expect(a.historicDispenses, 1);
      expect(a.isCritical, isTrue); // 30 dias = umbral critico
    });

    test('el que nunca despacho entra SIEMPRE, sea cual sea el umbral', () {
      final rows = idleAssetsOf(
        equipment: const [
          Equipment(equipmentId: 'NUEVO', status: statusInService),
        ],
        movements: const [],
        now: now,
        minDays: 999,
      );
      expect(rows.single.idleClass, IdleClass.neverDispensed);
      expect(rows.single.daysIdle, isNull);
      expect(rows.single.historicDispenses, 0);
    });

    test('un equipo activo dentro del umbral no se marca', () {
      final rows = idleAssetsOf(
        equipment: const [
          Equipment(equipmentId: 'EX01', status: statusInService),
        ],
        movements: [
          disp('a', equipmentId: 'EX01', at: DateTime.utc(2026, 6, 28)),
        ],
        now: now,
        minDays: 15,
      );
      expect(rows, isEmpty);
    });

    test('solo mira los equipos In Service', () {
      final rows = idleAssetsOf(
        equipment: const [
          Equipment(equipmentId: 'A', status: statusOutOfService),
          Equipment(equipmentId: 'B', status: statusDecommissioned),
        ],
        movements: const [],
        now: now,
      );
      expect(rows, isEmpty);
    });

    test('los que nunca despacharon van primero', () {
      final rows = idleAssetsOf(
        equipment: const [
          Equipment(equipmentId: 'VIEJO', status: statusInService),
          Equipment(equipmentId: 'NUEVO', status: statusInService),
        ],
        movements: [
          disp('a', equipmentId: 'VIEJO', at: DateTime.utc(2026, 6, 1)),
        ],
        now: now,
        minDays: 1,
      );
      expect(rows.first.equipmentId, 'NUEVO');
    });
  });

  group('trabaja sin repostar', () {
    /// Cadena que fija un burn rate tipico de 10 L/h con muestras suficientes.
    List<Movement> baseline(String id) => [
          for (var i = 0; i < 6; i++)
            disp('$id-b$i',
                equipmentId: id,
                litres: 100,
                smu: 100 + i * 10,
                at: DateTime.utc(2026, 6, 1).add(Duration(days: i))),
        ];

    test('marca el intervalo cuyo faltante supera un tanque con margen', () {
      final movements = [
        ...baseline('EX01'),
        // 500 h de avance en 21 dias (dentro de lo plausible) = 5000 L
        // esperados, pero solo se registran 100 L: faltan ~4900 (SFL 1000).
        disp('gap',
            equipmentId: 'EX01',
            litres: 100,
            smu: 650,
            at: DateTime.utc(2026, 6, 27)),
      ];
      final sfl = resolveSfl(movements: movements, limits: _limits);
      final rows = unfueledActivityOf(
        movements: movements,
        sflByEquipment: sfl,
      );
      final hit = rows.single;
      expect(hit.equipmentId, 'EX01');
      expect(hit.typicalBurnRate, 10);
      expect(hit.smuDelta, 500);
      expect(hit.expectedLitres, 5000);
      expect(hit.dispensedLitres, 100);
      expect(hit.unregisteredLitres, 4900);
    });

    test('un salto de SMU fisicamente imposible se descarta, no se estima', () {
      final movements = [
        ...baseline('EX01'),
        // 50.000 h de avance en 1 dia: sensor corrupto, no actividad real.
        disp('corrupt',
            equipmentId: 'EX01',
            litres: 100,
            smu: 50150,
            at: DateTime.utc(2026, 6, 7)),
      ];
      final rows = unfueledActivityOf(
        movements: movements,
        sflByEquipment: resolveSfl(movements: movements, limits: _limits),
      );
      expect(rows, isEmpty);
    });

    test('las ventanas mas largas que el maximo se descartan', () {
      final movements = [
        ...baseline('EX01'),
        disp('far',
            equipmentId: 'EX01',
            litres: 100,
            smu: 700,
            at: DateTime.utc(2026, 6, 1).add(const Duration(days: 200))),
      ];
      final rows = unfueledActivityOf(
        movements: movements,
        sflByEquipment: resolveSfl(movements: movements, limits: _limits),
      );
      expect(rows, isEmpty);
    });

    test('los despachos SIN SMU de la ventana cuentan como registrados', () {
      final movements = [
        ...baseline('EX01'),
        // Cuatro cargas grandes sin lectura de SMU dentro de la ventana.
        for (var i = 0; i < 4; i++)
          disp('nosmu$i',
              equipmentId: 'EX01',
              litres: 1500,
              at: DateTime.utc(2026, 6, 10).add(Duration(days: i))),
        disp('gap',
            equipmentId: 'EX01',
            litres: 100,
            smu: 650,
            at: DateTime.utc(2026, 6, 27)),
      ];
      final rows = unfueledActivityOf(
        movements: movements,
        sflByEquipment: resolveSfl(movements: movements, limits: _limits),
      );
      // 5000 esperados menos 6100 registrados: no falta nada.
      expect(rows, isEmpty);
    });

    test('sin SFL resuelto el equipo no participa', () {
      final movements = [
        ...baseline('EX01'),
        disp('gap',
            equipmentId: 'EX01',
            litres: 100,
            smu: 650,
            at: DateTime.utc(2026, 6, 27)),
      ];
      expect(unfueledActivityOf(movements: movements), isEmpty);
    });
  });

  group('repostado sin operar', () {
    test('marca la racha de despachos con el SMU congelado', () {
      // 5 despachos en 20 dias, todos con SMU 500: 4 pares congelados.
      final movements = [
        for (var i = 0; i < 5; i++)
          disp('f$i',
              equipmentId: 'EX01',
              litres: 400,
              smu: 500,
              at: DateTime.utc(2026, 6, 1).add(Duration(days: i * 5))),
      ];
      final rows = fuelingWithoutActivityOf(
        movements: movements,
        sflByEquipment: resolveSfl(movements: movements, limits: _limits),
      );
      final hit = rows.single;
      expect(hit.dispenses, 5);
      expect(hit.days, 20);
      expect(hit.frozenSmu, 500);
      // Los litros son los despachados DESPUES de la primera lectura: 4 x 400.
      expect(hit.litres, 1600);
      expect(hit.overSfl, isTrue); // 1600 > SFL 1000
    });

    test('una racha corta no basta', () {
      final movements = [
        for (var i = 0; i < 2; i++)
          disp('f$i',
              equipmentId: 'EX01',
              smu: 500,
              at: DateTime.utc(2026, 6, 1).add(Duration(days: i * 10))),
      ];
      expect(fuelingWithoutActivityOf(movements: movements), isEmpty);
    });

    test('un lapso corto no basta aunque haya despachos', () {
      final movements = [
        for (var i = 0; i < 6; i++)
          disp('f$i',
              equipmentId: 'EX01',
              smu: 500,
              at: DateTime.utc(2026, 6, 1).add(Duration(hours: i))),
      ];
      expect(fuelingWithoutActivityOf(movements: movements), isEmpty);
    });

    test('un SMU que avanza corta la racha', () {
      final movements = [
        for (var i = 0; i < 5; i++)
          disp('f$i',
              equipmentId: 'EX01',
              smu: 500 + i * 20.0, // avanza siempre
              at: DateTime.utc(2026, 6, 1).add(Duration(days: i * 5))),
      ];
      expect(fuelingWithoutActivityOf(movements: movements), isEmpty);
    });

    test('sin SFL la racha se reporta pero no se marca sobre el limite', () {
      final movements = [
        for (var i = 0; i < 5; i++)
          disp('f$i',
              equipmentId: 'EX01',
              litres: 400,
              smu: 500,
              at: DateTime.utc(2026, 6, 1).add(Duration(days: i * 5))),
      ];
      final rows = fuelingWithoutActivityOf(movements: movements);
      expect(rows.single.sfl, isNull);
      expect(rows.single.overSfl, isFalse);
    });
  });

  group('auditoria completa', () {
    test('los KPIs consolidan los tres detectores', () {
      final movements = [
        for (var i = 0; i < 5; i++)
          disp('f$i',
              equipmentId: 'EX01',
              litres: 400,
              smu: 500,
              at: DateTime.utc(2026, 6, 1).add(Duration(days: i * 5))),
      ];
      final audit = ActivityAudit.run(
        movements: movements,
        equipment: const [
          Equipment(equipmentId: 'EX01', status: statusInService),
          Equipment(equipmentId: 'NUEVO', status: statusInService),
        ],
        limits: _limits,
        now: DateTime.utc(2026, 7, 15),
        idleDays: 15,
      );
      expect(audit.kpis.equipmentInService, 2);
      expect(audit.kpis.idleAssets, 2); // EX01 lleva 24 dias; NUEVO nunca
      expect(audit.kpis.neverDispensed, 1);
      expect(audit.kpis.idlePctOfFleet, 100.0);
      expect(audit.kpis.frozenRuns, 1);
      expect(audit.kpis.runsOverSfl, 1);
    });
  });
}
