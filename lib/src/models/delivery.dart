/// Modelo de una ENTREGA (delivery) de combustible.
///
/// Subconjunto del aplanado de movimientos de MSGQ (`flatten_movement`)
/// reducido a lo que necesita la auditoria movil:
///
///   * `volume`          — volumen MEDIDO (medidor de linea / gauge del tanque).
///   * `secondaryVolume` — volumen DIGITADO en campo desde la guia del camion.
///
/// La diferencia entre ambos es la "Variance" que muestra AdaptIQ y lo que
/// audita `core/delivery_check.dart`.
library;

class Delivery {
  const Delivery({
    required this.id,
    this.status,
    this.type,
    this.volume,
    this.uom,
    this.secondaryVolume,
    this.volumeSource,
    this.secondaryVolumeSource,
    this.docketNumber,
    this.driver,
    this.company,
    this.tank,
    this.product,
    this.adaptMac,
    this.collectedAt,
    this.updatedAt,
  });

  final String id;
  final String? status;
  final String? type;

  /// Volumen MEDIDO (la referencia fisica).
  final double? volume;
  final String? uom;

  /// Volumen de la GUIA del camion (digitado en campo).
  final double? secondaryVolume;
  final String? volumeSource;
  final String? secondaryVolumeSource;
  final String? docketNumber;
  final String? driver;
  final String? company;

  /// Tanque de destino (target aplanado a etiqueta).
  final String? tank;
  final String? product;
  final String? adaptMac;
  final DateTime? collectedAt;
  final DateTime? updatedAt;

  /// Diferencia con signo (medido - guia), como la columna Variance de
  /// AdaptIQ: NEGATIVA cuando al tanque entro menos de lo que reclama la guia.
  double? get deviationL {
    final m = volume, f = secondaryVolume;
    if (m == null || f == null) return null;
    return m - f;
  }

  /// Desviacion |%| relativa a la GUIA (mismo denominador que AdaptIQ: la
  /// captura muestra 19,2 L medidos vs 40.000 de guia como 99,95 %). MSGQ usa
  /// el medido como denominador, pero en una entrega partida eso degenera
  /// (208.233 %); sobre la guia el numero se mantiene legible y comparable.
  double? get deviationPct {
    final dev = deviationL;
    final f = secondaryVolume;
    if (dev == null || f == null || f <= 0) return null;
    return dev.abs() / f * 100.0;
  }

  /// `status` ∈ {confirmed, unconfirmed, ...} segun tenant; se normaliza.
  bool get isUnconfirmed =>
      (status ?? '').toLowerCase().contains('unconfirm');

  /// Etiqueta corta para titulos de notificacion: la guia si existe, sino el id.
  String get label {
    final docket = (docketNumber ?? '').trim();
    return docket.isNotEmpty ? docket : id;
  }

  factory Delivery.fromNode(Map<String, dynamic> node) {
    return Delivery(
      id: (node['id'] ?? '').toString(),
      status: node['status']?.toString(),
      type: node['type']?.toString(),
      volume: _toDouble(node['volume']),
      uom: node['uom']?.toString(),
      secondaryVolume: _toDouble(node['secondaryVolume']),
      volumeSource: node['volumeSource']?.toString(),
      secondaryVolumeSource: node['secondaryVolumeSource']?.toString(),
      docketNumber: node['docketNumber']?.toString(),
      driver: node['driver']?.toString(),
      company: node['company']?.toString(),
      tank: _label(node['target']),
      product: _label(node['product']),
      adaptMac: node['adaptMac'] is Map
          ? (node['adaptMac'] as Map)['code']?.toString()
          : null,
      collectedAt: _parseDate(node['recordCollectedAt']),
      updatedAt: _parseDate(node['recordUpdatedAt']),
    );
  }

  factory Delivery.fromJson(Map<String, dynamic> json) {
    return Delivery(
      id: (json['id'] ?? '').toString(),
      status: json['status'] as String?,
      type: json['type'] as String?,
      volume: _toDouble(json['volume']),
      uom: json['uom'] as String?,
      secondaryVolume: _toDouble(json['secondaryVolume']),
      volumeSource: json['volumeSource'] as String?,
      secondaryVolumeSource: json['secondaryVolumeSource'] as String?,
      docketNumber: json['docketNumber'] as String?,
      driver: json['driver'] as String?,
      company: json['company'] as String?,
      tank: json['tank'] as String?,
      product: json['product'] as String?,
      adaptMac: json['adaptMac'] as String?,
      collectedAt: _parseDate(json['collectedAt']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status,
        'type': type,
        'volume': volume,
        'uom': uom,
        'secondaryVolume': secondaryVolume,
        'volumeSource': volumeSource,
        'secondaryVolumeSource': secondaryVolumeSource,
        'docketNumber': docketNumber,
        'driver': driver,
        'company': company,
        'tank': tank,
        'product': product,
        'adaptMac': adaptMac,
        'collectedAt': collectedAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  static double? _toDouble(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  static String? _label(Object? ref) {
    if (ref is Map) {
      // target trae {code name}; product trae {code description}.
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
