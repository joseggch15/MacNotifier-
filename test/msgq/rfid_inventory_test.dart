import 'package:adapt_mac_notifier/src/msgq/analytics/rfid_inventory.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/change_event.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

ChangeEvent rfid({
  required String recordId,
  String? before,
  String? after,
  required DateTime at,
  String? who,
}) =>
    ChangeEvent(
      eventKey: '$changeRecordRfid:$recordId:$at:$attrRfid',
      changedAt: at,
      recordType: changeRecordRfid,
      recordId: recordId,
      event: before == null ? 'create' : (after == null ? 'destroy' : 'update'),
      whodunnit: who,
      attribute: attrRfid,
      before: before,
      after: after,
    );

void main() {
  group('clasificacion de la operacion', () {
    test('deriva alta, reemplazo y remocion de before/after', () {
      expect(RfidOperation.classify(after: 'AAA'),
          RfidOperation.newInstallation);
      expect(RfidOperation.classify(before: 'AAA', after: 'BBB'),
          RfidOperation.replacement);
      expect(RfidOperation.classify(before: 'AAA'), RfidOperation.removal);
    });
  });

  group('reporte de instalacion', () {
    final equipment = [
      const Equipment(
        equipmentId: 'EX01',
        internalId: '77',
        description: 'Excavadora 01',
        status: statusInService,
        rfid: 'BBB',
        department: 'Mina',
        costCentre: 'CC1',
        group: 'Newmont',
        category: 'Heavy',
      ),
    ];

    test('enlaza el tag vigente contra el maestro actual', () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', before: 'AAA', after: 'BBB',
              at: DateTime.utc(2026, 6, 10), who: 'jgomez'),
        ],
        equipment: equipment,
      );
      final row = audit.report.single;
      expect(row.operation, RfidOperation.replacement);
      expect(row.equipmentId, 'EX01');
      expect(row.tag, 'BBB');
      expect(row.department, 'Mina');
      expect(row.costCentre, 'CC1');
      expect(row.whodunnit, 'jgomez');
      expect(row.isIdentified, isTrue);
    });

    test('una remocion se resuelve por el historial observado de asignaciones',
        () {
      final audit = RfidInventoryAudit.run(
        changes: [
          // El tag AAA ya no esta en ningun equipo del maestro.
          rfid(recordId: 't1', before: 'AAA', at: DateTime.utc(2026, 6, 10)),
        ],
        equipment: equipment,
        history: [
          RfidAssignment(
            tag: 'AAA',
            equipmentId: 'EX01',
            lastSeen: DateTime.utc(2026, 6, 1),
          ),
        ],
      );
      final row = audit.report.single;
      expect(row.operation, RfidOperation.removal);
      expect(row.equipmentId, 'EX01'); // recuperado del historial
      expect(row.tag, 'AAA');
      expect(row.description, 'Excavadora 01');
    });

    test('sin historial, una remocion queda sin identificar (no se inventa)',
        () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', before: 'ZZZ', at: DateTime.utc(2026, 6, 10)),
        ],
        equipment: equipment,
      );
      expect(audit.report.single.equipmentId, unidentifiedLabel);
      expect(audit.report.single.isIdentified, isFalse);
    });

    test('el desfase horario del sitio decide el dia operativo', () {
      // 01:00 UTC del dia 11 = 22:00 local del dia 10 en Merian (UTC-3).
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', after: 'BBB', at: DateTime.utc(2026, 6, 11, 1)),
        ],
        equipment: equipment,
        tzOffsetHours: siteUtcOffsetHours,
      );
      final date = audit.report.single.date;
      expect(date.day, 10);
      expect(date.hour, 22);
    });

    test('el rango incluye el dia completo de la fecha final', () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', after: 'BBB',
              at: DateTime.utc(2026, 6, 10, 23, 30)),
        ],
        equipment: equipment,
        to: DateTime.utc(2026, 6, 10),
      );
      expect(audit.report, hasLength(1));
    });

    test('los KPIs cuentan cada tipo y los tags distintos', () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', after: 'BBB', at: DateTime.utc(2026, 6, 1)),
          rfid(recordId: 't2', before: 'CCC', after: 'DDD',
              at: DateTime.utc(2026, 6, 2)),
          rfid(recordId: 't3', before: 'EEE', at: DateTime.utc(2026, 6, 3)),
        ],
        equipment: equipment,
      );
      expect(audit.kpis.newInstallations, 1);
      expect(audit.kpis.replacements, 1);
      expect(audit.kpis.removals, 1);
      expect(audit.kpis.distinctTags, 3);
      expect(audit.kpis.equipmentWithRfid, 1);
      expect(audit.kpis.totalEquipment, 1);
    });
  });

  group('producto del equipo', () {
    test('los productos habilitados ganan sobre el historial de despachos', () {
      final map = equipmentProductMap(
        limits: const [
          ConsumptionLimit(id: 'c1', equipmentId: 'EX01', product: 'Diesel',
              sfl: 7450),
          ConsumptionLimit(id: 'c2', equipmentId: 'EX01', product: 'Coolant',
              sfl: 40),
        ],
        movements: [
          Movement(
            id: 'm1',
            kind: MovementKind.dispense,
            equipmentId: 'EX01',
            product: 'Gasolina',
          ),
        ],
      );
      // Ordenados y unidos: es lo que AdaptIQ muestra como 'Products consumed'.
      expect(map['EX01'], 'Coolant, Diesel');
    });

    test('sin limite cargado se usa el producto mas despachado', () {
      final map = equipmentProductMap(
        movements: [
          for (var i = 0; i < 3; i++)
            Movement(
              id: 'd$i',
              kind: MovementKind.dispense,
              equipmentId: 'LV02',
              product: 'Gasolina',
            ),
          Movement(
            id: 'x',
            kind: MovementKind.dispense,
            equipmentId: 'LV02',
            product: 'Diesel',
          ),
        ],
      );
      expect(map['LV02'], 'Gasolina');
    });

    test('un id con espacios internos responde tambien por su variante compacta',
        () {
      final map = equipmentProductMap(
        limits: const [
          ConsumptionLimit(id: 'c1', equipmentId: 'C- SE-12', product: 'Diesel',
              sfl: 100),
        ],
      );
      expect(map['C- SE-12'], 'Diesel');
      expect(map['C-SE-12'], 'Diesel'); // el duplicado del maestro del FMS
    });
  });

  group('agrupaciones', () {
    RfidInventoryAudit build() => RfidInventoryAudit.run(
          changes: [
            rfid(recordId: 't1', after: 'AAA', at: DateTime.utc(2026, 6, 1)),
            rfid(recordId: 't2', before: 'X', after: 'BBB',
                at: DateTime.utc(2026, 6, 2)),
            rfid(recordId: 't3', before: 'CCC', at: DateTime.utc(2026, 6, 3)),
          ],
          equipment: const [
            Equipment(equipmentId: 'EX01', internalId: '1', rfid: 'AAA',
                group: 'Newmont', department: 'Mina'),
            Equipment(equipmentId: 'EX02', internalId: '2', rfid: 'BBB',
                group: 'Newmont', department: 'Taller'),
          ],
        );

    test('agrupa por grupo con desglose por tipo', () {
      final rows = build().byGroup();
      final newmont = rows.firstWhere((r) => r.key == 'Newmont');
      expect(newmont.installations, 2);
      expect(newmont.newInstallations, 1);
      expect(newmont.replacements, 1);
      // La remocion no se pudo enlazar: cae en (sin dato), no en Newmont.
      expect(rows.any((r) => r.key == noDataLabel), isTrue);
    });

    test('el churn solo cuenta equipos identificados', () {
      final rows = build().tagChangeFrequency();
      expect(rows.map((r) => r.equipmentId), ['EX01', 'EX02']);
      expect(rows.every((r) => r.changes == 1), isTrue);
    });
  });

  group('validaciones', () {
    test('detecta el mismo tag en dos equipos del maestro', () {
      final audit = RfidInventoryAudit.run(
        changes: const [],
        equipment: const [
          Equipment(equipmentId: 'EX01', internalId: '1', rfid: 'DUP'),
          Equipment(equipmentId: 'EX02', internalId: '2', rfid: 'DUP, OTRO'),
        ],
      );
      final dups = audit.duplicateTags();
      expect(dups, hasLength(2)); // una fila por equipo afectado
      expect(dups.every((d) => d.tag == 'DUP'), isTrue);
      expect(dups.first.equipmentCount, 2);
    });

    test('marca el tag instalado en un equipo fuera de servicio', () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', after: 'AAA', at: DateTime.utc(2026, 6, 1)),
        ],
        equipment: const [
          Equipment(equipmentId: 'EX01', internalId: '1', rfid: 'AAA',
              status: statusOutOfService),
        ],
      );
      expect(audit.outOfServiceInstallations(), hasLength(1));
      expect(audit.report.single.isAnomalous, isTrue);
    });

    test('las remociones sin equipo NO cuentan como registro incompleto', () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', before: 'ZZZ', at: DateTime.utc(2026, 6, 1)),
          rfid(recordId: 't2', after: 'YYY', at: DateTime.utc(2026, 6, 2)),
        ],
      );
      final incomplete = audit.incompleteRecords();
      expect(incomplete, hasLength(1));
      expect(incomplete.single.operation, RfidOperation.newInstallation);
    });

    test('el resumen lista las cuatro validaciones', () {
      final audit = RfidInventoryAudit.run(changes: const []);
      expect(audit.validationSummary(), hasLength(4));
      expect(audit.validationSummary().every((v) => v.anomalies == 0), isTrue);
    });
  });

  group('series temporales', () {
    test('la tendencia mensual separa actividad, remociones y anomalias', () {
      final audit = RfidInventoryAudit.run(
        changes: [
          rfid(recordId: 't1', after: 'AAA', at: DateTime.utc(2026, 6, 1)),
          rfid(recordId: 't2', before: 'BBB', at: DateTime.utc(2026, 6, 5)),
          rfid(recordId: 't3', after: 'ZZZ', at: DateTime.utc(2026, 7, 1)),
        ],
        equipment: const [
          Equipment(equipmentId: 'EX01', internalId: '1', rfid: 'AAA'),
        ],
      );
      final trends = audit.auditTrends();
      expect(trends, hasLength(2));
      final june = trends.first;
      expect(june.activity, 2);
      expect(june.removals, 1);
      // El alta de julio no se pudo identificar: es anomalia.
      expect(trends.last.anomalies, 1);
    });
  });

  group('historial de asignaciones', () {
    test('aplana el maestro a un registro por tag y preserva el firstSeen', () {
      final seen = DateTime.utc(2026, 7, 1);
      final rows = RfidAssignment.fromEquipment(
        const [
          Equipment(equipmentId: 'EX01', internalId: '1', rfid: 'AAA, BBB'),
        ],
        seenAt: seen,
        knownFirstSeen: {'AAA': DateTime.utc(2026, 1, 1)},
      );
      expect(rows.map((r) => r.tag), ['AAA', 'BBB']);
      expect(rows.first.firstSeen, DateTime.utc(2026, 1, 1));
      expect(rows.first.lastSeen, seen);
      expect(rows.last.firstSeen, seen); // primera observacion de BBB
    });
  });
}
