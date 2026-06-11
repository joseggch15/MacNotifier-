/// Auditoria de despachos contra el Safe Fill Level (SFL).
///
/// Port de `msgq/core/sfl_audit.py::exceedances`: el SFL (de
/// `EquipmentItem.consumptionTanks`) es el volumen maximo seguro a despachar a
/// un equipo en UN repostaje, por producto. Despachar mas es un
/// **sobrellenado** — la alarma "Equipment Overfill" que AdaptIQ muestra en
/// Alerts/Alarms ("Equipment HTK0826 ... overfill by 93.20 L"). La API
/// customer-facing NO expone esas alarmas, asi que se reconstruyen aqui con la
/// misma regla: `volume > sfl * (1 + tolerancia)` cruzando por
/// (equipmentId, PRODUCTO_MAYUS).
///
/// A diferencia de consolas/entregas, un sobrellenado es un EVENTO puntual (el
/// despacho ya ocurrio, no "se recupera"): el dedup es simplemente no volver a
/// notificar el mismo dispense id.
///
/// Dart puro: testeable sin emulador.
library;

import '../config/app_settings.dart';
import '../models/dispense.dart';

/// Llave del mapa de limites: misma normalizacion que `_norm` de MSGQ.
String sflKey(String equipmentId, String? product) =>
    '${equipmentId.trim()}|${normProduct(product)}';

/// Un despacho que supero el SFL del equipo para ese producto.
class OverfillAlert {
  const OverfillAlert({
    required this.dispenseId,
    required this.equipmentId,
    this.equipmentDescription,
    this.product,
    required this.volume,
    required this.sfl,
    this.tank,
    this.fieldUser,
    this.adaptMac,
    this.collectedAt,
  });

  final String dispenseId;
  final String equipmentId;
  final String? equipmentDescription;
  final String? product;
  final double volume;
  final double sfl;
  final String? tank;
  final String? fieldUser;
  final String? adaptMac;
  final DateTime? collectedAt;

  /// Litros por encima del nivel seguro (lo que AdaptIQ reporta como
  /// "overfill by N L").
  double get excess => volume - sfl;

  double get excessPct => sfl > 0 ? excess / sfl * 100.0 : 0.0;

  /// Un exceso grande ya no es ruido del medidor: derrame casi seguro.
  bool get isCritical => excessPct >= kSflCriticalExcessPct;

  factory OverfillAlert.fromJson(Map<String, dynamic> json) {
    return OverfillAlert(
      dispenseId: (json['dispenseId'] ?? '').toString(),
      equipmentId: (json['equipmentId'] ?? '').toString(),
      equipmentDescription: json['equipmentDescription'] as String?,
      product: json['product'] as String?,
      volume: (json['volume'] as num?)?.toDouble() ?? 0,
      sfl: (json['sfl'] as num?)?.toDouble() ?? 0,
      tank: json['tank'] as String?,
      fieldUser: json['fieldUser'] as String?,
      adaptMac: json['adaptMac'] as String?,
      collectedAt: json['collectedAt'] is String
          ? DateTime.tryParse(json['collectedAt'] as String)?.toUtc()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'dispenseId': dispenseId,
        'equipmentId': equipmentId,
        'equipmentDescription': equipmentDescription,
        'product': product,
        'volume': volume,
        'sfl': sfl,
        'tank': tank,
        'fieldUser': fieldUser,
        'adaptMac': adaptMac,
        'collectedAt': collectedAt?.toIso8601String(),
      };
}

/// Cruza los despachos contra el mapa de limites {sflKey: sfl} y devuelve los
/// sobrellenados. Solo se evaluan despachos con equipo, producto y volumen, y
/// con SFL conocido para esa pareja (igual que MSGQ: merge interno).
List<OverfillAlert> detectOverfills({
  required List<Dispense> dispenses,
  required Map<String, double> limits,
  double tolerancePct = kSflTolerancePct,
}) {
  final out = <OverfillAlert>[];
  for (final d in dispenses) {
    final eid = d.equipmentId?.trim();
    final volume = d.volume;
    if (eid == null || eid.isEmpty || volume == null) continue;
    final sfl = limits[sflKey(eid, d.product)];
    if (sfl == null || sfl <= 0) continue;
    if (volume > sfl * (1.0 + tolerancePct)) {
      out.add(OverfillAlert(
        dispenseId: d.id,
        equipmentId: eid,
        equipmentDescription: d.equipmentDescription,
        product: d.product,
        volume: volume,
        sfl: sfl,
        tank: d.tank,
        fieldUser: d.fieldUser,
        adaptMac: d.adaptMac,
        collectedAt: d.collectedAt,
      ));
    }
  }
  out.sort((a, b) {
    final ta = a.collectedAt ?? DateTime(0);
    final tb = b.collectedAt ?? DateTime(0);
    return tb.compareTo(ta); // recientes primero
  });
  return out;
}
