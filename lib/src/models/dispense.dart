/// Modelo de un DESPACHO (dispense) de combustible a un equipo.
///
/// Subconjunto del aplanado de movimientos de MSGQ (`flatten_movement`)
/// reducido a lo que necesita la auditoria SFL movil y los reportes: el
/// volumen despachado, el equipo destino y el producto. Todos los campos
/// pedidos estan en la query de produccion de MSGQ contra Merian.
library;

class Dispense {
  const Dispense({
    required this.id,
    this.status,
    this.type,
    this.volume,
    this.product,
    this.equipmentId,
    this.equipmentDescription,
    this.tank,
    this.fieldUser,
    this.adaptMac,
    this.adaptMacDescription,
    this.collectedAt,
    this.updatedAt,
    this.peakFlowRate,
    this.durationSeconds,
    this.transactionTemperature,
  });

  final String id;
  final String? status;
  final String? type;
  final double? volume;
  final String? product;

  /// Equipo destino (`target.equipmentId`): la llave del cruce contra el SFL.
  final String? equipmentId;
  final String? equipmentDescription;

  /// Tanque ORIGEN (`source` aplanado). OJO: en Merian es el tanque virtual
  /// ("LFO - Virtual Tank"), igual para los 3 lanes — NO sirve para distinguir
  /// el punto de despacho. El "Dispensing Point" (lane) es la consola AdaptMAC
  /// (ver [adaptMacDescription]).
  final String? tank;
  final String? fieldUser;

  /// Codigo de la consola AdaptMAC que registro el despacho (p. ej. "MER.3").
  final String? adaptMac;

  /// Descripcion de la consola AdaptMAC = el "Dispensing Point" / lane
  /// (p. ej. "LFO Dispense Lane 3"). La API NO expone el medidor/lane como
  /// campo propio del Dispense; el unico vinculo al lane es esta consola.
  final String? adaptMacDescription;
  final DateTime? collectedAt;
  final DateTime? updatedAt;

  /// Caudal PICO del movimiento (L/min), campo `peakFlowRate` de la interface
  /// Movement. La API lo entrega como String (precision) — se parsea a double.
  /// `null` si el tenant no lo expone.
  final double? peakFlowRate;

  /// Duracion del movimiento en SEGUNDOS (`duration`, Int en la interface
  /// Movement). Es el tiempo real de la transaccion, NO el desfase del registro
  /// (`recordCollectedAt/UpdatedAt` son tiempos de SYNC, no de flujo).
  final int? durationSeconds;

  /// Temperatura media de la transaccion en °C (`transactionTemperature`, Float;
  /// se pide sin `unit`, por defecto celsius). `null` si no se expone.
  final double? transactionTemperature;

  /// Caudal MEDIO calculado (L/min) = volumen / (duracion/60). `null` si falta
  /// alguno o la duracion es cero. Los GUARDAS de volumen/duracion minimos para
  /// que el cociente sea significativo viven en `core/flow_temp_check.dart`.
  double? get averageFlowLpm {
    final v = volume;
    final d = durationSeconds;
    if (v == null || d == null || d <= 0) return null;
    return v / (d / 60.0);
  }

  factory Dispense.fromNode(Map<String, dynamic> node) {
    final target = node['target'];
    final source = node['source'];
    final user = node['fieldUser'];
    final mac = node['adaptMac'];
    return Dispense(
      id: (node['id'] ?? '').toString(),
      status: node['status']?.toString(),
      type: node['type']?.toString(),
      volume: _toDouble(node['volume']),
      product: _label(node['product']),
      equipmentId:
          target is Map ? target['equipmentId']?.toString() : null,
      equipmentDescription:
          target is Map ? target['description']?.toString() : null,
      tank: _label(source),
      fieldUser: user is Map ? user['name']?.toString() : null,
      adaptMac: mac is Map ? mac['code']?.toString() : null,
      adaptMacDescription: mac is Map ? mac['description']?.toString() : null,
      collectedAt: _parseDate(node['recordCollectedAt']),
      updatedAt: _parseDate(node['recordUpdatedAt']),
      peakFlowRate: _toDouble(node['peakFlowRate']),
      durationSeconds: _toInt(node['duration']),
      transactionTemperature: _toDouble(node['transactionTemperature']),
    );
  }

  static double? _toDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static int? _toInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static String? _label(Object? ref) {
    if (ref is Map) {
      final name = (ref['name'] ?? ref['description'])?.toString();
      if (name != null && name.isNotEmpty) return name;
      return ref['code']?.toString();
    }
    return ref?.toString();
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}
