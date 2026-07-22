/// Replica local en SQLite del estado del FMS — port de `msgq/storage/db.py`.
///
/// Por que una base intermedia y no consultar la API desde cada pantalla:
///
///   * La analitica portada NO se puede calcular sobre un snapshot. Un burn
///     rate, una reconciliacion o un "dias promedio en servicio" son funciones
///     del HISTORICO; sin el, cada pantalla tendria que repaginar meses de
///     movimientos en cada apertura.
///   * Da datos consultables aunque la API o la red esten caidas.
///   * Permite sincronizar de forma INCREMENTAL: cada entidad recuerda su
///     `watermark` (el `updatedAt` mas alto ya replicado) y la siguiente pasada
///     solo pide lo posterior.
///
/// Diferencia deliberada con el escritorio: MSGQ hace backfill desde 2022
/// (cientos de miles de filas). Aqui la ventana es acotada y podable
/// ([pruneOlderThan]) — un telefono no tiene ni el almacenamiento ni la
/// paciencia para ese historico completo, y las pantallas portadas trabajan
/// sobre rangos de semanas o meses.
///
/// Concurrencia: sqflite serializa las operaciones sobre una unica conexion, y
/// las escrituras se agrupan en `Batch` dentro de una transaccion, asi que una
/// sincronizacion larga no deja a la UI leyendo a medias.
library;

import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
// `sqflite_common_ffi` reexporta toda la API de `sqflite`, asi que un solo
// import cubre ambos motores (el nativo de movil y el FFI de escritorio).
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../domain/change_event.dart';
import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import '../domain/tank.dart';

/// Nombres de las tablas de la replica (tambien son las claves de watermark).
class ReplicaTable {
  static const movements = 'movements';
  static const equipment = 'equipment';
  static const tanks = 'tanks';
  static const reconciliations = 'reconciliations';
  static const changeEvents = 'change_events';
  static const consumptionLimits = 'consumption_limits';

  static const all = [
    movements,
    equipment,
    tanks,
    reconciliations,
    changeEvents,
    consumptionLimits,
  ];
}

/// Fallo al abrir o escribir la replica local.
class ReplicaException implements Exception {
  const ReplicaException(this.message);

  final String message;

  @override
  String toString() => 'ReplicaException: $message';
}

class ReplicaDatabase {
  ReplicaDatabase._(this._db);

  final Database _db;

  static const _schemaVersion = 1;
  static const _defaultFileName = 'msgq_replica.sqlite3';

  /// Abre (y crea si hace falta) la replica.
  ///
  /// En Windows/Linux `sqflite` no trae motor propio: hay que registrar el de
  /// `sqflite_common_ffi` ANTES de abrir, o la llamada falla con
  /// "databaseFactory not initialized".
  static Future<ReplicaDatabase> open({String? path}) async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final file =
        path ?? p.join(await databaseFactory.getDatabasesPath(), _defaultFileName);
    try {
      final db = await databaseFactory.openDatabase(
        file,
        options: OpenDatabaseOptions(
          version: _schemaVersion,
          onConfigure: (db) => db.execute('PRAGMA foreign_keys = OFF'),
          onCreate: (db, _) => _createSchema(db),
        ),
      );
      return ReplicaDatabase._(db);
    } on DatabaseException catch (e) {
      throw ReplicaException('No se pudo abrir la replica local: $e');
    }
  }

  Future<void> close() => _db.close();

  // =========================================================================
  // Esquema
  // =========================================================================

  static Future<void> _createSchema(Database db) async {
    final batch = db.batch();
    // Los nombres de columna replican el esquema canonico de MSGQ (snake_case)
    // para que ambos software se puedan comparar fila a fila. Van SIEMPRE entre
    // comillas: `group` es palabra reservada de SQL.
    batch.execute('''
      CREATE TABLE movements (
        "id" TEXT PRIMARY KEY, "kind" TEXT, "type" TEXT, "status" TEXT,
        "volume" REAL, "secondary_volume" REAL,
        "record_collected_at" TEXT, "created_at" TEXT, "updated_at" TEXT,
        "transaction_temperature" REAL, "peak_flow_rate" REAL,
        "average_flow_rate" REAL, "flow_duration_s" REAL,
        "meter_id" TEXT, "meter_description" TEXT,
        "primary_volume_source" TEXT, "secondary_volume_source" TEXT,
        "smu_value" REAL, "smu_type" TEXT,
        "raw_smu_value" REAL, "calculated_smu_value" REAL,
        "smu_source" TEXT, "smu_value_source" TEXT,
        "gps_coordinates" TEXT, "cost" REAL, "rebate_amount" REAL,
        "cost_centre" TEXT, "site" TEXT, "product" TEXT, "tank" TEXT,
        "equipment_id" TEXT, "equipment_description" TEXT, "equipment_status" TEXT,
        "is_service_truck" INTEGER, "service_truck" TEXT, "field_user" TEXT
      )''');
    // Indices de los cruces calientes: filtrar por tipo+fecha (toda serie
    // temporal) y agrupar por equipo (top consumidores, burn rate).
    batch.execute(
        'CREATE INDEX idx_movements_kind_updated ON movements("kind", "updated_at")');
    batch.execute(
        'CREATE INDEX idx_movements_equipment ON movements("equipment_id")');
    batch.execute('CREATE INDEX idx_movements_tank ON movements("tank")');

    batch.execute('''
      CREATE TABLE equipment (
        "equipment_id" TEXT PRIMARY KEY, "internal_id" TEXT, "field_id" TEXT,
        "description" TEXT, "registration_number" TEXT,
        "group" TEXT, "category" TEXT, "status" TEXT,
        "make" TEXT, "model" TEXT,
        "is_light_vehicle" INTEGER, "is_contractor_vehicle" INTEGER,
        "rfid" TEXT, "department" TEXT, "cost_centre" TEXT, "project_code" TEXT,
        "service_interval" REAL, "service_interval_type" TEXT,
        "dispense_limited" INTEGER, "dispense_limit_period" TEXT,
        "erp_reference" TEXT, "order_number" TEXT, "order_item" TEXT,
        "sap_measurement_point" TEXT, "updated_at" TEXT
      )''');
    // El log de auditoria enlaza por el id INTERNO, no por el visible.
    batch.execute(
        'CREATE INDEX idx_equipment_internal ON equipment("internal_id")');

    batch.execute('''
      CREATE TABLE tanks (
        "tank_id" TEXT PRIMARY KEY, "code" TEXT, "description" TEXT, "name" TEXT,
        "product" TEXT, "virtual" INTEGER, "capacity" REAL, "volume_unit" TEXT,
        "enabled" INTEGER, "parent_tank" TEXT, "tank_type" TEXT
      )''');

    batch.execute('''
      CREATE TABLE reconciliations (
        "id" TEXT PRIMARY KEY, "period_start" TEXT, "period_end" TEXT,
        "tank" TEXT, "tank_description" TEXT, "product" TEXT,
        "opening_stock" REAL, "closing_stock" REAL,
        "inflow" REAL, "outflow" REAL, "error" REAL,
        "status" TEXT, "updated_at" TEXT
      )''');
    batch.execute(
        'CREATE INDEX idx_recon_tank_period ON reconciliations("tank", "period_end")');

    batch.execute('''
      CREATE TABLE change_events (
        "event_key" TEXT PRIMARY KEY, "changed_at" TEXT,
        "record_type" TEXT, "record_id" TEXT, "event" TEXT, "whodunnit" TEXT,
        "attribute" TEXT, "before" TEXT, "after" TEXT
      )''');
    batch.execute(
        'CREATE INDEX idx_changes_type_attr ON change_events("record_type", "attribute")');
    batch.execute(
        'CREATE INDEX idx_changes_record ON change_events("record_id")');

    batch.execute('''
      CREATE TABLE consumption_limits (
        "id" TEXT PRIMARY KEY, "equipment_id" TEXT, "internal_id" TEXT,
        "product" TEXT, "product_code" TEXT, "sfl" REAL
      )''');

    // Watermark por entidad: el `updatedAt` mas alto ya replicado.
    batch.execute('''
      CREATE TABLE sync_state (
        "entity" TEXT PRIMARY KEY, "watermark" TEXT, "synced_at" TEXT
      )''');
    await batch.commit(noResult: true);
  }

  // =========================================================================
  // Escritura
  // =========================================================================

  /// Upsert idempotente de una lista de modelos ya serializados.
  ///
  /// `INSERT OR REPLACE` sobre la PK: re-descargar una ventana solapada (lo
  /// normal al sincronizar con watermark) no duplica filas. Todo va en UNA
  /// transaccion; con miles de filas la diferencia contra insertar de a una es
  /// de minutos a segundos.
  Future<int> upsertAll(
    String table,
    Iterable<Map<String, dynamic>> rows,
  ) async {
    final list = rows.toList(growable: false);
    if (list.isEmpty) return 0;
    final columns = list.first.keys.toList(growable: false);
    final quoted = columns.map((c) => '"$c"').join(', ');
    final placeholders = List.filled(columns.length, '?').join(', ');
    final sql = 'INSERT OR REPLACE INTO $table ($quoted) VALUES ($placeholders)';
    try {
      await _db.transaction((txn) async {
        final batch = txn.batch();
        for (final row in list) {
          batch.rawInsert(
              sql, columns.map((c) => _toSqlValue(row[c])).toList());
        }
        await batch.commit(noResult: true);
      });
    } on DatabaseException catch (e) {
      throw ReplicaException('Fallo al escribir en $table: $e');
    }
    return list.length;
  }

  Future<int> upsertMovements(Iterable<Movement> items) =>
      upsertAll(ReplicaTable.movements, items.map((m) => m.toJson()));

  Future<int> upsertEquipment(Iterable<Equipment> items) => upsertAll(
      ReplicaTable.equipment,
      // Sin `equipment_id` no hay PK ni cruce posible con los movimientos.
      items.where((e) => e.equipmentId != null).map((e) => e.toJson()));

  Future<int> upsertTanks(Iterable<Tank> items) =>
      upsertAll(ReplicaTable.tanks, items.map((t) => t.toJson()));

  Future<int> upsertReconciliations(Iterable<Reconciliation> items) =>
      upsertAll(ReplicaTable.reconciliations, items.map((r) => r.toJson()));

  Future<int> upsertChangeEvents(Iterable<ChangeEvent> items) =>
      upsertAll(ReplicaTable.changeEvents, items.map((c) => c.toJson()));

  Future<int> upsertConsumptionLimits(Iterable<ConsumptionLimit> items) =>
      upsertAll(ReplicaTable.consumptionLimits, items.map((l) => l.toJson()));

  /// Reemplaza por completo una tabla de CATALOGO (tanques, equipos, limites).
  ///
  /// Los maestros no admiten filtro incremental: llegan enteros en cada
  /// refresco. Sin el borrado previo, un equipo dado de baja en el FMS seguiria
  /// para siempre en la replica inflando los KPIs de flota.
  Future<void> replaceAll(
    String table,
    Iterable<Map<String, dynamic>> rows,
  ) async {
    await _db.transaction((txn) async {
      await txn.delete(table);
    });
    await upsertAll(table, rows);
  }

  // =========================================================================
  // Watermarks
  // =========================================================================

  /// Ultimo instante replicado de [entity] (`null` = nunca se sincronizo).
  Future<DateTime?> watermark(String entity) async {
    final rows = await _db.query('sync_state',
        columns: ['watermark'], where: '"entity" = ?', whereArgs: [entity]);
    return rows.isEmpty ? null : asDate(rows.first['watermark']);
  }

  Future<void> setWatermark(String entity, DateTime? value) async {
    await _db.insert(
      'sync_state',
      {
        'entity': entity,
        'watermark': isoOrNull(value),
        'synced_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Momento del ultimo ciclo de sincronizacion de [entity], haya traido filas
  /// o no. Es lo que la UI muestra como "actualizado hace X".
  Future<DateTime?> lastSyncedAt(String entity) async {
    final rows = await _db.query('sync_state',
        columns: ['synced_at'], where: '"entity" = ?', whereArgs: [entity]);
    return rows.isEmpty ? null : asDate(rows.first['synced_at']);
  }

  // =========================================================================
  // Lectura
  // =========================================================================

  /// Movimientos filtrados. [from]/[to] acotan por `updated_at`.
  Future<List<Movement>> movements({
    MovementKind? kind,
    DateTime? from,
    DateTime? to,
    int? limit,
  }) async {
    final where = <String>[];
    final args = <Object>[];
    if (kind != null) {
      where.add('"kind" = ?');
      args.add(kind.wire);
    }
    if (from != null) {
      where.add('"updated_at" >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.add('"updated_at" <= ?');
      args.add(to.toUtc().toIso8601String());
    }
    final rows = await _db.query(
      ReplicaTable.movements,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: '"updated_at" DESC',
      limit: limit,
    );
    return rows.map(Movement.fromJson).toList(growable: false);
  }

  Future<List<Equipment>> equipmentAll() async {
    final rows = await _db.query(ReplicaTable.equipment);
    return rows.map(Equipment.fromJson).toList(growable: false);
  }

  Future<List<Tank>> tanksAll() async {
    final rows = await _db.query(ReplicaTable.tanks);
    return rows.map(Tank.fromJson).toList(growable: false);
  }

  Future<List<Reconciliation>> reconciliations({
    DateTime? from,
    DateTime? to,
  }) async {
    final where = <String>[];
    final args = <Object>[];
    if (from != null) {
      where.add('"period_end" >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    if (to != null) {
      where.add('"period_end" <= ?');
      args.add(to.toUtc().toIso8601String());
    }
    final rows = await _db.query(
      ReplicaTable.reconciliations,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: '"period_end" DESC',
    );
    return rows.map(Reconciliation.fromJson).toList(growable: false);
  }

  Future<List<ChangeEvent>> changeEvents({
    String? recordType,
    DateTime? from,
  }) async {
    final where = <String>[];
    final args = <Object>[];
    if (recordType != null) {
      where.add('"record_type" = ?');
      args.add(recordType);
    }
    if (from != null) {
      where.add('"changed_at" >= ?');
      args.add(from.toUtc().toIso8601String());
    }
    final rows = await _db.query(
      ReplicaTable.changeEvents,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: '"changed_at" DESC',
    );
    return rows.map(ChangeEvent.fromJson).toList(growable: false);
  }

  Future<List<ConsumptionLimit>> consumptionLimits() async {
    final rows = await _db.query(ReplicaTable.consumptionLimits);
    return rows.map(ConsumptionLimit.fromJson).toList(growable: false);
  }

  /// Filas por tabla (para el panel de diagnostico: "cuanto tengo replicado").
  Future<Map<String, int>> rowCounts() async {
    final counts = <String, int>{};
    for (final table in ReplicaTable.all) {
      final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM $table');
      counts[table] = asInt(rows.first['n']) ?? 0;
    }
    return counts;
  }

  // =========================================================================
  // Mantenimiento
  // =========================================================================

  /// Borra los datos transaccionales anteriores a [cutoff] y compacta.
  ///
  /// Solo poda TRANSACCIONES (movimientos, reconciliaciones, log): los
  /// catalogos —equipos, tanques, limites— son el estado actual y borrar por
  /// fecha los vaciaria.
  Future<void> pruneOlderThan(DateTime cutoff) async {
    final iso = cutoff.toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await txn.delete(ReplicaTable.movements,
          where: '"updated_at" IS NOT NULL AND "updated_at" < ?',
          whereArgs: [iso]);
      await txn.delete(ReplicaTable.reconciliations,
          where: '"period_end" IS NOT NULL AND "period_end" < ?',
          whereArgs: [iso]);
      await txn.delete(ReplicaTable.changeEvents,
          where: '"changed_at" IS NOT NULL AND "changed_at" < ?',
          whereArgs: [iso]);
    });
    await _db.execute('VACUUM');
  }

  /// Vacia la replica entera (cambio de sitio o de tenant: los datos previos ya
  /// no describen nada real).
  Future<void> clear() async {
    await _db.transaction((txn) async {
      for (final table in ReplicaTable.all) {
        await txn.delete(table);
      }
      await txn.delete('sync_state');
    });
  }
}

/// sqflite solo acepta `null`, `num`, `String` y `Uint8List`: los booleanos se
/// guardan como 0/1 (y vuelven a `bool` via [asBool] al leer).
Object? _toSqlValue(Object? value) {
  if (value is bool) return value ? 1 : 0;
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Enum) return value.name;
  return value;
}

/// Ventana de historico que la app mantiene por defecto. Cubre con holgura los
/// rangos que ofrecen las pantallas (hasta 6 meses) sin llevar el telefono a
/// cientos de miles de filas.
const Duration kReplicaRetention = Duration(days: 400);

/// Punto de partida del primer backfill cuando aun no hay watermark.
DateTime replicaHistoryStart({DateTime? now}) =>
    (now ?? DateTime.now().toUtc()).subtract(kReplicaRetention);

/// Tipos de registro del log que la analitica de flota necesita.
const List<String> replicaChangeRecordTypes = changeRecordTypes;
