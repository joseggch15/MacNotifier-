/// Auditoria de ENTREGAS (deliveries) y deteccion de transiciones.
///
/// Dos condiciones, derivadas del flujo real que el auditor revisa en AdaptIQ:
///
///   * `unconfirmed`  — la entrega quedo SIN CONFIRMAR (p. ej. una entrega
///     partida en dos por una segunda transaccion pedida en campo: la mitad
///     queda Unconfirmed y nadie se entera si no abre AdaptIQ).
///   * `highVariance` — la diferencia medidor-vs-guia supera el umbral
///     (port de msgq/core/volume_deviation.py, con dos ajustes documentados
///     en `Delivery.deviationPct` y `kDeliveryMinVolumeL`).
///
/// El dedup es el mismo patron que las consolas: se persiste el conjunto de
/// condiciones notificadas POR ENTREGA (id) y solo las transiciones emiten
/// eventos. Como las entregas se consultan incrementalmente (updatedFrom),
/// re-traer una entrega sin cambios no genera nada.
///
/// Dart puro: testeable sin emulador.
library;

import '../config/app_settings.dart';
import '../models/delivery.dart';

enum DeliveryCondition { highVariance, unconfirmed }

class DeliveryEvent {
  const DeliveryEvent({
    required this.delivery,
    required this.condition,
    required this.active,
    required this.at,
  });

  final Delivery delivery;
  final DeliveryCondition condition;
  final bool active;
  final DateTime at;

  /// Una varianza >= kDeliveryCriticalPct ya no es ruido de medicion: hay una
  /// discrepancia grande de volumen/dinero con el proveedor.
  bool get isCritical =>
      condition == DeliveryCondition.highVariance &&
      (delivery.deviationPct ?? 0) >= kDeliveryCriticalPct;
}

/// Condiciones activas de UNA entrega.
Set<DeliveryCondition> conditionsForDelivery(
  Delivery d, {
  required double thresholdPct,
}) {
  final out = <DeliveryCondition>{};
  if (d.isUnconfirmed) out.add(DeliveryCondition.unconfirmed);
  final pct = d.deviationPct;
  final measured = d.volume;
  final field = d.secondaryVolume;
  if (pct != null &&
      measured != null &&
      field != null &&
      measured > 0 &&
      field > 0 &&
      // Basta que UNO de los volumenes sea relevante (ver kDeliveryMinVolumeL).
      (measured >= kDeliveryMinVolumeL || field >= kDeliveryMinVolumeL) &&
      pct >= thresholdPct) {
    out.add(DeliveryCondition.highVariance);
  }
  return out;
}

/// Compara las entregas RECIEN consultadas contra las condiciones ya
/// notificadas y devuelve los eventos + el mapa actualizado para persistir.
///
/// Solo se tocan las entradas de las entregas presentes en `fetched` (las
/// demas no cambiaron: la consulta es incremental). Las entradas cuyo conjunto
/// queda vacio se eliminan del mapa — si la entrega vuelve a degradarse mas
/// adelante, volvera a alertar, que es lo correcto.
({List<DeliveryEvent> events, Map<String, Set<DeliveryCondition>> updated})
    diffDeliveryEvents({
  required Map<String, Set<DeliveryCondition>> previous,
  required List<Delivery> fetched,
  required double thresholdPct,
  required DateTime now,
}) {
  final updated = {
    for (final e in previous.entries) e.key: Set<DeliveryCondition>.of(e.value),
  };
  final events = <DeliveryEvent>[];
  for (final d in fetched) {
    final was = previous[d.id] ?? const <DeliveryCondition>{};
    final isNow = conditionsForDelivery(d, thresholdPct: thresholdPct);
    for (final c in isNow.difference(was)) {
      events.add(DeliveryEvent(delivery: d, condition: c, active: true, at: now));
    }
    for (final c in was.difference(isNow)) {
      events.add(DeliveryEvent(delivery: d, condition: c, active: false, at: now));
    }
    if (isNow.isEmpty) {
      updated.remove(d.id);
    } else {
      updated[d.id] = isNow;
    }
  }
  events.sort((a, b) {
    if (a.active != b.active) return a.active ? -1 : 1;
    if (a.isCritical != b.isCritical) return a.isCritical ? -1 : 1;
    return a.condition.index.compareTo(b.condition.index);
  });
  return (events: events, updated: updated);
}
