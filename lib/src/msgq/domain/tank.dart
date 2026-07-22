/// Tanques del sitio y su reconciliacion diaria — port de `flatten_tank` /
/// `flatten_reconciliation` (`TANK_COLS` / `RECONCILIATION_COLS` de MSGQ).
///
/// La analitica de tanques tiene dos mitades que NO deben confundirse:
///
///   * TRANSACCIONES: entregas / despachos / transferencias — se calcula desde
///     [Movement].
///   * STOCK MEDIDO: opening / closing por sensor — llega ya pre-calculado en
///     [Reconciliation], el reporte 'Detailed Reconciliation' nativo de AdaptIQ.
///
/// La resta de ambas mitades es el `error` de reconciliacion: litros que el
/// sensor dice que salieron del tanque pero ninguna transaccion registro.
///
/// Dart puro y null-safe.
library;

import 'fms_vocabulary.dart';
import 'node_parsing.dart';

/// Registro maestro de un tanque.
class Tank {
  const Tank({
    required this.tankId,
    this.code,
    this.description,
    this.name,
    this.product,
    this.virtual,
    this.capacity,
    this.volumeUnit,
    this.enabled,
    this.parentTank,
    this.tankType,
  });

  final String tankId;

  /// Codigo del tanque: es la clave con la que se cruza contra
  /// [Movement.tank] y [Reconciliation.tank].
  final String? code;
  final String? description;
  final String? name;
  final String? product;

  /// Tanque LOGICO cuyo nivel es la suma de sus hijos (los satelites apuntan a
  /// el con [parentTank]). Sumarlo junto a sus hijos contaria doble.
  final bool? virtual;

  final double? capacity;
  final String? volumeUnit;
  final bool? enabled;

  /// `code` del tanque padre (virtual), si este es un satelite.
  final String? parentTank;
  final String? tankType;

  /// Etiqueta preferida para mostrar: la misma precedencia (`name` >
  /// `description` > `code`) con la que la API etiqueta el tanque en cada
  /// movimiento, para que ambas vistas nombren igual al mismo tanque.
  String get displayLabel =>
      asText(name) ?? asText(description) ?? asText(code) ?? tankId;

  Circuit? get circuit => classifyCircuit(product);

  factory Tank.fromNode(Map<String, dynamic> node) => Tank(
        tankId: (node['id'] ?? '').toString(),
        code: asText(node['code']),
        description: asText(node['description']),
        name: asText(node['name']),
        product: label(node['product']),
        virtual: asBool(node['virtual']),
        capacity: asDouble(node['capacity']),
        volumeUnit: asText(node['volumeUnit']),
        enabled: asBool(node['enabled']),
        parentTank: asText(dig(node, ['parentTank', 'code'])),
        tankType: label(node['tankType']),
      );

  factory Tank.fromJson(Map<String, dynamic> json) => Tank(
        tankId: (json['tank_id'] ?? '').toString(),
        code: asText(json['code']),
        description: asText(json['description']),
        name: asText(json['name']),
        product: asText(json['product']),
        virtual: asBool(json['virtual']),
        capacity: asDouble(json['capacity']),
        volumeUnit: asText(json['volume_unit']),
        enabled: asBool(json['enabled']),
        parentTank: asText(json['parent_tank']),
        tankType: asText(json['tank_type']),
      );

  Map<String, dynamic> toJson() => {
        'tank_id': tankId,
        'code': code,
        'description': description,
        'name': name,
        'product': product,
        'virtual': virtual,
        'capacity': capacity,
        'volume_unit': volumeUnit,
        'enabled': enabled,
        'parent_tank': parentTank,
        'tank_type': tankType,
      };

  @override
  String toString() => 'Tank($code, $product)';
}

/// Una reconciliacion diaria de UN tanque.
///
/// `error` llega YA calculado por la API (viaja en su campo `volume`) como
/// `(closing - opening) - (inflow - outflow)`. No se recalcula: se replica tal
/// cual para que la app y el reporte oficial de AdaptIQ nunca discrepen.
class Reconciliation {
  const Reconciliation({
    required this.id,
    this.periodStart,
    this.periodEnd,
    this.tank,
    this.tankDescription,
    this.product,
    this.openingStock,
    this.closingStock,
    this.inflow,
    this.outflow,
    this.error,
    this.status,
    this.updatedAt,
  });

  final String id;
  final DateTime? periodStart;

  /// Fin del periodo: es la fecha por la que se ordena y se filtra (un dia
  /// operativo se identifica por su cierre).
  final DateTime? periodEnd;

  /// `code` del tanque reconciliado.
  final String? tank;
  final String? tankDescription;
  final String? product;

  /// Stock MEDIDO por el sensor al abrir / cerrar el periodo.
  final double? openingStock;
  final double? closingStock;

  /// Volumen que ENTRO / SALIO segun las transacciones registradas.
  final double? inflow;
  final double? outflow;

  /// Descuadre pre-calculado por la API.
  final double? error;

  /// `all_ok` / `unconfirmed` / `pending`.
  final String? status;
  final DateTime? updatedAt;

  Circuit? get circuit => classifyCircuit(product);

  /// Error relativo al outflow (%). `null` si no hubo salidas: dividir por cero
  /// convertiria un descuadre pequeno en un porcentaje infinito.
  double? get errorPctOfOutflow {
    final out = outflow;
    final err = error;
    if (out == null || err == null || out == 0) return null;
    return roundTo(err / out * 100, 2);
  }

  factory Reconciliation.fromNode(Map<String, dynamic> node) {
    final target = node['target'] is Map<String, dynamic>
        ? node['target'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return Reconciliation(
      id: (node['id'] ?? '').toString(),
      periodStart: asDate(node['periodStart']),
      periodEnd: asDate(node['periodEnd']),
      tank: asText(target['code']),
      tankDescription: asText(target['description']),
      product: label(node['product']),
      openingStock: asDouble(node['openingStock']),
      closingStock: asDouble(node['closingStock']),
      inflow: asDouble(node['inflowVolume']),
      outflow: asDouble(node['outflowVolume']),
      error: asDouble(node['volume']),
      status: asText(node['status']),
      updatedAt: asDate(node['recordUpdatedAt']),
    );
  }

  factory Reconciliation.fromJson(Map<String, dynamic> json) => Reconciliation(
        id: (json['id'] ?? '').toString(),
        periodStart: asDate(json['period_start']),
        periodEnd: asDate(json['period_end']),
        tank: asText(json['tank']),
        tankDescription: asText(json['tank_description']),
        product: asText(json['product']),
        openingStock: asDouble(json['opening_stock']),
        closingStock: asDouble(json['closing_stock']),
        inflow: asDouble(json['inflow']),
        outflow: asDouble(json['outflow']),
        error: asDouble(json['error']),
        status: asText(json['status']),
        updatedAt: asDate(json['updated_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'period_start': isoOrNull(periodStart),
        'period_end': isoOrNull(periodEnd),
        'tank': tank,
        'tank_description': tankDescription,
        'product': product,
        'opening_stock': openingStock,
        'closing_stock': closingStock,
        'inflow': inflow,
        'outflow': outflow,
        'error': error,
        'status': status,
        'updated_at': isoOrNull(updatedAt),
      };

  @override
  String toString() => 'Reconciliation($tank, $periodEnd, err=$error)';
}
