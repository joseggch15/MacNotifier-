import 'package:adapt_mac_notifier/src/msgq/analytics/equipment_analytics.dart';
import 'package:adapt_mac_notifier/src/msgq/analytics/grouping.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/change_event.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:flutter_test/flutter_test.dart';

Equipment eq(
  String id, {
  String? internalId,
  String? status = statusInService,
  String? group,
  String? department,
  String? costCentre,
  String? make,
  String? model,
  String? category,
  String? registrationNumber,
  String? rfid,
  bool? contractor,
  bool? light,
  String? description,
}) =>
    Equipment(
      equipmentId: id,
      internalId: internalId ?? 'i-$id',
      description: description,
      status: status,
      group: group,
      category: category,
      department: department,
      costCentre: costCentre,
      make: make,
      model: model,
      registrationNumber: registrationNumber,
      rfid: rfid,
      isContractorVehicle: contractor,
      isLightVehicle: light,
    );

ChangeEvent statusChange(
  String recordId, {
  required String? before,
  required String after,
  required DateTime at,
  String? who,
}) =>
    ChangeEvent(
      eventKey: '$changeRecordEquipment:$recordId:$at:$attrStatus',
      changedAt: at,
      recordType: changeRecordEquipment,
      recordId: recordId,
      event: before == null ? 'create' : 'update',
      whodunnit: who,
      attribute: attrStatus,
      before: before,
      after: after,
    );

ChangeEvent rfidChange(
  String recordId, {
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
      whodunnit: who,
      attribute: attrRfid,
      before: before,
      after: after,
    );

void main() {
  group('KPIs de flota', () {
    test('cuenta estados y calcula disponibilidad', () {
      final analytics = EquipmentAnalytics(equipment: [
        eq('A'),
        eq('B'),
        eq('C', status: statusOutOfService),
        eq('D', status: statusDecommissioned, contractor: true),
      ]);
      final kpis = analytics.fleetKpis()!;
      expect(kpis.total, 4);
      expect(kpis.inService, 2);
      expect(kpis.outOfService, 1);
      expect(kpis.decommissioned, 1);
      expect(kpis.availabilityPct, 50.0);
      expect(kpis.contractorVehicles, 1);
      expect(kpis.contractorPct, 25.0);
    });

    test('sin maestro devuelve null, no una flota de cero equipos', () {
      expect(const EquipmentAnalytics().fleetKpis(), isNull);
    });

    test('agrupa por dimension dejando los vacios en (sin dato)', () {
      final analytics = EquipmentAnalytics(equipment: [
        eq('A', group: 'Excavadoras'),
        eq('B', group: 'Excavadoras', status: statusOutOfService),
        eq('C'),
      ]);
      final rows = analytics.groupSummary(EquipmentDimension.group);
      expect(rows.first.key, 'Excavadoras');
      expect(rows.first.total, 2);
      expect(rows.first.availabilityPct, 50.0);
      expect(rows.last.key, noDataLabel);
    });
  });

  group('completitud del maestro', () {
    test('mide el porcentaje de equipos con cada campo cargado', () {
      final analytics = EquipmentAnalytics(equipment: [
        eq('A', category: 'Heavy', make: 'CAT', rfid: 'TAG1'),
        eq('B'),
      ]);
      final rows = analytics.dataCompleteness();
      final category = rows.firstWhere((r) => r.field == 'category');
      expect(category.filled, 1);
      expect(category.missing, 1);
      expect(category.completenessPct, 50.0);
      // Un campo que nadie tiene se reporta al 0%, no se omite.
      final model = rows.firstWhere((r) => r.field == 'model');
      expect(model.completenessPct, 0.0);
    });
  });

  group('transiciones de estado', () {
    final analytics = EquipmentAnalytics(
      equipment: [eq('EX01', internalId: '77', group: 'Excavadoras')],
      changes: [
        // Alta inicial: no es una transicion.
        statusChange('77', before: null, after: '1', at: DateTime.utc(2026, 1, 1)),
        statusChange('77', before: '1', after: '2', at: DateTime.utc(2026, 3, 1)),
        statusChange('77', before: '2', after: '1', at: DateTime.utc(2026, 3, 11)),
        statusChange('77', before: '1', after: '2', at: DateTime.utc(2026, 4, 10)),
      ],
    );

    test('descarta el alta inicial y resuelve los ids a nombres', () {
      final rows = analytics.statusTransitions();
      expect(rows, hasLength(3));
      expect(rows.first.changedAt, DateTime.utc(2026, 4, 10)); // mas reciente
      expect(rows.first.from, statusInService);
      expect(rows.first.to, statusOutOfService);
      // Enlaza con el maestro por el id INTERNO, no por el visible.
      expect(rows.first.equipmentId, 'EX01');
      expect(rows.first.group, 'Excavadoras');
    });

    test('el resumen agrupa por tipo de transicion', () {
      final rows =
          analytics.statusTransitionSummary(analytics.statusTransitions());
      final inToOut = rows.firstWhere(
          (r) => r.transition == '$statusInService -> $statusOutOfService');
      expect(inToOut.times, 2);
    });

    test('el tiempo en servicio mide de la entrada a la siguiente salida', () {
      final rows = analytics.timeInService(analytics.statusTransitions());
      final row = rows.single;
      expect(row.equipmentId, 'EX01');
      expect(row.exitsToOutOfService, 2);
      // Solo el tramo 11/03 -> 10/04 tiene entrada previa observada: 30 dias.
      // La primera salida (01/03) no tiene un In previo dentro del rango.
      expect(row.avgDaysInService, 30.0);
    });

    test('la serie In->Out agrupa por mes', () {
      final series = analytics.inToOutOverTime(
        analytics.statusTransitions(),
        period: AnalyticsPeriod.monthly,
      );
      expect(series, hasLength(2));
      expect(series.map((p) => p.count), [1, 1]);
    });

    test('agrupa transiciones por dimension del equipo', () {
      final rows = analytics.transitionsByDimension(
        analytics.statusTransitions(),
        EquipmentDimension.group,
      );
      expect(rows.single.key, 'Excavadoras');
      expect(rows.single.inToOut, 2);
      expect(rows.single.outToIn, 1);
    });
  });

  group('RFID', () {
    final analytics = EquipmentAnalytics(changes: [
      rfidChange('t1', after: 'AAA', at: DateTime.utc(2026, 1, 5)),
      rfidChange('t1',
          before: 'AAA', after: 'BBB', at: DateTime.utc(2026, 2, 5)),
      rfidChange('t2', before: 'CCC', at: DateTime.utc(2026, 2, 20)),
    ]);

    test('clasifica alta, cambio y remocion', () {
      final summary = analytics.rfidChangeSummary();
      expect(summary.events, 3);
      expect(summary.assigned, 1);
      expect(summary.changed, 1);
      expect(summary.removed, 1);
      expect(summary.tagRecords, 2);
    });

    test('el churn ordena por cantidad de eventos del registro de tag', () {
      final rows = analytics.rfidChurnByTag();
      expect(rows.first.recordId, 't1');
      expect(rows.first.events, 2);
      expect(rows.first.lastChange, DateTime.utc(2026, 2, 5));
    });

    test('la serie mensual desglosa por tipo', () {
      final series =
          analytics.rfidChangesOverTime(period: AnalyticsPeriod.monthly);
      expect(series, hasLength(2));
      expect(series.last.changed, 1);
      expect(series.last.removed, 1);
      expect(series.last.total, 2);
    });
  });

  group('auditoria', () {
    test('el resumen de atributos ignora las altas iniciales', () {
      final analytics = EquipmentAnalytics(changes: [
        statusChange('9', before: null, after: '1', at: DateTime.utc(2026, 1, 1)),
        statusChange('9', before: '1', after: '2', at: DateTime.utc(2026, 2, 1)),
      ]);
      final rows = analytics.attributeChangeSummary();
      expect(rows.single.attribute, attrStatus);
      expect(rows.single.label, 'Estado');
      expect(rows.single.changes, 1);
      expect(rows.single.equipmentCount, 1);
    });

    test('agrupa los cambios por usuario y marca los sin autor', () {
      final analytics = EquipmentAnalytics(changes: [
        statusChange('9', before: '1', after: '2',
            at: DateTime.utc(2026, 2, 1), who: 'jgomez'),
        rfidChange('t1', after: 'AAA', at: DateTime.utc(2026, 2, 2)),
      ]);
      final rows = analytics.auditByUser();
      final jgomez = rows.firstWhere((r) => r.user == 'jgomez');
      expect(jgomez.equipmentChanges, 1);
      expect(jgomez.rfidChanges, 0);
      expect(rows.any((r) => r.user == '(desconocido)'), isTrue);
    });

    test('el audit log de un equipo traduce el id de estado a su nombre', () {
      final analytics = EquipmentAnalytics(changes: [
        statusChange('9', before: '1', after: '2', at: DateTime.utc(2026, 2, 1)),
      ]);
      final row = analytics.equipmentAuditLog('9').single;
      expect(row.attributeLabel, 'Estado');
      expect(row.from, statusInService);
      expect(row.to, statusOutOfService);
    });
  });
}
