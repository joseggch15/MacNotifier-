import 'package:flutter_test/flutter_test.dart';

import 'package:adapt_mac_notifier/src/core/delivery_check.dart';
import 'package:adapt_mac_notifier/src/models/delivery.dart';

void main() {
  final now = DateTime.utc(2026, 6, 11, 13, 0, 0);

  Delivery delivery(
    String id, {
    String status = 'confirmed',
    double? measured,
    double? docket,
  }) =>
      Delivery(
        id: id,
        status: status,
        volume: measured,
        secondaryVolume: docket,
        docketNumber: 'D-$id',
        collectedAt: now,
        updatedAt: now,
      );

  group('conditionsForDelivery', () {
    test('entrega normal dentro de tolerancia (0.49%) no marca', () {
      // Caso real Merian: 39.803,3 medidos vs 40.000 de guia = 0,49 % < 1 %.
      final d = delivery('1', measured: 39803.3, docket: 40000);
      expect(conditionsForDelivery(d, thresholdPct: 1.0), isEmpty);
    });

    test('varianza sobre el umbral marca highVariance', () {
      // 38.000 vs 40.000 = 5 % sobre la guia.
      final d = delivery('2', measured: 38000, docket: 40000);
      expect(conditionsForDelivery(d, thresholdPct: 1.0),
          {DeliveryCondition.highVariance});
      expect(d.deviationPct, closeTo(5.0, 0.001));
    });

    test('caso real: entrega partida (19.2 L vs 40,000 de guia) marca ambas', () {
      // La transaccion se hizo dos veces: la mitad quedo Unconfirmed con la
      // guia completa. AdaptIQ la muestra como -39.980,80 L (99,95 %).
      final d = delivery('3',
          status: 'unconfirmed', measured: 19.2, docket: 40000);
      expect(conditionsForDelivery(d, thresholdPct: 1.0), {
        DeliveryCondition.unconfirmed,
        DeliveryCondition.highVariance,
      });
      expect(d.deviationPct, closeTo(99.95, 0.01));
      expect(d.deviationL, closeTo(-39980.8, 0.01));
    });

    test('volumenes chicos en AMBOS lados no marcan varianza (ruido)', () {
      // 50 vs 60 L = 16 % pero irrelevante operativamente.
      final d = delivery('4', measured: 50, docket: 60);
      expect(conditionsForDelivery(d, thresholdPct: 1.0), isEmpty);
    });

    test('sin guia (secondaryVolume) no se puede evaluar varianza', () {
      final d = delivery('5', measured: 39000);
      expect(conditionsForDelivery(d, thresholdPct: 1.0), isEmpty);
    });

    test('unconfirmed marca aunque la varianza este bien', () {
      final d = delivery('6',
          status: 'Unconfirmed', measured: 39900, docket: 40000);
      expect(conditionsForDelivery(d, thresholdPct: 1.0),
          {DeliveryCondition.unconfirmed});
    });
  });

  group('diffDeliveryEvents (dedup incremental)', () {
    test('primera vez que se ve la entrega marcada -> evento raised', () {
      final d = delivery('10',
          status: 'unconfirmed', measured: 19.2, docket: 40000);
      final diff = diffDeliveryEvents(
          previous: const {}, fetched: [d], thresholdPct: 1.0, now: now);
      expect(diff.events.where((e) => e.active), hasLength(2));
      expect(diff.updated['10'], isNotEmpty);
    });

    test('re-traer la misma entrega sin cambios no emite nada', () {
      final d = delivery('10',
          status: 'unconfirmed', measured: 19.2, docket: 40000);
      final first = diffDeliveryEvents(
          previous: const {}, fetched: [d], thresholdPct: 1.0, now: now);
      final second = diffDeliveryEvents(
          previous: first.updated, fetched: [d], thresholdPct: 1.0, now: now);
      expect(second.events, isEmpty);
    });

    test('confirmacion: unconfirmed -> confirmed emite cleared y limpia el mapa',
        () {
      final before = delivery('11',
          status: 'unconfirmed', measured: 39900, docket: 40000);
      final first = diffDeliveryEvents(
          previous: const {}, fetched: [before], thresholdPct: 1.0, now: now);
      final after = delivery('11',
          status: 'confirmed', measured: 39900, docket: 40000);
      final second = diffDeliveryEvents(
          previous: first.updated, fetched: [after], thresholdPct: 1.0, now: now);
      expect(second.events, hasLength(1));
      expect(second.events.single.active, isFalse);
      expect(second.events.single.condition, DeliveryCondition.unconfirmed);
      expect(second.updated.containsKey('11'), isFalse);
    });

    test('entregas no re-consultadas conservan su estado en el mapa', () {
      final previous = {
        '99': {DeliveryCondition.highVariance},
      };
      final diff = diffDeliveryEvents(
          previous: previous,
          fetched: [delivery('100', measured: 39900, docket: 40000)],
          thresholdPct: 1.0,
          now: now);
      expect(diff.events, isEmpty);
      expect(diff.updated['99'], {DeliveryCondition.highVariance});
    });

    test('varianza >= 5% es critica', () {
      final d = delivery('12', measured: 30000, docket: 40000);
      final diff = diffDeliveryEvents(
          previous: const {}, fetched: [d], thresholdPct: 1.0, now: now);
      expect(diff.events.single.isCritical, isTrue);
    });
  });

  group('Delivery model', () {
    test('fromNode aplana target/product y parsea volumenes', () {
      final d = Delivery.fromNode({
        'id': '555',
        'status': 'unconfirmed',
        'type': 'MANUAL',
        'volume': 19.2,
        'uom': 'L',
        'secondaryVolume': 40000,
        'docketNumber': '0169949_3213KV_HT0937_AMAT_P1',
        'recordCollectedAt': '2026-06-11T12:33:00Z',
        'recordUpdatedAt': '2026-06-11T12:35:00Z',
        'product': {'code': 'DIESEL', 'description': 'Diesel'},
        'target': {'code': 'LFO1', 'name': 'LFO - Main Tank'},
        'adaptMac': {'code': 'MER.1'},
      });
      expect(d.tank, 'LFO - Main Tank');
      expect(d.product, 'Diesel');
      expect(d.adaptMac, 'MER.1');
      expect(d.isUnconfirmed, isTrue);
      expect(d.label, '0169949_3213KV_HT0937_AMAT_P1');
    });

    test('roundtrip toJson/fromJson conserva la auditoria', () {
      final original = Delivery.fromNode({
        'id': '556',
        'status': 'confirmed',
        'volume': 39779.6,
        'secondaryVolume': 40000,
        'recordCollectedAt': '2026-06-11T11:27:00Z',
      });
      final copy = Delivery.fromJson(original.toJson());
      expect(copy.id, original.id);
      expect(copy.volume, original.volume);
      expect(copy.secondaryVolume, original.secondaryVolume);
      expect(copy.deviationPct, original.deviationPct);
      expect(copy.collectedAt, original.collectedAt);
    });
  });
}
