/// Un Equipment Item del maestro de flota — port de `flatten_equipment` +
/// `EQUIPMENT_COLS` de MSGQ, y su Safe Fill Level por producto.
///
/// Diferencia deliberada con el esquema de escritorio: MSGQ declara tambien
/// `product`, `is_pod`, `is_service_truck`, `site`, `zone` y el trio `smu_*`,
/// que `flatten_equipment` deja SIEMPRE en NA porque no existen en el tipo
/// `EquipmentItem` (el SMU viaja por-movimiento, no en el maestro). Alli tienen
/// sentido para poder recibir un CSV de inventario; aqui no hay importador CSV,
/// asi que no se declaran campos que nunca podrian poblarse.
///
/// Dart puro y null-safe.
library;

import 'fms_vocabulary.dart';
import 'node_parsing.dart';

class Equipment {
  const Equipment({
    this.equipmentId,
    this.internalId,
    this.fieldId,
    this.description,
    this.registrationNumber,
    this.group,
    this.category,
    this.status,
    this.make,
    this.model,
    this.isLightVehicle,
    this.isContractorVehicle,
    this.rfid,
    this.department,
    this.costCentre,
    this.projectCode,
    this.serviceInterval,
    this.serviceIntervalType,
    this.dispenseLimited,
    this.dispenseLimitPeriod,
    this.erpReference,
    this.orderNumber,
    this.orderItem,
    this.sapMeasurementPoint,
    this.updatedAt,
  });

  /// Codigo de flota visible (el que viaja en cada despacho). Clave de cruce
  /// con los movimientos.
  final String? equipmentId;

  /// Id interno del FMS. Clave de cruce con el log de auditoria
  /// (`ChangeEvent.recordId`), que NO usa el `equipmentId` visible.
  final String? internalId;

  final String? fieldId;
  final String? description;
  final String? registrationNumber;
  final String? group;
  final String? category;

  /// Estado operativo: 'In Service' / 'Out of Service' / 'Decommissioned'.
  final String? status;

  final String? make;
  final String? model;
  final bool? isLightVehicle;
  final bool? isContractorVehicle;

  /// Tags RFID unidos por ", " (el maestro los expone como lista).
  final String? rfid;

  final String? department;
  final String? costCentre;
  final String? projectCode;
  final double? serviceInterval;
  final String? serviceIntervalType;
  final bool? dispenseLimited;
  final String? dispenseLimitPeriod;
  final String? erpReference;
  final String? orderNumber;
  final String? orderItem;
  final String? sapMeasurementPoint;

  /// `lastChangedAt` del maestro.
  final DateTime? updatedAt;

  bool get isInService => status?.trim() == statusInService;
  bool get isOutOfService => status?.trim() == statusOutOfService;
  bool get isDecommissioned => status?.trim() == statusDecommissioned;

  /// Tags individuales (el maestro los guarda unidos por ", ").
  List<String> get rfidTags => (rfid ?? '')
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);

  /// Valor de una dimension de agrupacion, por su nombre canonico. Permite que
  /// la UI ofrezca "agrupar por..." sin un `switch` por pantalla.
  String? dimension(EquipmentDimension dim) => switch (dim) {
        EquipmentDimension.group => group,
        EquipmentDimension.category => category,
        EquipmentDimension.department => department,
        EquipmentDimension.costCentre => costCentre,
        EquipmentDimension.make => make,
      };

  /// Presencia del campo de completitud [field] (`completenessFields`).
  bool hasCompletenessField(String field) => switch (field) {
        'registration_number' => registrationNumber != null,
        'category' => category != null,
        'group' => group != null,
        'make' => make != null,
        'model' => model != null,
        'department' => department != null,
        'cost_centre' => costCentre != null,
        'rfid' => rfid != null,
        _ => false,
      };

  factory Equipment.fromNode(Map<String, dynamic> node) => Equipment(
        equipmentId: asText(node['equipmentId']),
        internalId: asText(node['id']),
        fieldId: asText(node['fieldId']),
        description: asText(node['description']),
        registrationNumber: asText(node['fieldDescription']),
        group: label(node['equipmentGroup']),
        category: label(node['equipmentCategory']),
        status: asText(node['status']),
        make: asText(node['make']),
        model: asText(node['model']),
        isLightVehicle: asBool(node['isLightVehicle']),
        isContractorVehicle: asBool(node['isContractorVehicle']),
        rfid: joinRfids(node['rfidTags']),
        department: label(node['department']),
        costCentre: label(node['costCentre']),
        projectCode: asText(node['projectCode']),
        serviceInterval: asDouble(node['serviceInterval']),
        serviceIntervalType: asText(node['serviceIntervalType']),
        dispenseLimited: asBool(node['dispenseLimited']),
        dispenseLimitPeriod: asText(node['dispenseLimitPeriod']),
        erpReference: asText(node['erpReference']),
        orderNumber: asText(node['orderNumber']),
        orderItem: asText(node['orderItem']),
        sapMeasurementPoint: asText(node['sap']),
        updatedAt: asDate(node['lastChangedAt']),
      );

  factory Equipment.fromJson(Map<String, dynamic> json) => Equipment(
        equipmentId: asText(json['equipment_id']),
        internalId: asText(json['internal_id']),
        fieldId: asText(json['field_id']),
        description: asText(json['description']),
        registrationNumber: asText(json['registration_number']),
        group: asText(json['group']),
        category: asText(json['category']),
        status: asText(json['status']),
        make: asText(json['make']),
        model: asText(json['model']),
        isLightVehicle: asBool(json['is_light_vehicle']),
        isContractorVehicle: asBool(json['is_contractor_vehicle']),
        rfid: asText(json['rfid']),
        department: asText(json['department']),
        costCentre: asText(json['cost_centre']),
        projectCode: asText(json['project_code']),
        serviceInterval: asDouble(json['service_interval']),
        serviceIntervalType: asText(json['service_interval_type']),
        dispenseLimited: asBool(json['dispense_limited']),
        dispenseLimitPeriod: asText(json['dispense_limit_period']),
        erpReference: asText(json['erp_reference']),
        orderNumber: asText(json['order_number']),
        orderItem: asText(json['order_item']),
        sapMeasurementPoint: asText(json['sap_measurement_point']),
        updatedAt: asDate(json['updated_at']),
      );

  Map<String, dynamic> toJson() => {
        'equipment_id': equipmentId,
        'internal_id': internalId,
        'field_id': fieldId,
        'description': description,
        'registration_number': registrationNumber,
        'group': group,
        'category': category,
        'status': status,
        'make': make,
        'model': model,
        'is_light_vehicle': isLightVehicle,
        'is_contractor_vehicle': isContractorVehicle,
        'rfid': rfid,
        'department': department,
        'cost_centre': costCentre,
        'project_code': projectCode,
        'service_interval': serviceInterval,
        'service_interval_type': serviceIntervalType,
        'dispense_limited': dispenseLimited,
        'dispense_limit_period': dispenseLimitPeriod,
        'erp_reference': erpReference,
        'order_number': orderNumber,
        'order_item': orderItem,
        'sap_measurement_point': sapMeasurementPoint,
        'updated_at': isoOrNull(updatedAt),
      };

  @override
  String toString() => 'Equipment($equipmentId, $status)';
}

/// Dimensiones por las que se agrupa la flota en los resumenes.
enum EquipmentDimension {
  group('Grupo', 'group'),
  category('Categoria', 'category'),
  department('Departamento', 'department'),
  costCentre('Cost Centre', 'cost_centre'),
  make('Marca', 'make');

  const EquipmentDimension(this.label, this.column);

  /// Etiqueta de la columna en los reportes (misma que usa MSGQ).
  final String label;

  /// Nombre canonico de la columna en la replica.
  final String column;
}

/// Safe Fill Level de un equipo para UN producto — port de
/// `consumption_limits_to_df` (`EquipmentItem.consumptionTanks`).
///
/// Es el volumen maximo seguro a despachar en un solo repostaje. `product` es
/// la etiqueta (`description`), la misma que [Movement.product], para poder
/// cruzarlos.
class ConsumptionLimit {
  const ConsumptionLimit({
    required this.id,
    this.equipmentId,
    this.internalId,
    this.product,
    this.productCode,
    required this.sfl,
  });

  /// Id del `ConsumptionTank` (PK en la replica).
  final String id;
  final String? equipmentId;
  final String? internalId;
  final String? product;
  final String? productCode;

  /// Safe Fill Level en litros.
  final double sfl;

  /// Clave de cruce con un despacho: `equipmentId|PRODUCTO_MAYUS`.
  String get key => limitKey(equipmentId, product);

  /// Aplana los `consumptionTanks` de un nodo de equipo. Descarta los tanques
  /// sin `sfl`: sin limite definido no hay nada que auditar.
  static List<ConsumptionLimit> fromEquipmentNode(Map<String, dynamic> node) {
    final tanks = node['consumptionTanks'];
    if (tanks is! List) return const [];
    return tanks
        .whereType<Map<String, dynamic>>()
        .map((ct) {
          final sfl = asDouble(ct['sfl']);
          if (sfl == null) return null;
          return ConsumptionLimit(
            id: (ct['id'] ?? '').toString(),
            equipmentId: asText(node['equipmentId']),
            internalId: asText(node['id']),
            product: label(ct['product']),
            productCode: ct['product'] is Map
                ? asText((ct['product'] as Map)['code'])
                : null,
            sfl: sfl,
          );
        })
        .whereType<ConsumptionLimit>()
        .toList(growable: false);
  }

  factory ConsumptionLimit.fromJson(Map<String, dynamic> json) =>
      ConsumptionLimit(
        id: (json['id'] ?? '').toString(),
        equipmentId: asText(json['equipment_id']),
        internalId: asText(json['internal_id']),
        product: asText(json['product']),
        productCode: asText(json['product_code']),
        sfl: asDouble(json['sfl']) ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'equipment_id': equipmentId,
        'internal_id': internalId,
        'product': product,
        'product_code': productCode,
        'sfl': sfl,
      };
}

/// Clave de cruce equipo+producto, normalizada igual que en MSGQ (`_norm`).
String limitKey(String? equipmentId, String? product) =>
    '${equipmentId?.trim() ?? ''}|${product?.trim().toUpperCase() ?? ''}';

/// Asignacion observada de un tag RFID a un equipo — port de
/// `RFID_HISTORY_COLS` / `transform.rfid_assignments_df`.
///
/// La API NO expone el vinculo historico entre un tag y su equipo: el log de
/// RFID no trae el equipo, y `rfidTags` es solo el estado actual. El historial
/// se RECONSTRUYE observando el maestro: cada vez que se replica, los pares
/// (tag, equipo) vigentes se registran con su `lastSeen`. Un tag que se remueve
/// deja de reinsertarse y su `lastSeen` queda congelado — que es justo lo que
/// permite responder "de quien era este tag" cuando ya no esta en nadie.
class RfidAssignment {
  const RfidAssignment({
    required this.tag,
    this.equipmentId,
    this.internalId,
    this.firstSeen,
    this.lastSeen,
  });

  /// Tag en MAYUSCULAS (la clave; los tags se comparan sin distinguir caja).
  final String tag;

  final String? equipmentId;
  final String? internalId;

  /// Primera observacion del par (se preserva entre refrescos).
  final DateTime? firstSeen;

  /// Ultima observacion. Congelado = el tag ya no esta asignado.
  final DateTime? lastSeen;

  /// Aplana el maestro a una fila por (tag, equipo) observado en [seenAt].
  static List<RfidAssignment> fromEquipment(
    Iterable<Equipment> equipment, {
    required DateTime seenAt,
    Map<String, DateTime> knownFirstSeen = const {},
  }) {
    final out = <RfidAssignment>[];
    final seen = <String>{};
    for (final e in equipment) {
      for (final tag in e.rfidTags) {
        final key = tag.toUpperCase();
        if (!seen.add(key)) continue; // un tag no puede estar en dos equipos
        out.add(RfidAssignment(
          tag: key,
          equipmentId: e.equipmentId,
          internalId: e.internalId,
          firstSeen: knownFirstSeen[key] ?? seenAt,
          lastSeen: seenAt,
        ));
      }
    }
    return out;
  }

  factory RfidAssignment.fromJson(Map<String, dynamic> json) => RfidAssignment(
        tag: (json['tag'] ?? '').toString(),
        equipmentId: asText(json['equipment_id']),
        internalId: asText(json['internal_id']),
        firstSeen: asDate(json['first_seen']),
        lastSeen: asDate(json['last_seen']),
      );

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'equipment_id': equipmentId,
        'internal_id': internalId,
        'first_seen': isoOrNull(firstSeen),
        'last_seen': isoOrNull(lastSeen),
      };
}
