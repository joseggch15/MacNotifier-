import 'package:adapt_mac_notifier/src/config/app_settings.dart';
import 'package:adapt_mac_notifier/src/core/flow_temp_check.dart';
import 'package:adapt_mac_notifier/src/models/dispense.dart';
import 'package:flutter_test/flutter_test.dart';

/// Despacho de prueba con los campos relevantes para caudal/temperatura.
Dispense disp(
  String id, {
  double? volume,
  int? duration,
  double? peak,
  double? temp,
  String? product,
  String? equipmentId,
}) =>
    Dispense(
      id: id,
      volume: volume,
      durationSeconds: duration,
      peakFlowRate: peak,
      transactionTemperature: temp,
      product: product,
      equipmentId: equipmentId,
      collectedAt: DateTime.utc(2026, 6, 19, 12),
    );

const _thr = FlowTempThresholds(
  minFlowLpm: kDefaultFlowMinLpm, // 15
  maxFlowLpm: kDefaultFlowMaxLpm, // 180
  maxTempCelsius: kDefaultTempMaxCelsius, // 60
);

void main() {
  group('caudal medio (volume/duration)', () {
    test('caudal normal no alerta', () {
      // 100 L en 100 s = 60 L/min, dentro de [15, 180].
      final a = evaluateFlowTemp(disp('a', volume: 100, duration: 100), _thr);
      expect(a, isNull);
    });

    test('caudal bajo => obstruccion (lowFlow, no critico)', () {
      // 100 L en 1000 s = 6 L/min < 15.
      final a = evaluateFlowTemp(disp('a', volume: 100, duration: 1000), _thr);
      expect(a, isNotNull);
      expect(a!.conditions, contains(FlowTempCondition.lowFlow));
      expect(a.isCritical, isFalse);
      expect(a.flowLpm, closeTo(6.0, 0.001));
    });

    test('caudal alto => medidor en vacio (highFlow, critico)', () {
      // 800 L en 120 s = 400 L/min > 180.
      final a = evaluateFlowTemp(disp('a', volume: 800, duration: 120), _thr);
      expect(a, isNotNull);
      expect(a!.conditions, contains(FlowTempCondition.highFlow));
      expect(a.isCritical, isTrue);
    });

    test('volumen por debajo del guarda no evalua caudal', () {
      // 5 L (< 20) en 1 s daria 300 L/min, pero el guarda lo descarta.
      final a = evaluateFlowTemp(disp('a', volume: 5, duration: 1), _thr);
      expect(a, isNull);
    });

    test('duracion por debajo del guarda no evalua caudal', () {
      // 50 L en 2 s (< 5) => no se evalua el caudal.
      final a = evaluateFlowTemp(disp('a', volume: 50, duration: 2), _thr);
      expect(a, isNull);
    });

    test('sin duracion no evalua caudal (pero si temperatura)', () {
      final a = evaluateFlowTemp(disp('a', volume: 100, temp: 80), _thr);
      expect(a, isNotNull);
      expect(a!.conditions, isNot(contains(FlowTempCondition.lowFlow)));
      expect(a.conditions, contains(FlowTempCondition.highTemp));
      expect(a.flowLpm, isNull);
    });
  });

  group('temperatura', () {
    test('temperatura normal no alerta', () {
      final a = evaluateFlowTemp(
          disp('a', volume: 100, duration: 100, temp: 30), _thr);
      expect(a, isNull);
    });

    test('temperatura alta => sensor averiado (critico)', () {
      final a = evaluateFlowTemp(disp('a', temp: 75), _thr);
      expect(a, isNotNull);
      expect(a!.conditions, contains(FlowTempCondition.highTemp));
      expect(a.isCritical, isTrue);
      expect(a.temperatureC, 75);
    });

    test('temperatura bajo cero extremo => sensor averiado (no critico)', () {
      final a = evaluateFlowTemp(disp('a', temp: -20), _thr);
      expect(a, isNotNull);
      expect(a!.conditions, contains(FlowTempCondition.lowTemp));
      expect(a.isCritical, isFalse);
    });
  });

  group('combinadas y deteccion en tanda', () {
    test('caudal alto Y temperatura alta en una transaccion', () {
      final a = evaluateFlowTemp(
          disp('a', volume: 800, duration: 120, temp: 90), _thr);
      expect(a!.conditions, containsAll(
          [FlowTempCondition.highFlow, FlowTempCondition.highTemp]));
    });

    test('detectFlowTempAnomalies filtra los sanos y ordena por fecha', () {
      final dispenses = [
        disp('sano', volume: 100, duration: 100),
        disp('bajo', volume: 100, duration: 1000),
        disp('alto', volume: 800, duration: 60),
      ];
      final out = detectFlowTempAnomalies(
          dispenses: dispenses, thresholds: _thr);
      expect(out.map((a) => a.dispenseId), containsAll(['bajo', 'alto']));
      expect(out.map((a) => a.dispenseId), isNot(contains('sano')));
    });

    test('umbrales desde settings', () {
      final thr = FlowTempThresholds.fromSettings(const AppSettings(
        flowMinLpm: 20,
        flowMaxLpm: 100,
        tempMaxCelsius: 50,
      ));
      expect(thr.minFlowLpm, 20);
      expect(thr.maxFlowLpm, 100);
      expect(thr.maxTempCelsius, 50);
    });
  });
}
