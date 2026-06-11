import 'package:flutter_test/flutter_test.dart';

import 'package:adapt_mac_notifier/src/config/app_settings.dart';
import 'package:adapt_mac_notifier/src/core/sfl_check.dart';
import 'package:adapt_mac_notifier/src/models/dispense.dart';
import 'package:adapt_mac_notifier/src/reports/report_service.dart';

void main() {
  Dispense dispense(
    String id, {
    String? equipmentId,
    String? product,
    double? volume,
  }) =>
      Dispense(
        id: id,
        equipmentId: equipmentId,
        product: product,
        volume: volume,
        collectedAt: DateTime.utc(2026, 6, 11, 8),
      );

  group('detectOverfills (port de sfl_audit.exceedances)', () {
    final limits = {
      sflKey('HTK0826', 'Diesel'): 700.0,
      sflKey('DZT0752', 'Diesel'): 1500.0,
    };

    test('volumen dentro del SFL no marca', () {
      final out = detectOverfills(
        dispenses: [
          dispense('1', equipmentId: 'HTK0826', product: 'Diesel', volume: 699)
        ],
        limits: limits,
      );
      expect(out, isEmpty);
    });

    test('la tolerancia del 2% filtra el ruido de medicion', () {
      // 700 * 1.02 = 714: justo en el limite tolerado no marca…
      final under = detectOverfills(
        dispenses: [
          dispense('1', equipmentId: 'HTK0826', product: 'Diesel', volume: 714)
        ],
        limits: limits,
      );
      expect(under, isEmpty);
      // …pero por encima si, y el exceso reportado es sobre el SFL real.
      final over = detectOverfills(
        dispenses: [
          dispense('2',
              equipmentId: 'HTK0826', product: 'Diesel', volume: 793.2)
        ],
        limits: limits,
      );
      expect(over, hasLength(1));
      expect(over.single.excess, closeTo(93.2, 0.01));
    });

    test('el cruce por producto es case-insensitive (como _norm de MSGQ)', () {
      final out = detectOverfills(
        dispenses: [
          dispense('1', equipmentId: 'HTK0826', product: 'DIESEL', volume: 800)
        ],
        limits: limits,
      );
      expect(out, hasLength(1));
    });

    test('sin SFL conocido para (equipo, producto) no se evalua', () {
      final out = detectOverfills(
        dispenses: [
          dispense('1', equipmentId: 'XX999', product: 'Diesel', volume: 9999),
          dispense('2', equipmentId: 'HTK0826', product: 'Coolant', volume: 999),
          dispense('3', product: 'Diesel', volume: 9999), // sin equipo
        ],
        limits: limits,
      );
      expect(out, isEmpty);
    });

    test('isCritical cuando el exceso supera el porcentaje critico', () {
      final out = detectOverfills(
        dispenses: [
          dispense('1', equipmentId: 'HTK0826', product: 'Diesel', volume: 720),
          dispense('2', equipmentId: 'HTK0826', product: 'Diesel', volume: 800),
        ],
        limits: limits,
      );
      expect(out, hasLength(2));
      final byId = {for (final o in out) o.dispenseId: o};
      expect(byId['1']!.isCritical, isFalse); // +2.9%
      expect(byId['2']!.isCritical, isTrue); // +14.3%
    });
  });

  group('silenciado por producto', () {
    test('normProduct normaliza para el cruce', () {
      expect(normProduct('  Diesel '), 'DIESEL');
      expect(normProduct(null), '');
    });

    test('isSflProductMuted / isDeliveryProductMuted', () {
      const s = AppSettings(
        mutedSflProducts: ['COOLANT'],
        mutedDeliveryProducts: ['HYDRAULIC OIL'],
      );
      expect(s.isSflProductMuted('Coolant'), isTrue);
      expect(s.isSflProductMuted('Diesel'), isFalse);
      expect(s.isDeliveryProductMuted('hydraulic oil'), isTrue);
      expect(s.isDeliveryProductMuted('Diesel'), isFalse);
    });

    test('roundtrip OverfillAlert toJson/fromJson', () {
      final original = detectOverfills(
        dispenses: [
          dispense('99',
              equipmentId: 'HTK0826', product: 'Diesel', volume: 793.2)
        ],
        limits: {sflKey('HTK0826', 'Diesel'): 700.0},
      ).single;
      final copy = OverfillAlert.fromJson(original.toJson());
      expect(copy.dispenseId, original.dispenseId);
      expect(copy.volume, original.volume);
      expect(copy.sfl, original.sfl);
      expect(copy.excess, closeTo(original.excess, 0.001));
      expect(copy.collectedAt, original.collectedAt);
    });
  });

  group('reportes', () {
    test('csvEscape cumple RFC 4180', () {
      expect(csvEscape('simple'), 'simple');
      expect(csvEscape('con,coma'), '"con,coma"');
      expect(csvEscape('con "comillas"'), '"con ""comillas"""');
      expect(csvEscape(null), '');
    });

    test('buildCsv arma filas CRLF', () {
      final csv = buildCsv([
        ['a', 'b'],
        ['1,5', 'x'],
      ]);
      expect(csv, 'a,b\r\n"1,5",x');
    });

    test('rangos de periodo en hora local', () {
      final now = DateTime(2026, 6, 11, 15, 30);
      final daily = ReportPeriod.daily.range(now);
      expect(daily.start, DateTime(2026, 6, 11).toUtc());
      final weekly = ReportPeriod.weekly.range(now);
      expect(weekly.start, DateTime(2026, 6, 5).toUtc());
      final monthly = ReportPeriod.monthly.range(now);
      expect(monthly.start, DateTime(2026, 6, 1).toUtc());
      final yearly = ReportPeriod.yearly.range(now);
      expect(yearly.start, DateTime(2026, 1, 1).toUtc());
    });
  });
}
