/// Modelo de una consola/hardware de campo AdaptMAC.
///
/// Espejo de `flatten_adaptmac` en `msgq/core/transform.py`: mismos campos y el
/// mismo aplanado del `site { code description }` a una etiqueta.
library;

class AdaptMac {
  const AdaptMac({
    required this.code,
    this.description,
    this.site,
    this.erpReference,
    this.online,
    this.keyBypass,
    this.lastSuccessfulComms,
    this.lastFailedComms,
    this.updatedAt,
  });

  final String code;
  final String? description;
  final String? site;
  final String? erpReference;

  /// Flag de conexion que reporta la API. `null` = el tenant no lo informo.
  final bool? online;

  /// Consola en modo bypass de autorizacion (despacha sin validar tag/llave).
  final bool? keyBypass;

  /// Solo presentes si el tenant los expone (se descubren por introspeccion).
  final DateTime? lastSuccessfulComms;
  final DateTime? lastFailedComms;
  final DateTime? updatedAt;

  /// Nodo GraphQL crudo (camelCase) -> modelo.
  factory AdaptMac.fromNode(Map<String, dynamic> node) {
    return AdaptMac(
      code: (node['code'] ?? '').toString(),
      description: node['description']?.toString(),
      site: _label(node['site']),
      erpReference: node['erpReference']?.toString(),
      online: node['online'] as bool?,
      keyBypass: node['keyBypass'] as bool?,
      lastSuccessfulComms: _parseDate(node['lastSuccessfulComms']),
      lastFailedComms: _parseDate(node['lastFailedComms']),
      updatedAt: _parseDate(node['updatedAt']),
    );
  }

  /// JSON persistido en el snapshot local (site ya viene aplanado a String).
  factory AdaptMac.fromJson(Map<String, dynamic> json) {
    return AdaptMac(
      code: (json['code'] ?? '').toString(),
      description: json['description'] as String?,
      site: json['site'] as String?,
      erpReference: json['erpReference'] as String?,
      online: json['online'] as bool?,
      keyBypass: json['keyBypass'] as bool?,
      lastSuccessfulComms: _parseDate(json['lastSuccessfulComms']),
      lastFailedComms: _parseDate(json['lastFailedComms']),
      updatedAt: _parseDate(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'description': description,
        'site': site,
        'erpReference': erpReference,
        'online': online,
        'keyBypass': keyBypass,
        'lastSuccessfulComms': lastSuccessfulComms?.toIso8601String(),
        'lastFailedComms': lastFailedComms?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  static String? _label(Object? ref) {
    if (ref is Map) {
      final description = ref['description']?.toString();
      if (description != null && description.isNotEmpty) return description;
      return ref['code']?.toString();
    }
    return ref?.toString();
  }

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}
