/// Un evento del log de auditoria del FMS — port de `change_events_to_df`
/// (`CHANGE_EVENT_COLS` de MSGQ).
///
/// La API entrega un `ChangeEvent` con un diff de VARIOS atributos; aqui se
/// aplana a UNA fila por atributo cambiado, que es la forma en la que la
/// analitica lo consulta ("cuantas veces cambio el cost centre", "quien movio
/// este equipo a Out of Service").
///
/// [eventKey] es la PK sintetica que hace idempotente el upsert al re-descargar
/// ventanas solapadas: el mismo cambio replicado dos veces no se duplica.
///
/// Dart puro y null-safe.
library;

import 'fms_vocabulary.dart';
import 'node_parsing.dart';

class ChangeEvent {
  const ChangeEvent({
    required this.eventKey,
    this.changedAt,
    this.recordType,
    this.recordId,
    this.event,
    this.whodunnit,
    this.attribute,
    this.before,
    this.after,
  });

  /// `recordType:recordId:changedAt:attribute`.
  final String eventKey;

  final DateTime? changedAt;

  /// `EquipmentItem` o `EquipmentRfid`.
  final String? recordType;

  /// Id INTERNO del registro afectado — cruza con [Equipment.internalId], no
  /// con el `equipmentId` visible.
  final String? recordId;

  /// `create` / `update` / `destroy`.
  final String? event;

  /// Usuario que hizo el cambio (`null` = proceso automatico o no informado).
  final String? whodunnit;

  final String? attribute;
  final String? before;
  final String? after;

  bool get isEquipmentRecord => recordType == changeRecordEquipment;
  bool get isRfidRecord => recordType == changeRecordRfid;

  /// Cambio REAL de un valor existente, no el alta inicial (`before` vacio).
  /// Contar las altas como "reasignaciones" inflaba los rankings de cambios.
  bool get isReassignment => before != null;

  /// Etiqueta legible del atributo cambiado.
  String get attributeLabel => attrLabel(attribute);

  /// Estado de origen / destino, ya resueltos de id a nombre. Solo tienen
  /// sentido cuando [attribute] es `equipment_status_id`.
  String get statusFrom => statusName(before);
  String get statusTo => statusName(after);

  /// Clasificacion del evento de RFID, como `equipment_analytics.rfid_changes`:
  /// antes y despues -> Cambiado; solo despues -> Asignado; solo antes ->
  /// Removido.
  RfidChangeType get rfidChangeType {
    if (before != null && after != null) return RfidChangeType.changed;
    if (after != null) return RfidChangeType.assigned;
    return RfidChangeType.removed;
  }

  /// Un nodo `ChangeEvent` de la API expande a N filas (una por atributo).
  static List<ChangeEvent> fromNode(Map<String, dynamic> node) {
    final changedAt = node['changedAt'];
    final recordType = asText(node['recordType']);
    final recordId = asText(node['recordId']);
    final event = asText(node['event']);
    final whodunnit = asText(node['whodunnit']);
    final changes = node['changes'];
    if (changes is! List) return const [];
    return changes.whereType<Map<String, dynamic>>().map((ch) {
      final attribute = asText(ch['attribute']);
      return ChangeEvent(
        eventKey: '$recordType:$recordId:$changedAt:$attribute',
        changedAt: asDate(changedAt),
        recordType: recordType,
        recordId: recordId,
        event: event,
        whodunnit: whodunnit,
        attribute: attribute,
        before: asText(ch['before']),
        after: asText(ch['after']),
      );
    }).toList(growable: false);
  }

  factory ChangeEvent.fromJson(Map<String, dynamic> json) => ChangeEvent(
        eventKey: (json['event_key'] ?? '').toString(),
        changedAt: asDate(json['changed_at']),
        recordType: asText(json['record_type']),
        recordId: asText(json['record_id']),
        event: asText(json['event']),
        whodunnit: asText(json['whodunnit']),
        attribute: asText(json['attribute']),
        before: asText(json['before']),
        after: asText(json['after']),
      );

  Map<String, dynamic> toJson() => {
        'event_key': eventKey,
        'changed_at': isoOrNull(changedAt),
        'record_type': recordType,
        'record_id': recordId,
        'event': event,
        'whodunnit': whodunnit,
        'attribute': attribute,
        'before': before,
        'after': after,
      };

  @override
  String toString() => 'ChangeEvent($recordType/$attribute @ $changedAt)';
}

/// Tipo de evento de tag RFID a nivel de flota.
///
/// El log NO enlaza el tag con su equipo (`EquipmentRfid` no trae FK), asi que
/// estos eventos son de flota / registro-de-tag, no por equipo.
enum RfidChangeType {
  assigned('Asignado'),
  changed('Cambiado'),
  removed('Removido');

  const RfidChangeType(this.label);

  final String label;
}
