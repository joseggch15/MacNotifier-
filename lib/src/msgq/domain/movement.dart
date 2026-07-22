/// Un movimiento del FMS, aplanado — port de `flatten_movement` +
/// `MOVEMENT_COLS` de MSGQ.
///
/// Las tres conexiones de la API (`dispenses`, `deliveries`, `transfers`)
/// implementan la misma interface `Movement`, asi que se modelan con UNA clase
/// discriminada por [kind]. Eso es lo que permite que la analitica de tanques
/// calcule inflow/outflow sobre un solo conjunto en vez de cruzar tres listas.
///
/// Semantica por tipo (importa al leer `tank` / `equipmentId`):
///   * Dispense  -> `target` es un Equipment Item, `source` es el tanque.
///   * Transfer  -> `source`/`target` son tanques, `serviceTruck` es el equipo.
///   * Delivery  -> `target` es el tanque.
///
/// Dart puro y null-safe: un campo `null` significa "el tenant no lo informa",
/// nunca cero.
library;

import 'fms_vocabulary.dart';
import 'node_parsing.dart';

class Movement {
  const Movement({
    required this.id,
    required this.kind,
    this.type,
    this.status,
    this.volume,
    this.secondaryVolume,
    this.recordCollectedAt,
    this.createdAt,
    this.updatedAt,
    this.transactionTemperature,
    this.peakFlowRate,
    this.averageFlowRate,
    this.flowDurationS,
    this.meterId,
    this.meterDescription,
    this.primaryVolumeSource,
    this.secondaryVolumeSource,
    this.smuValue,
    this.smuType,
    this.rawSmuValue,
    this.calculatedSmuValue,
    this.smuSource,
    this.smuValueSource,
    this.gpsCoordinates,
    this.cost,
    this.rebateAmount,
    this.costCentre,
    this.site,
    this.product,
    this.tank,
    this.equipmentId,
    this.equipmentDescription,
    this.equipmentStatus,
    this.isServiceTruck,
    this.serviceTruck,
    this.fieldUser,
  });

  /// Id del movimiento en el FMS (PK de la replica).
  final String id;

  /// Familia de la transaccion: despacho, entrega o transferencia.
  final MovementKind kind;

  /// Modo de la transaccion (`AUTO`, `KEY_BYPASS`, `Unauthorised`...).
  final String? type;
  final String? status;

  /// Volumen MEDIDO (medidor digital o gauge del tanque), en litros.
  final double? volume;

  /// Volumen DIGITADO en campo desde la guia del camion — solo entregas. Su
  /// diferencia contra [volume] es lo que audita la desviacion de volumen.
  final double? secondaryVolume;

  final DateTime? recordCollectedAt;
  final DateTime? createdAt;

  /// Marca de actualizacion del registro: es la que ordena el tiempo en los
  /// reportes y la que alimenta el watermark incremental de la replica.
  final DateTime? updatedAt;

  final double? transactionTemperature;
  final double? peakFlowRate;

  // -- Salud del medidor / manguera (opcionales segun tenant) ----------------
  final double? averageFlowRate;

  /// Duracion REAL del movimiento en segundos (`duration` de la API).
  final double? flowDurationS;
  final String? meterId;
  final String? meterDescription;

  final String? primaryVolumeSource;
  final String? secondaryVolumeSource;

  // -- SMU (horometro / odometro) -------------------------------------------
  final double? smuValue;
  final String? smuType;

  /// SMU crudo vs calculado: el crudo es la mejor senal de "el sensor no envia
  /// pulsos" (estancamiento) en la auditoria de hardware.
  final double? rawSmuValue;
  final double? calculatedSmuValue;
  final String? smuSource;
  final String? smuValueSource;

  final String? gpsCoordinates;

  final double? cost;
  final double? rebateAmount;
  final String? costCentre;

  final String? site;
  final String? product;

  /// Tanque de ORIGEN de la transaccion (o el destino en una entrega).
  final String? tank;

  final String? equipmentId;
  final String? equipmentDescription;
  final String? equipmentStatus;

  /// `null` cuando no se puede determinar (ni hay service truck ni equipo).
  final bool? isServiceTruck;
  final String? serviceTruck;
  final String? fieldUser;

  /// Circuito del producto (Diesel / Gasolina / Lubricantes), derivado.
  Circuit? get circuit => classifyCircuit(product);

  bool get isDispense => kind == MovementKind.dispense;
  bool get isDelivery => kind == MovementKind.delivery;
  bool get isTransfer => kind == MovementKind.transfer;

  /// Volumen tratado como 0 cuando falta, para sumar sin propagar `null`.
  /// Solo para agregados: NUNCA para decidir si hubo o no medicion.
  double get volumeOrZero => volume ?? 0;

  /// Nodo GraphQL crudo (camelCase) -> modelo, con la semantica por [kind] de
  /// `transform.flatten_movement`.
  factory Movement.fromNode(Map<String, dynamic> node, MovementKind kind) {
    final target = node['target'] is Map<String, dynamic>
        ? node['target'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final serviceTruck = node['serviceTruck'] is Map<String, dynamic>
        ? node['serviceTruck'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final meter = node['meter'] is Map<String, dynamic>
        ? node['meter'] as Map<String, dynamic>
        : const <String, dynamic>{};
    // `target` solo es un Equipment Item en los despachos; en transferencias y
    // entregas es un tanque, y entonces no hay equipo que imputar.
    final targetEquipmentId = asText(target['equipmentId']);

    return Movement(
      id: (node['id'] ?? '').toString(),
      kind: kind,
      type: asText(node['type']),
      status: asText(node['status']),
      volume: asDouble(node['volume']),
      secondaryVolume: asDouble(node['secondaryVolume']),
      recordCollectedAt: asDate(node['recordCollectedAt']),
      createdAt: asDate(node['recordCreatedAt']),
      updatedAt: asDate(node['recordUpdatedAt']),
      transactionTemperature: asDouble(node['transactionTemperature']),
      peakFlowRate: asDouble(node['peakFlowRate']),
      averageFlowRate: asDouble(node['averageFlowRate']),
      flowDurationS: asDouble(node['duration']),
      meterId: asText(meter['code']),
      meterDescription: asText(meter['description']),
      primaryVolumeSource: asText(node['volumeSource']),
      secondaryVolumeSource: asText(node['secondaryVolumeSource']),
      smuValue: asDouble(node['smuValue']),
      smuType: asText(node['smuType']),
      rawSmuValue: asDouble(node['rawSmuValue']),
      calculatedSmuValue: asDouble(node['calculatedSmuValue']),
      smuSource: asText(node['smuSource']),
      smuValueSource: asText(node['smuValueSource']),
      gpsCoordinates: asText(node['gpsCoordinates']),
      cost: asDouble(node['cost']),
      rebateAmount: asDouble(node['rebateAmount']),
      costCentre: label(node['costCentre']),
      site: label(node['site']),
      product: label(node['product']),
      tank: label(node['source']) ?? label(target),
      equipmentId: targetEquipmentId,
      equipmentDescription:
          targetEquipmentId == null ? null : asText(target['description']),
      equipmentStatus: asText(target['status']),
      isServiceTruck: serviceTruck.isNotEmpty
          ? true
          : (targetEquipmentId != null ? false : null),
      serviceTruck: asText(serviceTruck['equipmentId']),
      fieldUser: asText(dig(node, ['fieldUser', 'name'])),
    );
  }

  /// JSON/fila de la replica (snake_case, el esquema canonico de MSGQ).
  factory Movement.fromJson(Map<String, dynamic> json) => Movement(
        id: (json['id'] ?? '').toString(),
        kind: MovementKind.fromWire(json['kind'] as String?) ??
            MovementKind.dispense,
        type: asText(json['type']),
        status: asText(json['status']),
        volume: asDouble(json['volume']),
        secondaryVolume: asDouble(json['secondary_volume']),
        recordCollectedAt: asDate(json['record_collected_at']),
        createdAt: asDate(json['created_at']),
        updatedAt: asDate(json['updated_at']),
        transactionTemperature: asDouble(json['transaction_temperature']),
        peakFlowRate: asDouble(json['peak_flow_rate']),
        averageFlowRate: asDouble(json['average_flow_rate']),
        flowDurationS: asDouble(json['flow_duration_s']),
        meterId: asText(json['meter_id']),
        meterDescription: asText(json['meter_description']),
        primaryVolumeSource: asText(json['primary_volume_source']),
        secondaryVolumeSource: asText(json['secondary_volume_source']),
        smuValue: asDouble(json['smu_value']),
        smuType: asText(json['smu_type']),
        rawSmuValue: asDouble(json['raw_smu_value']),
        calculatedSmuValue: asDouble(json['calculated_smu_value']),
        smuSource: asText(json['smu_source']),
        smuValueSource: asText(json['smu_value_source']),
        gpsCoordinates: asText(json['gps_coordinates']),
        cost: asDouble(json['cost']),
        rebateAmount: asDouble(json['rebate_amount']),
        costCentre: asText(json['cost_centre']),
        site: asText(json['site']),
        product: asText(json['product']),
        tank: asText(json['tank']),
        equipmentId: asText(json['equipment_id']),
        equipmentDescription: asText(json['equipment_description']),
        equipmentStatus: asText(json['equipment_status']),
        isServiceTruck: asBool(json['is_service_truck']),
        serviceTruck: asText(json['service_truck']),
        fieldUser: asText(json['field_user']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.wire,
        'type': type,
        'status': status,
        'volume': volume,
        'secondary_volume': secondaryVolume,
        'record_collected_at': isoOrNull(recordCollectedAt),
        'created_at': isoOrNull(createdAt),
        'updated_at': isoOrNull(updatedAt),
        'transaction_temperature': transactionTemperature,
        'peak_flow_rate': peakFlowRate,
        'average_flow_rate': averageFlowRate,
        'flow_duration_s': flowDurationS,
        'meter_id': meterId,
        'meter_description': meterDescription,
        'primary_volume_source': primaryVolumeSource,
        'secondary_volume_source': secondaryVolumeSource,
        'smu_value': smuValue,
        'smu_type': smuType,
        'raw_smu_value': rawSmuValue,
        'calculated_smu_value': calculatedSmuValue,
        'smu_source': smuSource,
        'smu_value_source': smuValueSource,
        'gps_coordinates': gpsCoordinates,
        'cost': cost,
        'rebate_amount': rebateAmount,
        'cost_centre': costCentre,
        'site': site,
        'product': product,
        'tank': tank,
        'equipment_id': equipmentId,
        'equipment_description': equipmentDescription,
        'equipment_status': equipmentStatus,
        'is_service_truck': isServiceTruck,
        'service_truck': serviceTruck,
        'field_user': fieldUser,
      };

  @override
  String toString() =>
      'Movement(${kind.wire} $id, ${volume?.toStringAsFixed(1)} L, $product)';
}
