/// Auditoria de anomalias de CAUDAL y TEMPERATURA por transaccion.
///
/// Dos senales independientes sobre cada despacho, a partir de campos de la
/// interface Movement de AdaptIQ (confirmados en el doc oficial y en MSGQ):
///
///   * CAUDAL medio (L/min) = `volume` / (`duration`/60). Demasiado BAJO sugiere
///     obstruccion/medidor sucio; demasiado ALTO, que el medidor gira en vacio
///     (posible bypass fisico). Es exactamente el cruce volumen-vs-duracion que
///     pidio el operador. Se usa la duracion REAL del movimiento (`duration`,
///     segundos), no el desfase del registro.
///   * TEMPERATURA (`transactionTemperature`, °C). Fuera de un rango razonable
///     delata un sensor termico averiado en el medidor.
///
/// Como un sobrellenado SFL, una anomalia es un EVENTO puntual: el despacho ya
/// ocurrio y sus valores no cambian, asi que el dedup es simplemente no volver
/// a notificar el mismo dispense id (one-shot).
///
/// Dart puro: testeable sin emulador.
library;

import '../config/app_settings.dart';
import '../models/dispense.dart';

/// Las anomalias que puede presentar una transaccion. Orden = severidad
/// (las criticas primero) para ordenar y elegir canal.
enum FlowTempCondition { highFlow, highTemp, lowFlow, lowTemp }

extension FlowTempConditionX on FlowTempCondition {
  /// Las anomalias "altas" son las que delatan fraude/derrame: criticas.
  bool get isCritical =>
      this == FlowTempCondition.highFlow || this == FlowTempCondition.highTemp;
}

/// Umbrales del monitor de caudal/temperatura (los valores configurables viven
/// en [AppSettings]; los guardas/limites duros son constantes del modulo).
class FlowTempThresholds {
  const FlowTempThresholds({
    required this.minFlowLpm,
    required this.maxFlowLpm,
    required this.maxTempCelsius,
    this.minTempCelsius = kFlowTempMinCelsius,
    this.minVolumeL = kFlowTempMinVolumeL,
    this.minDurationS = kFlowTempMinDurationS,
  });

  final double minFlowLpm;
  final double maxFlowLpm;
  final double maxTempCelsius;
  final double minTempCelsius;

  /// Por debajo de estos minimos el caudal calculado es ruido y NO se evalua.
  final double minVolumeL;
  final int minDurationS;

  factory FlowTempThresholds.fromSettings(AppSettings s) => FlowTempThresholds(
        minFlowLpm: s.flowMinLpm,
        maxFlowLpm: s.flowMaxLpm,
        maxTempCelsius: s.tempMaxCelsius,
      );
}

/// Una transaccion con caudal o temperatura fuera de rango.
class FlowTempAlert {
  const FlowTempAlert({
    required this.dispenseId,
    required this.conditions,
    this.equipmentId,
    this.product,
    this.lane,
    this.fieldUser,
    this.volume,
    this.flowLpm,
    this.peakFlowRate,
    this.temperatureC,
    this.collectedAt,
  });

  final String dispenseId;

  /// Anomalias detectadas (puede haber varias: caudal Y temperatura).
  final Set<FlowTempCondition> conditions;

  final String? equipmentId;
  final String? product;

  /// Punto de despacho (consola/lane), como en los no autorizados.
  final String? lane;
  final String? fieldUser;
  final double? volume;

  /// Caudal MEDIO calculado (L/min), si fue evaluable.
  final double? flowLpm;

  /// Caudal PICO reportado por la API (contexto), si lo expone.
  final double? peakFlowRate;
  final double? temperatureC;
  final DateTime? collectedAt;

  /// Hay al menos una anomalia critica (caudal alto / temperatura alta).
  bool get isCritical => conditions.any((c) => c.isCritical);

  factory FlowTempAlert.fromJson(Map<String, dynamic> json) => FlowTempAlert(
        dispenseId: (json['dispenseId'] ?? '').toString(),
        conditions: <FlowTempCondition>{
          if (json['conditions'] is List)
            for (final name in json['conditions'] as List)
              ...FlowTempCondition.values.where((c) => c.name == name),
        },
        equipmentId: json['equipmentId'] as String?,
        product: json['product'] as String?,
        lane: json['lane'] as String?,
        fieldUser: json['fieldUser'] as String?,
        volume: (json['volume'] as num?)?.toDouble(),
        flowLpm: (json['flowLpm'] as num?)?.toDouble(),
        peakFlowRate: (json['peakFlowRate'] as num?)?.toDouble(),
        temperatureC: (json['temperatureC'] as num?)?.toDouble(),
        collectedAt: json['collectedAt'] is String
            ? DateTime.tryParse(json['collectedAt'] as String)?.toUtc()
            : null,
      );

  Map<String, dynamic> toJson() => {
        'dispenseId': dispenseId,
        'conditions': [for (final c in conditions) c.name],
        'equipmentId': equipmentId,
        'product': product,
        'lane': lane,
        'fieldUser': fieldUser,
        'volume': volume,
        'flowLpm': flowLpm,
        'peakFlowRate': peakFlowRate,
        'temperatureC': temperatureC,
        'collectedAt': collectedAt?.toIso8601String(),
      };
}

/// Evalua las anomalias de UN despacho (o `null` si esta dentro de rango / sin
/// datos suficientes). Expuesta para tests; [detectFlowTempAnomalies] la corre
/// sobre una tanda.
FlowTempAlert? evaluateFlowTemp(Dispense d, FlowTempThresholds thr) {
  final conditions = <FlowTempCondition>{};

  // -- Caudal: solo si la transaccion es lo bastante grande/larga para que el
  //    cociente volumen/duracion signifique algo.
  final volume = d.volume;
  final duration = d.durationSeconds;
  double? flow;
  if (volume != null &&
      duration != null &&
      volume >= thr.minVolumeL &&
      duration >= thr.minDurationS) {
    flow = d.averageFlowLpm;
    if (flow != null) {
      if (flow < thr.minFlowLpm) conditions.add(FlowTempCondition.lowFlow);
      if (flow > thr.maxFlowLpm) conditions.add(FlowTempCondition.highFlow);
    }
  }

  // -- Temperatura: directa, sin guardas de tamaño.
  final temp = d.transactionTemperature;
  if (temp != null) {
    if (temp > thr.maxTempCelsius) conditions.add(FlowTempCondition.highTemp);
    if (temp < thr.minTempCelsius) conditions.add(FlowTempCondition.lowTemp);
  }

  if (conditions.isEmpty) return null;
  return FlowTempAlert(
    dispenseId: d.id,
    conditions: conditions,
    equipmentId: d.equipmentId,
    product: d.product,
    lane: d.adaptMacDescription ?? d.adaptMac ?? d.tank,
    fieldUser: d.fieldUser,
    volume: volume,
    flowLpm: flow,
    peakFlowRate: d.peakFlowRate,
    temperatureC: temp,
    collectedAt: d.collectedAt,
  );
}

/// Recorre los despachos y devuelve las anomalias de caudal/temperatura,
/// recientes primero.
List<FlowTempAlert> detectFlowTempAnomalies({
  required List<Dispense> dispenses,
  required FlowTempThresholds thresholds,
}) {
  final out = <FlowTempAlert>[];
  for (final d in dispenses) {
    final alert = evaluateFlowTemp(d, thresholds);
    if (alert != null) out.add(alert);
  }
  out.sort((a, b) {
    final ta = a.collectedAt ?? DateTime(0);
    final tb = b.collectedAt ?? DateTime(0);
    return tb.compareTo(ta);
  });
  return out;
}
