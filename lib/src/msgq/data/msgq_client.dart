/// Acceso a las conexiones de la API que solo usa la analitica MSGQ — port de
/// `msgq/api/client.py` reducido a lo que el escritorio llama "datos maestros e
/// historicos": movimientos completos, tanques, reconciliaciones, maestro de
/// equipos y log de auditoria.
///
/// COMPOSICION, no herencia: envuelve al [AdaptIQClient] del notificador en vez
/// de reimplementarlo. El transporte, el throttling anti-WAF, el backoff ante
/// 429/503 y la traduccion de errores a excepciones de dominio ya estan
/// resueltos y probados alli; duplicarlos habria dado dos clientes con distinto
/// comportamiento ante el mismo endpoint.
///
/// Dart puro (sin dependencias de Flutter UI): corre igual en el isolate de
/// primer plano y en el de background.
library;

import '../../api/adaptiq_client.dart';
import '../../config/app_settings.dart';
import '../../models/adapt_mac.dart';
import '../domain/change_event.dart';
import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/tank.dart';
import 'msgq_queries.dart' as q;

/// Maestro de equipos y sus limites SFL: la misma query devuelve ambos
/// (`consumptionTanks` viaja anidado en cada equipo), asi que se entregan
/// juntos en vez de pagar dos veces la misma descarga.
class EquipmentMaster {
  const EquipmentMaster({required this.equipment, required this.limits});

  final List<Equipment> equipment;
  final List<ConsumptionLimit> limits;

  static const EquipmentMaster empty =
      EquipmentMaster(equipment: [], limits: []);
}

class MsgqClient {
  MsgqClient(this._client);

  /// Construye el cliente sobre la configuracion de la app, reusando los
  /// descubrimientos ya cacheados (site id, conexion de equipos) para no
  /// repetir la introspeccion en cada sincronizacion.
  factory MsgqClient.fromSettings(
    AppSettings settings, {
    String? siteId,
    String? equipmentField,
    Set<String>? knownDispenseFields,
  }) {
    final client = MsgqClient(AdaptIQClient(
      settings,
      siteId: siteId,
      equipmentField: equipmentField,
    ));
    client._dispenseFields = knownDispenseFields;
    return client;
  }

  final AdaptIQClient _client;

  /// Campos opcionales del despacho que el tenant expone. `null` = sin
  /// descubrir; conjunto vacio = ninguno disponible.
  Set<String>? _dispenseFields;

  /// Site id resuelto (para que el llamador lo persista como cache).
  String? get siteId => _client.siteId;

  /// Conexion de equipos descubierta (`''` = el tenant no expone equipos).
  String? get equipmentField => _client.equipmentField;

  /// Campos opcionales del despacho descubiertos (para cachearlos).
  Set<String>? get discoveredDispenseFields => _dispenseFields;

  void close() => _client.close();

  // =========================================================================
  // Movimientos
  // =========================================================================

  /// Trae los movimientos de las TRES conexiones desde [updatedFrom],
  /// etiquetando cada uno con su [MovementKind].
  ///
  /// [onProgress] reporta `(kind, registros acumulados)` por pagina e
  /// [isCancelled] permite abortar: un backfill sobre movil puede durar minutos
  /// y el usuario tiene que poder salirse sin dejar la app colgada.
  Future<List<Movement>> fetchMovements({
    DateTime? updatedFrom,
    Set<MovementKind> kinds = const {
      MovementKind.dispense,
      MovementKind.delivery,
      MovementKind.transfer,
    },
    void Function(MovementKind kind, int records)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = <Movement>[];
    for (final kind in MovementKind.values) {
      if (!kinds.contains(kind)) continue;
      if (isCancelled?.call() ?? false) break;
      final nodes = await _client.paginateSiteConnection(
        await _queryFor(kind),
        _connectionFor(kind),
        await _movementVariables(updatedFrom),
        onPage: (_, records) => onProgress?.call(kind, records),
        isCancelled: isCancelled,
      );
      out.addAll(nodes.map((n) => Movement.fromNode(n, kind)));
    }
    return out;
  }

  /// Pagina UNA conexion de movimientos emitiendo CADA pagina, sin acumular.
  ///
  /// Es el camino RESUMIBLE: el llamador persiste cada pagina y guarda su
  /// [endCursor]; si el proceso se interrumpe (pantalla apagada, red caida,
  /// app en segundo plano), reanuda pasando ese cursor como [startCursor] y
  /// continua donde quedo, en vez de re-descargar las 30.000 filas. Ademas
  /// nunca sostiene mas de una pagina en memoria — importa en un telefono de
  /// gama baja.
  ///
  /// [onPage] recibe la pagina ya parseada, el cursor con el que reanudar, y si
  /// quedan mas paginas. Se aguarda (`await`) para que la escritura de una
  /// pagina termine antes de pedir la siguiente.
  Future<void> fetchMovementsPaged({
    required MovementKind kind,
    DateTime? updatedFrom,
    String? startCursor,
    required Future<void> Function(
            List<Movement> page, String? endCursor, bool hasNext)
        onPage,
    bool Function()? isCancelled,
  }) async {
    final query = await _queryFor(kind);
    final connection = _connectionFor(kind);
    final variables = await _movementVariables(updatedFrom);
    var cursor = startCursor;
    for (var page = 0; page < 100000; page++) { // cota de seguridad
      if (isCancelled?.call() ?? false) return;
      final data = await _client.execute(query, {
        ...variables,
        if (cursor != null) 'after': cursor,
      });
      final site = data['site'];
      final conn = site is Map<String, dynamic> ? site[connection] : null;
      if (conn is! Map<String, dynamic>) return;
      final movements = <Movement>[];
      final edges = conn['edges'];
      if (edges is List) {
        for (final edge in edges) {
          final node = edge is Map<String, dynamic> ? edge['node'] : null;
          if (node is Map<String, dynamic>) {
            movements.add(Movement.fromNode(node, kind));
          }
        }
      }
      final pageInfo = conn['pageInfo'];
      final hasNext =
          pageInfo is Map<String, dynamic> && pageInfo['hasNextPage'] == true;
      cursor = pageInfo is Map<String, dynamic>
          ? pageInfo['endCursor'] as String?
          : null;
      final more = hasNext && cursor != null;
      await onPage(movements, cursor, more);
      if (!more) return;
    }
  }

  String _connectionFor(MovementKind kind) => switch (kind) {
        MovementKind.dispense => 'dispenses',
        MovementKind.delivery => 'deliveries',
        MovementKind.transfer => 'transfers',
      };

  /// Solo los despachos llevan campos opcionales; las otras dos conexiones usan
  /// su query fija.
  Future<String> _queryFor(MovementKind kind) async => switch (kind) {
        MovementKind.dispense =>
          q.buildDispensesQuery(await _discoverDispenseFields()),
        MovementKind.delivery => q.deliveriesQuery,
        MovementKind.transfer => q.transfersQuery,
      };

  Future<Map<String, dynamic>> _movementVariables(DateTime? updatedFrom) async {
    return {
      'siteId': await _client.resolveSiteId(),
      'filter': {
        if (updatedFrom != null)
          'updatedFrom': updatedFrom.toUtc().toIso8601String(),
      },
      'first': kPageSize,
    };
  }

  /// Cuales de [q.optionalDispenseFields] expone el tenant (cacheado).
  ///
  /// Si la introspeccion no esta disponible devuelve el conjunto vacio: se usa
  /// la query base, intacta. Es preferible perder el medidor y el SMU crudo a
  /// romper la sincronizacion entera con un campo inexistente.
  Future<Set<String>> _discoverDispenseFields() async {
    final cached = _dispenseFields;
    if (cached != null) return cached;
    for (final typeName in q.dispenseTypeCandidates) {
      Map<String, dynamic> data;
      try {
        data = await _client.execute(q.typeFieldsIntrospection(typeName));
      } on AuthException {
        rethrow;
      } on ApiException {
        continue; // introspeccion deshabilitada o tipo inexistente
      }
      final type = data['__type'];
      if (type is! Map<String, dynamic>) continue;
      final fields = type['fields'];
      final names = <String>{
        if (fields is List)
          for (final f in fields)
            if (f is Map && f['name'] != null) f['name'].toString(),
      };
      // Tipo hallado: su interseccion es la respuesta, aunque sea vacia.
      return _dispenseFields =
          names.intersection(q.optionalDispenseFields.keys.toSet());
    }
    return _dispenseFields = <String>{};
  }

  // =========================================================================
  // Maestros e historicos
  // =========================================================================

  /// Maestro de consolas AdaptMAC.
  ///
  /// Reexpone el fetch del notificador: la query y el descubrimiento de campos
  /// opcionales ya estan resueltos alli, y duplicarlos daria dos consultas con
  /// distinta seleccion de campos contra el mismo tipo.
  Future<List<AdaptMac>> fetchAdaptMacs() => _client.fetchAdaptMacs();

  /// Tanques del sitio (catalogo completo; no admite filtro incremental).
  Future<List<Tank>> fetchTanks() async {
    final nodes = await _client.paginateSiteConnection(
      q.tanksQuery,
      'tanks',
      {'siteId': await _client.resolveSiteId(), 'first': kPageSize},
    );
    return nodes.map(Tank.fromNode).toList(growable: false);
  }

  /// Reconciliaciones diarias por tanque desde [updatedFrom].
  Future<List<Reconciliation>> fetchReconciliations({
    DateTime? updatedFrom,
  }) async {
    final nodes = await _client.paginateSiteConnection(
      q.reconciliationsQuery,
      'reconciliations',
      {
        'siteId': await _client.resolveSiteId(),
        'filter': {
          if (updatedFrom != null)
            'updatedFrom': updatedFrom.toUtc().toIso8601String(),
        },
        'first': kPageSize,
      },
    );
    return nodes.map(Reconciliation.fromNode).toList(growable: false);
  }

  /// Maestro de equipos + sus Safe Fill Levels.
  ///
  /// Devuelve [EquipmentMaster.empty] si el tenant no expone conexion de
  /// equipos: es un escenario soportado (el `Equipment Item` del doc oficial no
  /// es listable), no un error.
  Future<EquipmentMaster> fetchEquipment() async {
    final field = await _client.discoverEquipmentField();
    if (field.isEmpty) return EquipmentMaster.empty;
    final nodes = await _client.paginateSiteConnection(
      q.buildEquipmentQuery(field),
      field,
      {'siteId': await _client.resolveSiteId(), 'first': kPageSize},
    );
    return EquipmentMaster(
      equipment: nodes.map(Equipment.fromNode).toList(growable: false),
      limits: nodes
          .expand(ConsumptionLimit.fromEquipmentNode)
          .toList(growable: false),
    );
  }

  /// Log de auditoria de un tipo de registro desde [changesFrom].
  ///
  /// `changes` es la unica query TOP-LEVEL del esquema (no cuelga del site: el
  /// site va dentro del filtro), por eso no puede usar el paginador de
  /// conexiones del sitio.
  Future<List<ChangeEvent>> fetchChanges({
    required String recordType,
    DateTime? changesFrom,
    void Function(int records)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final filter = <String, dynamic>{
      'siteId': await _client.resolveSiteId(),
      'recordType': recordType,
      if (changesFrom != null)
        'changesFrom': changesFrom.toUtc().toIso8601String(),
    };
    final nodes = await _paginateTopLevel(
      q.changesQuery,
      'changes',
      {'filter': filter, 'first': kPageSize},
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    return nodes.expand(ChangeEvent.fromNode).toList(growable: false);
  }

  /// Igual que [fetchChanges] pero emitiendo cada pagina (camino RESUMIBLE).
  Future<void> fetchChangesPaged({
    required String recordType,
    DateTime? changesFrom,
    String? startCursor,
    required Future<void> Function(
            List<ChangeEvent> page, String? endCursor, bool hasNext)
        onPage,
    bool Function()? isCancelled,
  }) async {
    final filter = <String, dynamic>{
      'siteId': await _client.resolveSiteId(),
      'recordType': recordType,
      if (changesFrom != null)
        'changesFrom': changesFrom.toUtc().toIso8601String(),
    };
    var cursor = startCursor;
    for (var page = 0; page < 100000; page++) {
      if (isCancelled?.call() ?? false) return;
      final data = await _client.execute(q.changesQuery, {
        'filter': filter,
        'first': kPageSize,
        if (cursor != null) 'after': cursor,
      });
      final conn = data['changes'];
      if (conn is! Map<String, dynamic>) return;
      final events = <ChangeEvent>[];
      final edges = conn['edges'];
      if (edges is List) {
        for (final edge in edges) {
          final node = edge is Map<String, dynamic> ? edge['node'] : null;
          if (node is Map<String, dynamic>) events.addAll(ChangeEvent.fromNode(node));
        }
      }
      final pageInfo = conn['pageInfo'];
      final hasNext =
          pageInfo is Map<String, dynamic> && pageInfo['hasNextPage'] == true;
      cursor = pageInfo is Map<String, dynamic>
          ? pageInfo['endCursor'] as String?
          : null;
      final more = hasNext && cursor != null;
      await onPage(events, cursor, more);
      if (!more) return;
    }
  }

  /// Log de auditoria de TODOS los tipos que la analitica de flota necesita
  /// (`EquipmentItem` + `EquipmentRfid`).
  Future<List<ChangeEvent>> fetchAllChanges({
    DateTime? changesFrom,
    void Function(int records)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final out = <ChangeEvent>[];
    for (final recordType in changeRecordTypes) {
      if (isCancelled?.call() ?? false) break;
      out.addAll(await fetchChanges(
        recordType: recordType,
        changesFrom: changesFrom,
        onProgress: (records) => onProgress?.call(out.length + records),
        isCancelled: isCancelled,
      ));
    }
    return out;
  }

  /// Pagina por cursor una conexion top-level.
  Future<List<Map<String, dynamic>>> _paginateTopLevel(
    String query,
    String rootKey,
    Map<String, dynamic> variables, {
    void Function(int records)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final nodes = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < 10000; page++) { // cota de seguridad
      if (isCancelled?.call() ?? false) break;
      final data = await _client.execute(query, {
        ...variables,
        if (cursor != null) 'after': cursor,
      });
      final conn = data[rootKey];
      if (conn is! Map<String, dynamic>) break;
      final edges = conn['edges'];
      if (edges is List) {
        for (final edge in edges) {
          final node = edge is Map<String, dynamic> ? edge['node'] : null;
          if (node is Map<String, dynamic>) nodes.add(node);
        }
      }
      onProgress?.call(nodes.length);
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
}
