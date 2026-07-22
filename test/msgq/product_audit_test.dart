import 'package:adapt_mac_notifier/src/msgq/analytics/product_audit.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

Movement disp(
  String id, {
  required String equipmentId,
  required String product,
  DateTime? at,
  double litres = 100,
}) =>
    Movement(
      id: id,
      kind: MovementKind.dispense,
      equipmentId: equipmentId,
      product: product,
      volume: litres,
      recordCollectedAt: at ?? DateTime.utc(2026, 6, 15),
    );

/// Despachos que ESTABLECEN un producto por uso (3+ eventos).
List<Movement> established(String equipmentId, String product, {int n = 4}) =>
    List.generate(
      n,
      (i) => disp('$equipmentId-$product-$i',
          equipmentId: equipmentId,
          product: product,
          at: DateTime.utc(2026, 6, 1).add(Duration(days: i))),
    );

void main() {
  group('clase de producto', () {
    test('separa combustible de fluido de servicio', () {
      expect(productClass('Diesel LFO'), ProductClass.fuel);
      expect(productClass('Unleaded Gasoline'), ProductClass.fuel);
      expect(productClass('Coolant'), ProductClass.fluid);
      expect(productClass('Hydraulic Oil 68'), ProductClass.fluid);
      expect(productClass('15W40'), ProductClass.fluid);
      expect(productClass('Agua'), ProductClass.other);
      expect(productClass(null), ProductClass.other);
    });

    test("'Gas Oil' es combustible pese a contener OIL", () {
      // Es el caso que obliga a evaluar FUEL antes que FLUID.
      expect(productClass('Gas Oil'), ProductClass.fuel);
      expect(productClass('GASOIL'), ProductClass.fuel);
    });
  });

  group('conjunto permitido', () {
    test('el maestro autoriza el producto', () {
      final rows = productMismatchesOf(
        movements: [disp('a', equipmentId: 'EX01', product: 'Diesel')],
        limits: const [
          ConsumptionLimit(
              id: 'c1', equipmentId: 'EX01', product: 'Diesel', sfl: 7450),
        ],
      );
      expect(rows, isEmpty);
    });

    test('el historial observado tambien autoriza (producto deshabilitado)',
        () {
      final rows = productMismatchesOf(
        movements: [disp('a', equipmentId: 'EX01', product: 'Coolant')],
        limits: const [
          ConsumptionLimit(
              id: 'c1', equipmentId: 'EX01', product: 'Diesel', sfl: 7450),
        ],
        productHistory: [
          // Estuvo habilitado en su momento: el despacho es legitimo.
          ProductAssignment(
            key: 'EX01|COOLANT',
            equipmentId: 'EX01',
            product: 'Coolant',
            firstSeen: DateTime.utc(2026, 1, 1),
            lastSeen: DateTime.utc(2026, 3, 1),
          ),
        ],
      );
      expect(rows, isEmpty);
    });

    test('el uso establecido autoriza aunque no este en ningun maestro', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          ...established('EX01', 'Coolant'), // 4 eventos: establecido
        ],
      );
      expect(rows, isEmpty);
    });

    test('un despacho AISLADO no se establece solo: se marca', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          disp('raro',
              equipmentId: 'EX01',
              product: 'Coolant',
              at: DateTime.utc(2026, 6, 20)),
        ],
      );
      final hit = rows.single;
      expect(hit.product, 'Coolant');
      expect(hit.productClassOf, ProductClass.fluid);
      expect(hit.expectedProducts, 'Diesel');
      expect(hit.expectedClasses, 'FUEL');
    });
  });

  group('cruce de clase', () {
    test('fluido a un equipo solo-combustible es cruce (tag clonado)', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          disp('x', equipmentId: 'EX01', product: 'Hydraulic Oil',
              at: DateTime.utc(2026, 6, 20)),
        ],
      );
      expect(rows.single.crossClass, isTrue);
      expect(rows.single.alertCategory, alertProductForeign);
    });

    test('otro combustible a un equipo de combustible NO es cruce', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          disp('x', equipmentId: 'EX01', product: 'Unleaded Gasoline',
              at: DateTime.utc(2026, 6, 20)),
        ],
      );
      expect(rows.single.crossClass, isFalse);
      expect(rows.single.alertCategory, alertProductOffMaster);
    });

    test('un producto OTHER nunca cruza clase', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          disp('x', equipmentId: 'EX01', product: 'Agua',
              at: DateTime.utc(2026, 6, 20)),
        ],
      );
      expect(rows.single.crossClass, isFalse);
    });
  });

  group('omisiones deliberadas', () {
    test('un equipo sin base establecida se OMITE, no se marca', () {
      // Un unico despacho: no hay con que juzgar al equipo.
      final rows = productMismatchesOf(
        movements: [disp('a', equipmentId: 'NUEVO', product: 'Coolant')],
      );
      expect(rows, isEmpty);
    });

    test('un despacho sin equipo real no se evalua', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          disp('u', equipmentId: 'Unauthorised', product: 'Coolant'),
        ],
      );
      expect(rows, isEmpty);
    });

    test('las entregas y transferencias no cuentan: solo despachos', () {
      final rows = productMismatchesOf(
        movements: [
          ...established('EX01', 'Diesel'),
          Movement(
            id: 'e1',
            kind: MovementKind.delivery,
            equipmentId: 'EX01',
            product: 'Coolant',
            recordCollectedAt: DateTime.utc(2026, 6, 20),
          ),
        ],
      );
      expect(rows, isEmpty);
    });
  });

  group('auditoria completa', () {
    test('los cruces van primero y los KPIs los separan', () {
      final audit = ProductAudit.run(
        movements: [
          ...established('EX01', 'Diesel'),
          ...established('EX02', 'Diesel'),
          // Cruce de clase (mas antiguo).
          disp('cross', equipmentId: 'EX01', product: 'Coolant',
              at: DateTime.utc(2026, 6, 10)),
          // Fuera del maestro pero misma clase (mas reciente).
          disp('same', equipmentId: 'EX02', product: 'Gasoline',
              at: DateTime.utc(2026, 6, 25)),
        ],
      );
      expect(audit.kpis.mismatches, 2);
      expect(audit.kpis.crossClass, 1);
      expect(audit.kpis.equipmentAffected, 2);
      // Pese a ser el mas antiguo, el cruce de clase encabeza la lista.
      expect(audit.mismatches.first.sourceId, 'cross');
      expect(audit.crossClassMismatches.single.equipmentId, 'EX01');
    });

    test('sin hallazgos los KPIs son cero', () {
      final audit = ProductAudit.run(movements: established('EX01', 'Diesel'));
      expect(audit.kpis.mismatches, 0);
      expect(audit.mismatches, isEmpty);
    });
  });

  group('historial de habilitacion', () {
    test('aplana los limites y preserva el firstSeen', () {
      final seen = DateTime.utc(2026, 7, 1);
      final rows = ProductAssignment.fromLimits(
        const [
          ConsumptionLimit(
              id: 'c1', equipmentId: 'EX01', product: 'Diesel', sfl: 7450),
          ConsumptionLimit(
              id: 'c2', equipmentId: 'EX01', product: 'Coolant', sfl: 40),
        ],
        seenAt: seen,
        knownFirstSeen: {'EX01|DIESEL': DateTime.utc(2026, 1, 1)},
      );
      expect(rows, hasLength(2));
      final diesel = rows.firstWhere((r) => r.product == 'Diesel');
      expect(diesel.key, 'EX01|DIESEL');
      expect(diesel.firstSeen, DateTime.utc(2026, 1, 1));
      expect(diesel.lastSeen, seen);
      final coolant = rows.firstWhere((r) => r.product == 'Coolant');
      expect(coolant.firstSeen, seen);
    });
  });
}
