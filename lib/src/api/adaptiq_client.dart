/// Cliente GraphQL contra la API de AdaptIQ (AdaptFMS), en HTTP puro.
///
/// Port de `msgq/api/client.py` reducido al dominio de consolas:
///
///   * Resuelve el `site id` (configurado o autodescubierto via `sites`).
///   * Ejecuta queries via POST con `Authorization: Token token=<token>`.
///   * Pagina por cursor (`pageInfo.hasNextPage` / `endCursor`, limite 100).
///   * Espacia las peticiones y reintenta 429/503/timeout con backoff, para
///     ser buen ciudadano del endpoint.
///   * Traduce fallos de red/HTTP/GraphQL a excepciones de dominio claras.
///
/// Es Dart puro (sin dependencias de Flutter UI): el mismo cliente corre en el
/// isolate de primer plano y en el de Workmanager.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../config/app_settings.dart';
import '../core/sfl_check.dart' show sflKey;
import '../models/adapt_mac.dart';
import '../models/delivery.dart';
import '../models/dispense.dart';
import 'queries.dart' as queries;

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Token ausente, invalido o expirado (HTTP 401/403).
class AuthException extends ApiException {
  const AuthException(super.message);
}

/// Fallo de red / conexion / timeout al hablar con el endpoint.
class TransportException extends ApiException {
  const TransportException(super.message);
}

/// El servidor respondio 200 pero con errores en el cuerpo GraphQL.
class GraphQLException extends ApiException {
  const GraphQLException(super.message);
}

class AdaptIQClient {
  AdaptIQClient(
    this._settings, {
    String? siteId,
    Set<String>? knownOptionalFields,
    String? equipmentField,
    http.Client? httpClient,
  })  : _siteId = (siteId != null && siteId.isNotEmpty) ? siteId : null,
        _optionalFields = knownOptionalFields,
        _equipmentField = equipmentField,
        _http = httpClient ?? http.Client();

  final AppSettings _settings;
  final http.Client _http;

  String? _siteId;
  Set<String>? _optionalFields;

  /// Conexion de equipos del tenant: null = sin descubrir; '' = no existe.
  String? _equipmentField;
  DateTime? _lastRequestAt;

  // En movil los reintentos son cortos: el ciclo de primer plano corre cada
  // 20 s y el isolate de background de iOS tiene ~30 s de presupuesto total.
  static const _maxRetries = 2;
  static const _requestTimeout = Duration(seconds: 25);
  static const _minRequestInterval = Duration(milliseconds: 300);
  static const _retryAfterCeiling = Duration(seconds: 60);

  /// Site id resuelto (para que el llamador lo persista como cache).
  String? get siteId => _siteId;

  /// Campos opcionales del nodo AdaptMac descubiertos por introspeccion.
  Set<String>? get discoveredOptionalFields => _optionalFields;

  /// Conexion de equipos descubierta ('' = el tenant no expone equipos).
  String? get equipmentField => _equipmentField;

  void close() => _http.close();

  // -- contrato publico ------------------------------------------------------

  /// Lista los sitios visibles para el token (tambien sirve de "probar conexion").
  Future<List<Map<String, dynamic>>> fetchSites() async {
    final data = await _execute(queries.sitesQuery);
    final sites = data['sites'];
    return [
      if (sites is List)
        for (final s in sites)
          if (s is Map<String, dynamic>) s,
    ];
  }

  /// Trae TODAS las consolas AdaptMAC del sitio (paginado completo).
  Future<List<AdaptMac>> fetchAdaptMacs() async {
    final siteId = await _resolveSiteId();
    final optional = await _discoverOptionalFields();
    List<Map<String, dynamic>> nodes;
    try {
      nodes = await _paginateSiteConnection(
        queries.buildAdaptMacsQuery(optional),
        'adaptMacs',
        {'siteId': siteId, 'first': kPageSize},
      );
    } on GraphQLException {
      // La introspeccion puede anunciar un campo que la query real rechaza
      // (p. ej. permisos del token). Reintenta UNA vez con la query base
      // probada en produccion, en vez de dejar el monitoreo ciego.
      if (optional.isEmpty) rethrow;
      _optionalFields = <String>{};
      nodes = await _paginateSiteConnection(
        queries.buildAdaptMacsQuery(const {}),
        'adaptMacs',
        {'siteId': siteId, 'first': kPageSize},
      );
    }
    return [for (final n in nodes) AdaptMac.fromNode(n)];
  }

  /// Trae las entregas actualizadas desde [updatedFrom] (filtro incremental
  /// `MovementQuery.updatedFrom`, igual que el poller de MSGQ).
  Future<List<Delivery>> fetchDeliveries({DateTime? updatedFrom}) async {
    final siteId = await _resolveSiteId();
    final nodes = await _paginateSiteConnection(
      queries.deliveriesQuery,
      'deliveries',
      {
        'siteId': siteId,
        'filter': {
          if (updatedFrom != null)
            'updatedFrom': updatedFrom.toUtc().toIso8601String(),
        },
        'first': kPageSize,
      },
    );
    return [for (final n in nodes) Delivery.fromNode(n)];
  }

  /// Trae los despachos actualizados desde [updatedFrom] (incremental).
  Future<List<Dispense>> fetchDispenses({DateTime? updatedFrom}) async {
    final siteId = await _resolveSiteId();
    final nodes = await _paginateSiteConnection(
      queries.dispensesQuery,
      'dispenses',
      {
        'siteId': siteId,
        'filter': {
          if (updatedFrom != null)
            'updatedFrom': updatedFrom.toUtc().toIso8601String(),
        },
        'first': kPageSize,
      },
    );
    return [for (final n in nodes) Dispense.fromNode(n)];
  }

  /// Mapa de limites SFL {sflKey(equipo, producto): sfl} desde los
  /// `consumptionTanks` del maestro de equipos. Devuelve `null` si el tenant
  /// no expone una conexion de equipos (los sobrellenados no se pueden
  /// auditar por GraphQL en ese caso).
  Future<Map<String, double>?> fetchSflLimits() async {
    final siteId = await _resolveSiteId();
    final field = await _discoverEquipmentField();
    if (field.isEmpty) return null;
    final nodes = await _paginateSiteConnection(
      queries.buildSflLimitsQuery(field),
      field,
      {'siteId': siteId, 'first': kPageSize},
    );
    final limits = <String, double>{};
    for (final node in nodes) {
      final eid = node['equipmentId']?.toString().trim();
      if (eid == null || eid.isEmpty) continue;
      final tanks = node['consumptionTanks'];
      if (tanks is! List) continue;
      for (final tank in tanks) {
        if (tank is! Map) continue;
        final sfl = tank['sfl'];
        final sflValue = sfl is num
            ? sfl.toDouble()
            : sfl is String
                ? double.tryParse(sfl)
                : null;
        if (sflValue == null || sflValue <= 0) continue;
        final product = tank['product'];
        final label = product is Map
            ? (product['description'] ?? product['code'])?.toString()
            : null;
        if (label == null || label.isEmpty) continue;
        limits[sflKey(eid, label)] = sflValue;
      }
    }
    return limits;
  }

  // -- resolucion de sitio ----------------------------------------------------

  Future<String> _resolveSiteId() async {
    final fixed = _settings.siteId.trim();
    if (fixed.isNotEmpty) return _siteId = fixed;
    final cached = _siteId;
    if (cached != null) return cached;
    final sites = await fetchSites();
    if (sites.isEmpty) {
      throw const ApiException(
          'La API no devolvio sitios; revisa los permisos del token.');
    }
    final match = _settings.siteMatch.trim().toLowerCase();
    Map<String, dynamic>? chosen;
    if (match.isNotEmpty) {
      for (final s in sites) {
        final blob = '${s['code'] ?? ''} ${s['description'] ?? ''}'.toLowerCase();
        if (blob.contains(match)) {
          chosen = s;
          break;
        }
      }
    }
    chosen ??= sites.first;
    return _siteId = chosen['id'].toString();
  }

  // -- introspeccion de campos opcionales -------------------------------------

  Future<Set<String>> _discoverOptionalFields() async {
    final cached = _optionalFields;
    if (cached != null) return cached;
    var available = <String>{};
    for (final typeName in queries.adaptMacTypeCandidates) {
      Map<String, dynamic> data;
      try {
        data = await _execute(queries.typeFieldsIntrospection(typeName));
      } on AuthException {
        rethrow;
      } on ApiException {
        continue; // introspeccion deshabilitada o tipo inexistente: probar otro
      }
      final type = data['__type'];
      if (type is! Map<String, dynamic>) continue;
      final fields = type['fields'];
      final names = <String>{
        if (fields is List)
          for (final f in fields)
            if (f is Map && f['name'] != null) f['name'].toString(),
      };
      // Tipo hallado: su interseccion es la respuesta (aunque sea vacia).
      available = names.intersection(queries.optionalAdaptMacFields.keys.toSet());
      break;
    }
    return _optionalFields = available;
  }

  /// Introspecciona el tipo Site para hallar la conexion de equipos (port de
  /// `_discover_equipment_field` de MSGQ). '' = ningun candidato existe.
  Future<String> _discoverEquipmentField() async {
    final cached = _equipmentField;
    if (cached != null) return cached;
    Map<String, dynamic> data;
    try {
      data = await _execute(queries.siteFieldsIntrospectionQuery);
    } on AuthException {
      rethrow;
    } on ApiException {
      return _equipmentField = ''; // introspeccion no disponible
    }
    final type = data['__type'];
    final fields = type is Map<String, dynamic> ? type['fields'] : null;
    final names = <String>{
      if (fields is List)
        for (final f in fields)
          if (f is Map && f['name'] != null) f['name'].toString(),
    };
    for (final candidate in queries.equipmentFieldCandidates) {
      if (names.contains(candidate)) return _equipmentField = candidate;
    }
    return _equipmentField = '';
  }

  // -- paginacion --------------------------------------------------------------

  Future<List<Map<String, dynamic>>> _paginateSiteConnection(
    String query,
    String connection,
    Map<String, dynamic> variables,
  ) async {
    final nodes = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < 1000; page++) { // cota de seguridad
      final data = await _execute(query, {
        ...variables,
        if (cursor != null) 'after': cursor,
      });
      final site = data['site'];
      final conn = site is Map<String, dynamic> ? site[connection] : null;
      if (conn is! Map<String, dynamic>) break;
      final edges = conn['edges'];
      if (edges is List) {
        for (final edge in edges) {
          final node = edge is Map<String, dynamic> ? edge['node'] : null;
          if (node is Map<String, dynamic>) nodes.add(node);
        }
      }
      final pageInfo = conn['pageInfo'];
      final hasNext =
          pageInfo is Map<String, dynamic> && pageInfo['hasNextPage'] == true;
      cursor = pageInfo is Map<String, dynamic>
          ? pageInfo['endCursor'] as String?
          : null;
      if (!hasNext || cursor == null) break;
    }
    return nodes;
  }

  // -- ejecucion de bajo nivel --------------------------------------------------

  Future<Map<String, dynamic>> _execute(
    String query, [
    Map<String, dynamic> variables = const {},
  ]) async {
    final uri = Uri.parse(_settings.endpoint);
    final payload = jsonEncode({'query': query, 'variables': variables});
    var attempt = 0;
    while (true) {
      await _throttle();
      http.Response resp;
      try {
        resp = await _http
            .post(uri, headers: _settings.authHeaders(), body: payload)
            .timeout(_requestTimeout);
      } on Exception catch (e) {
        if (attempt < _maxRetries) {
          attempt += 1;
          await Future<void>.delayed(_backoffDelay(attempt));
          continue;
        }
        throw TransportException('Fallo de conexion con el endpoint: $e');
      }

      // 429/503: el servidor pide expresamente bajar el ritmo.
      if ((resp.statusCode == 429 || resp.statusCode == 503) &&
          attempt < _maxRetries) {
        attempt += 1;
        await Future<void>.delayed(
            _parseRetryAfter(resp.headers['retry-after']) ?? _backoffDelay(attempt));
        continue;
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw AuthException(
            'Autenticacion rechazada (HTTP ${resp.statusCode}). Verifica el '
            'token (Authorization: Token token=<token>).');
      }
      if (resp.statusCode >= 400) {
        throw TransportException('HTTP ${resp.statusCode}: ${_snippet(resp)}');
      }

      final Object? body;
      try {
        body = jsonDecode(utf8.decode(resp.bodyBytes));
      } on FormatException {
        throw GraphQLException('La respuesta no es JSON valido: ${_snippet(resp)}');
      }
      if (body is! Map<String, dynamic>) {
        throw const GraphQLException('Respuesta GraphQL con forma inesperada.');
      }
      final errors = body['errors'];
      if (errors is List && errors.isNotEmpty) {
        final messages = errors
            .map((e) => e is Map ? (e['message'] ?? e).toString() : e.toString())
            .join('; ');
        throw GraphQLException(messages);
      }
      final data = body['data'];
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }
  }

  /// Espacia las peticiones consecutivas (paginacion incluida) para no parecer
  /// un escaneo al WAF del endpoint.
  Future<void> _throttle() async {
    final last = _lastRequestAt;
    if (last != null) {
      final wait = _minRequestInterval - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastRequestAt = DateTime.now();
  }

  Duration _backoffDelay(int attempt) {
    final base = min(1000 * pow(2, attempt - 1).toInt(), 8000);
    return Duration(milliseconds: base + Random().nextInt(500));
  }

  Duration? _parseRetryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds == null) return null;
    final d = Duration(seconds: max(0, seconds));
    return d > _retryAfterCeiling ? _retryAfterCeiling : d;
  }

  String _snippet(http.Response resp) {
    final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}
