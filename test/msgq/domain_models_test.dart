import 'package:adapt_mac_notifier/src/msgq/domain/change_event.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/tank.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Movement.fromNode', () {
    test('en un despacho, target es el equipo y source el tanque', () {
      final m = Movement.fromNode({
        'id': 'd1',
        'volume': 250.5,
        'recordUpdatedAt': '2026-07-01T10:00:00+00:00',
        'product': {'code': 'DSL', 'description': 'Diesel'},
        'source': {'code': 'T1', 'name': 'Tanque Norte'},
        'target': {
          'equipmentId': 'EX01',
          'description': 'Excavadora 01',
          'status': 'In Service',
        },
        'fieldUser': {'name': 'jgomez'},
      }, MovementKind.dispense);

      expect(m.kind, MovementKind.dispense);
      expect(m.volume, 250.5);
      expect(m.product, 'Diesel'); // description gana sobre code
      expect(m.tank, 'Tanque Norte'); // name gana sobre code
      expect(m.equipmentId, 'EX01');
      expect(m.equipmentDescription, 'Excavadora 01');
      expect(m.fieldUser, 'jgomez');
      expect(m.circuit, Circuit.diesel);
      // Hay equipo y no hay service truck: se sabe que NO es cisterna.
      expect(m.isServiceTruck, isFalse);
    });

    test('en una entrega, target es el tanque y no hay equipo', () {
      final m = Movement.fromNode({
        'id': 'e1',
        'volume': 20000,
        'secondaryVolume': 20150,
        'target': {'code': 'T1', 'name': 'Tanque Norte'},
      }, MovementKind.delivery);

      expect(m.tank, 'Tanque Norte');
      expect(m.equipmentId, isNull);
      expect(m.equipmentDescription, isNull);
      expect(m.secondaryVolume, 20150);
      // Ni equipo ni service truck: no se puede afirmar nada.
      expect(m.isServiceTruck, isNull);
    });

    test('las fechas se normalizan a UTC aunque lleguen con offset', () {
      final m = Movement.fromNode({
        'id': 'x',
        'recordUpdatedAt': '2026-07-01T10:00:00+11:00',
      }, MovementKind.dispense);
      expect(m.updatedAt!.isUtc, isTrue);
      expect(m.updatedAt, DateTime.utc(2026, 6, 30, 23));
    });

    test('el ida y vuelta por JSON conserva los campos', () {
      final original = Movement.fromNode({
        'id': 'd1',
        'volume': 100.0,
        'type': 'KEY_BYPASS',
        'recordUpdatedAt': '2026-07-01T10:00:00Z',
        'product': {'description': 'Diesel'},
        'source': {'code': 'T1'},
        'target': {'equipmentId': 'EX01'},
      }, MovementKind.dispense);
      final restored = Movement.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.kind, original.kind);
      expect(restored.volume, original.volume);
      expect(restored.type, original.type);
      expect(restored.product, original.product);
      expect(restored.tank, original.tank);
      expect(restored.equipmentId, original.equipmentId);
      expect(restored.updatedAt, original.updatedAt);
      expect(restored.isServiceTruck, original.isServiceTruck);
    });
  });

  group('Equipment', () {
    test('aplana grupos, departamento y une los tags RFID', () {
      final e = Equipment.fromNode({
        'id': '77',
        'equipmentId': 'EX01',
        'description': 'Excavadora 01',
        'status': 'In Service',
        'rfidTags': ['AAA', '', 'BBB'],
        'equipmentGroup': {'code': 'G1', 'description': 'Excavadoras'},
        'costCentre': {'description': 'CC Mina'},
        'isLightVehicle': false,
      });

      expect(e.internalId, '77');
      expect(e.rfid, 'AAA, BBB');
      expect(e.rfidTags, ['AAA', 'BBB']);
      expect(e.group, 'Excavadoras');
      expect(e.costCentre, 'CC Mina');
      expect(e.isInService, isTrue);
      expect(e.dimension(EquipmentDimension.group), 'Excavadoras');
    });

    test('los limites SFL salen de consumptionTanks y descartan los vacios', () {
      final limits = ConsumptionLimit.fromEquipmentNode({
        'id': '77',
        'equipmentId': 'EX01',
        'consumptionTanks': [
          {
            'id': 'ct1',
            'sfl': 7450,
            'product': {'code': 'DSL', 'description': 'Diesel'}
          },
          {
            'id': 'ct2',
            'sfl': null,
            'product': {'description': 'Coolant'}
          },
        ],
      });

      expect(limits, hasLength(1));
      expect(limits.single.sfl, 7450);
      expect(limits.single.product, 'Diesel');
      expect(limits.single.key, 'EX01|DIESEL');
    });
  });

  group('Reconciliation', () {
    test('el campo volume de la API es el error de reconciliacion', () {
      final r = Reconciliation.fromNode({
        'id': 'r1',
        'periodEnd': '2026-07-01T00:00:00Z',
        'openingStock': 10000,
        'closingStock': 9000,
        'inflowVolume': 0,
        'outflowVolume': 900,
        'volume': -100,
        'status': 'all_ok',
        'target': {'code': 'T1', 'description': 'Tanque Norte'},
        'product': {'description': 'Diesel'},
      });

      expect(r.tank, 'T1'); // el tanque se identifica por code, no por etiqueta
      expect(r.error, -100);
      expect(r.errorPctOfOutflow, closeTo(-11.11, 0.01));
      expect(r.circuit, Circuit.diesel);
    });
  });

  group('Tank', () {
    test('reconoce el tanque virtual y su padre', () {
      final t = Tank.fromNode({
        'id': '1',
        'code': 'T1A',
        'name': 'Satelite A',
        'virtual': false,
        'capacity': 50000,
        'parentTank': {'code': 'VT1'},
        'product': {'description': 'Diesel'},
      });
      expect(t.parentTank, 'VT1');
      expect(t.virtual, isFalse);
      expect(t.displayLabel, 'Satelite A');
    });
  });

  group('ChangeEvent', () {
    test('un nodo con varios atributos expande a una fila por atributo', () {
      final rows = ChangeEvent.fromNode({
        'changedAt': '2026-07-01T10:00:00Z',
        'recordType': 'EquipmentItem',
        'recordId': '77',
        'event': 'update',
        'whodunnit': 'jgomez',
        'changes': [
          {'attribute': 'equipment_status_id', 'before': '1', 'after': '2'},
          {'attribute': 'cost_centre_id', 'before': '10', 'after': '11'},
        ],
      });

      expect(rows, hasLength(2));
      expect(rows.first.statusFrom, statusInService);
      expect(rows.first.statusTo, statusOutOfService);
      expect(rows.first.isReassignment, isTrue);
      expect(rows.last.attributeLabel, 'Cost Centre');
      // La PK sintetica incluye el atributo: dos cambios del mismo evento no
      // colisionan al hacer upsert.
      expect(rows.first.eventKey, isNot(rows.last.eventKey));
    });

    test('un alta inicial no cuenta como reasignacion', () {
      final row = ChangeEvent.fromNode({
        'changedAt': '2026-07-01T10:00:00Z',
        'recordType': 'EquipmentItem',
        'recordId': '77',
        'event': 'create',
        'changes': [
          {'attribute': 'equipment_status_id', 'before': null, 'after': '1'},
        ],
      }).single;
      expect(row.isReassignment, isFalse);
      expect(row.statusFrom, '(alta)');
    });
  });
}
