import 'package:adapt_mac_notifier/src/msgq/analytics/hardware_health.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/change_event.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

Movement disp(
  String id, {
  required String equipmentId,
  double? calculatedSmu,
  double? rawSmu,
  double? smu,
  required DateTime at,
  String? meterId,
  double? averageFlow,
  String? status,
}) =>
    Movement(
      id: id,
      kind: MovementKind.dispense,
      equipmentId: equipmentId,
      smuValue: smu,
      calculatedSmuValue: calculatedSmu,
      rawSmuValue: rawSmu,
      recordCollectedAt: at,
      meterId: meterId,
      averageFlowRate: averageFlow,
      equipmentStatus: status,
    );

ChangeEvent rfidSwap(String recordId, DateTime at, {String? tag}) => ChangeEvent(
      eventKey: '$changeRecordRfid:$recordId:$at:$attrRfid',
      changedAt: at,
      recordType: changeRecordRfid,
      recordId: recordId,
      attribute: attrRfid,
      before: 'OLD',
      after: tag ?? 'NEW',
    );

void main() {
  group('regresion del SMU', () {
    test('marca la caida que no se recupera', () {
      final anomalies = smuAnomaliesOf(movements: [
        disp('a', equipmentId: 'EX01', calculatedSmu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', calculatedSmu: 20,
            at: DateTime.utc(2026, 6, 5)),
        disp('c', equipmentId: 'EX01', calculatedSmu: 30,
            at: DateTime.utc(2026, 6, 9)),
      ]);
      final hit = anomalies.singleWhere(
          (a) => a.type == SmuAnomalyType.regression);
      expect(hit.equipmentId, 'EX01');
      expect(hit.referenceValue, 1000);
      expect(hit.smuValue, 20);
      expect(hit.drop, 980);
      expect(hit.days, 4);
    });

    test('un bache que se recupera NO se marca', () {
      final anomalies = smuAnomaliesOf(movements: [
        disp('a', equipmentId: 'EX01', calculatedSmu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', calculatedSmu: 990,
            at: DateTime.utc(2026, 6, 2)),
        // La siguiente lectura vuelve al nivel previo: fue ruido, no un reset.
        disp('c', equipmentId: 'EX01', calculatedSmu: 1010,
            at: DateTime.utc(2026, 6, 3)),
      ]);
      expect(anomalies.where((a) => a.type == SmuAnomalyType.regression),
          isEmpty);
    });

    test('una caida menor al minimo es ruido de medicion', () {
      final anomalies = smuAnomaliesOf(movements: [
        disp('a', equipmentId: 'EX01', calculatedSmu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', calculatedSmu: 999.5,
            at: DateTime.utc(2026, 6, 2)),
        disp('c', equipmentId: 'EX01', calculatedSmu: 999.6,
            at: DateTime.utc(2026, 6, 3)),
      ]);
      expect(anomalies, isEmpty);
    });

    test('cada reset se reporta UNA vez, no en cada despacho posterior', () {
      final anomalies = smuAnomaliesOf(movements: [
        disp('a', equipmentId: 'EX01', calculatedSmu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', calculatedSmu: 10,
            at: DateTime.utc(2026, 6, 2)),
        disp('c', equipmentId: 'EX01', calculatedSmu: 20,
            at: DateTime.utc(2026, 6, 3)),
        disp('d', equipmentId: 'EX01', calculatedSmu: 30,
            at: DateTime.utc(2026, 6, 4)),
      ]);
      expect(anomalies.where((a) => a.type == SmuAnomalyType.regression),
          hasLength(1));
    });

    test('usa smuValue cuando el tenant no expone el SMU calculado', () {
      final anomalies = smuAnomaliesOf(movements: [
        disp('a', equipmentId: 'EX01', smu: 1000, at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', smu: 10, at: DateTime.utc(2026, 6, 2)),
      ]);
      expect(anomalies.single.type, SmuAnomalyType.regression);
    });
  });

  group('estancamiento del SMU', () {
    List<Movement> stalled({required int count, required int dayStep,
        String status = statusInService}) {
      return List.generate(
        count,
        (i) => disp(
          's$i',
          equipmentId: 'EX01',
          rawSmu: 500,
          at: DateTime.utc(2026, 6, 1).add(Duration(days: i * dayStep)),
          status: status,
        ),
      );
    }

    test('marca la corrida larga de un equipo en servicio', () {
      final anomalies = smuAnomaliesOf(movements: stalled(count: 6, dayStep: 2));
      final hit = anomalies.singleWhere(
          (a) => a.type == SmuAnomalyType.stagnation);
      expect(hit.repeats, 6);
      expect(hit.days, 10);
      expect(hit.smuValue, 500);
    });

    test('pocas repeticiones no bastan', () {
      final anomalies = smuAnomaliesOf(movements: stalled(count: 4, dayStep: 5));
      expect(anomalies.where((a) => a.type == SmuAnomalyType.stagnation),
          isEmpty);
    });

    test('un lapso corto no basta aunque haya repeticiones', () {
      // 6 despachos el mismo dia: un turno, no un sensor muerto.
      final anomalies = smuAnomaliesOf(movements: stalled(count: 6, dayStep: 0));
      expect(anomalies.where((a) => a.type == SmuAnomalyType.stagnation),
          isEmpty);
    });

    test('un equipo fuera de servicio no se marca: su SMU debe estar quieto',
        () {
      final anomalies = smuAnomaliesOf(
        movements: stalled(count: 6, dayStep: 2, status: statusOutOfService),
      );
      expect(anomalies.where((a) => a.type == SmuAnomalyType.stagnation),
          isEmpty);
    });

    test('el estado vigente del maestro gana sobre el del movimiento', () {
      final anomalies = smuAnomaliesOf(
        movements: stalled(count: 6, dayStep: 2, status: statusInService),
        equipment: const [
          Equipment(equipmentId: 'EX01', status: statusOutOfService),
        ],
      );
      expect(anomalies.where((a) => a.type == SmuAnomalyType.stagnation),
          isEmpty);
    });
  });

  group('re-tagueo sospechoso', () {
    test('marca los reemplazos que exceden el umbral en la ventana movil', () {
      final alerts = retagAlertsOf(
        changes: [
          rfidSwap('77', DateTime.utc(2026, 6, 1)),
          rfidSwap('77', DateTime.utc(2026, 6, 8)),
          rfidSwap('77', DateTime.utc(2026, 6, 15)),
          rfidSwap('77', DateTime.utc(2026, 6, 22), tag: 'LAST'),
        ],
        equipment: const [
          Equipment(equipmentId: 'EX01', internalId: '77', description: 'Exc 01'),
        ],
      );
      final hit = alerts.single;
      expect(hit.equipmentId, 'EX01');
      expect(hit.changesInWindow, 4);
      expect(hit.lastTag, 'LAST');
      expect(hit.firstChange, DateTime.utc(2026, 6, 1));
    });

    test('la ventana es MOVIL: cruza el cambio de mes', () {
      final alerts = retagAlertsOf(changes: [
        rfidSwap('77', DateTime.utc(2026, 5, 28)),
        rfidSwap('77', DateTime.utc(2026, 6, 2)),
        rfidSwap('77', DateTime.utc(2026, 6, 10)),
        rfidSwap('77', DateTime.utc(2026, 6, 20)),
      ]);
      expect(alerts.single.changesInWindow, 4);
    });

    test('cambios repartidos en meses distintos no se marcan', () {
      final alerts = retagAlertsOf(changes: [
        rfidSwap('77', DateTime.utc(2026, 1, 1)),
        rfidSwap('77', DateTime.utc(2026, 3, 1)),
        rfidSwap('77', DateTime.utc(2026, 5, 1)),
        rfidSwap('77', DateTime.utc(2026, 7, 1)),
      ]);
      expect(alerts, isEmpty);
    });

    test('las altas y bajas no cuentan: solo los reemplazos', () {
      final alerts = retagAlertsOf(changes: [
        for (var i = 0; i < 5; i++)
          ChangeEvent(
            eventKey: 'k$i',
            changedAt: DateTime.utc(2026, 6, 1 + i),
            recordType: changeRecordRfid,
            recordId: '77',
            attribute: attrRfid,
            after: 'TAG$i', // alta, sin valor previo
          ),
      ]);
      expect(alerts, isEmpty);
    });

    test('un tag ya no vinculado a ningun equipo se marca sin identificar', () {
      final alerts = retagAlertsOf(changes: [
        for (var i = 0; i < 4; i++)
          rfidSwap('999', DateTime.utc(2026, 6, 1 + i * 5)),
      ]);
      expect(alerts.single.equipmentId, unidentifiedLabel);
      expect(alerts.single.internalId, '999');
    });
  });

  group('degradacion del medidor', () {
    List<Movement> flows({
      required String meterId,
      required int count,
      required double flow,
      required DateTime from,
    }) =>
        List.generate(
          count,
          (i) => disp(
            '$meterId-${from.day}-$i',
            equipmentId: 'EX01',
            meterId: meterId,
            averageFlow: flow,
            at: from.add(Duration(hours: i)),
          ),
        );

    test('marca la manguera cuyo caudal reciente cae bajo el umbral', () {
      final meters = meterHealthOf([
        ...flows(meterId: 'M1', count: 8, flow: 100,
            from: DateTime.utc(2026, 6, 1)),
        // Ventana reciente: los ultimos 7 dias del dato mas nuevo.
        ...flows(meterId: 'M1', count: 8, flow: 50,
            from: DateTime.utc(2026, 6, 28)),
      ]);
      final m = meters.single;
      expect(m.baseFlow, 100);
      expect(m.recentFlow, 50);
      expect(m.dropPct, 50);
      expect(m.degraded, isTrue);
      expect(m.metric, 'Caudal promedio');
    });

    test('una caida pequeña no se marca', () {
      final meters = meterHealthOf([
        ...flows(meterId: 'M1', count: 8, flow: 100,
            from: DateTime.utc(2026, 6, 1)),
        ...flows(meterId: 'M1', count: 8, flow: 90,
            from: DateTime.utc(2026, 6, 28)),
      ]);
      expect(meters.single.degraded, isFalse);
    });

    test('sin muestras suficientes a ambos lados no se evalua', () {
      final meters = meterHealthOf([
        ...flows(meterId: 'M1', count: 8, flow: 100,
            from: DateTime.utc(2026, 6, 1)),
        ...flows(meterId: 'M1', count: 2, flow: 10,
            from: DateTime.utc(2026, 6, 28)),
      ]);
      expect(meters, isEmpty);
    });

    test('sin datos de medidor la capacidad de auditar se reporta como ausente',
        () {
      final audit = HardwareAudit.run(movements: [
        disp('a', equipmentId: 'EX01', smu: 10, at: DateTime.utc(2026, 6, 1)),
      ]);
      expect(audit.meterDataAvailable, isFalse);
      expect(audit.meters, isEmpty);
    });
  });

  group('ordenes de trabajo', () {
    test('consolida un ticket por activo y problema con el evento reciente',
        () {
      final audit = HardwareAudit.run(movements: [
        disp('a', equipmentId: 'EX01', calculatedSmu: 1000,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', calculatedSmu: 10,
            at: DateTime.utc(2026, 6, 2)),
        disp('c', equipmentId: 'EX01', calculatedSmu: 900,
            at: DateTime.utc(2026, 6, 3)),
        disp('d', equipmentId: 'EX01', calculatedSmu: 5,
            at: DateTime.utc(2026, 6, 4)),
        disp('e', equipmentId: 'EX01', calculatedSmu: 6,
            at: DateTime.utc(2026, 6, 5)),
      ]);
      // Dos regresiones del mismo equipo -> UNA orden, la del evento reciente.
      expect(audit.kpis.smuRegressions, 2);
      final orders = audit.workOrders
          .where((o) => o.type == alertSmuRegression)
          .toList();
      expect(orders, hasLength(1));
      expect(orders.single.asset, 'EX01');
      expect(orders.single.date, DateTime.utc(2026, 6, 4));
      expect(orders.single.severity, WorkOrderSeverity.critical);
    });

    test('sin hallazgos no hay ordenes', () {
      final audit = HardwareAudit.run(movements: [
        disp('a', equipmentId: 'EX01', calculatedSmu: 100,
            at: DateTime.utc(2026, 6, 1)),
        disp('b', equipmentId: 'EX01', calculatedSmu: 110,
            at: DateTime.utc(2026, 6, 2)),
      ]);
      expect(audit.workOrders, isEmpty);
      expect(audit.kpis.workOrders, 0);
    });
  });
}
