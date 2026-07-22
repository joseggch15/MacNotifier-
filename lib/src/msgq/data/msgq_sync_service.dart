/// Motor de sincronizacion de la replica MSGQ — port del `msgq/ingest/poller.py`
/// reducido a un ciclo bajo demanda.
///
/// Diferencia de diseno frente al escritorio: alli el poller es un hilo que
/// late cada 10-30 s indefinidamente. Aqui NO: el sistema operativo movil mata
/// procesos en segundo plano, y estas descargas (historico de movimientos, log
/// de auditoria) son demasiado pesadas para un latido continuo. Se sincroniza
/// cuando el usuario abre o refresca un modulo, y el resto del tiempo las
/// pantallas leen de la replica.
///
/// Dos ritmos, igual que en MSGQ:
///
///   * INCREMENTAL por watermark (movimientos, reconciliaciones, log): solo lo
///     modificado desde la ultima pasada.
///   * CATALOGO completo (tanques, equipos, limites SFL): llegan enteros y
///     reemplazan la tabla, para que una baja en el FMS desaparezca aqui.
///
/// Dart puro: sin dependencias de Flutter UI.
library;

import '../../config/app_settings.dart';
import '../domain/change_event.dart';
import '../domain/equipment.dart';
import '../domain/movement.dart';
import '../domain/tank.dart';
import 'msgq_client.dart';
import 'replica_database.dart';

/// Solapamiento que se resta al watermark antes de pedir la siguiente ventana.
///
/// El filtro `updatedFrom` es del lado del servidor y su reloj no es el nuestro:
/// pedir exactamente desde el ultimo instante replicado deja una rendija por la
/// que se pierden registros escritos durante la pasada anterior. Re-descargar
/// unos minutos es gratis (el upsert es idempotente); perder un movimiento no.
const Duration kWatermarkOverlap = Duration(minutes: 15);

/// Fase del ciclo, para que la UI diga QUE esta bajando y no solo "cargando".
enum SyncPhase {
  movements('Movimientos'),
  reconciliations('Reconciliaciones'),
  tanks('Tanques'),
  equipment('Equipos'),
  changes('Log de auditoria'),
  pruning('Depurando historico');

  const SyncPhase(this.label);

  final String label;
}

/// Progreso de un ciclo de sincronizacion.
class SyncProgress {
  const SyncProgress({required this.phase, this.records = 0});

  final SyncPhase phase;

  /// Registros descargados en la fase actual.
  final int records;
}

/// Resultado de un ciclo completo.
class SyncResult {
  const SyncResult({
    required this.movements,
    required this.reconciliations,
    required this.tanks,
    required this.equipment,
    required this.limits,
    required this.changes,
    required this.elapsed,
    this.cancelled = false,
  });

  final int movements;
  final int reconciliations;
  final int tanks;
  final int equipment;
  final int limits;
  final int changes;
  final Duration elapsed;

  /// El usuario aborto: lo ya escrito es valido, pero los watermarks de las
  /// fases no alcanzadas quedaron intactos para reintentarlas.
  final bool cancelled;

  int get total =>
      movements + reconciliations + tanks + equipment + limits + changes;
}

class MsgqSyncService {
  const MsgqSyncService({required this.replica, required this.settings});

  final ReplicaDatabase replica;
  final AppSettings settings;

  /// Un ciclo completo. Cada fase escribe su watermark SOLO si termino bien,
  /// asi un fallo a mitad de camino no marca como replicado lo que no llego.
  ///
  /// [onCachesDiscovered] entrega el site id, la conexion de equipos y los
  /// campos opcionales descubiertos, para que el llamador los persista y la
  /// proxima sincronizacion se salte la introspeccion.
  Future<SyncResult> sync({
    String? cachedSiteId,
    String? cachedEquipmentField,
    Set<String>? cachedDispenseFields,
    void Function(SyncProgress)? onProgress,
    bool Function()? isCancelled,
    void Function(String? siteId, String? equipmentField,
            Set<String>? dispenseFields)?
        onCachesDiscovered,
  }) async {
    final started = DateTime.now();
    final client = MsgqClient.fromSettings(
      settings,
      siteId: cachedSiteId,
      equipmentField: cachedEquipmentField,
      knownDispenseFields: cachedDispenseFields,
    );
    bool cancelled() => isCancelled?.call() ?? false;

    var movements = 0;
    var reconciliations = 0;
    var tanks = 0;
    var equipment = 0;
    var limits = 0;
    var changes = 0;

    try {
      // -- movimientos (incremental) ---------------------------------------
      if (!cancelled()) {
        onProgress?.call(const SyncProgress(phase: SyncPhase.movements));
        final since = await _since(ReplicaTable.movements);
        final rows = await client.fetchMovements(
          updatedFrom: since,
          onProgress: (_, records) => onProgress
              ?.call(SyncProgress(phase: SyncPhase.movements, records: records)),
          isCancelled: isCancelled,
        );
        if (!cancelled()) {
          movements = await replica.upsertMovements(rows);
          await _advance(ReplicaTable.movements, rows, (m) => m.updatedAt);
        }
      }

      // -- reconciliaciones (incremental) -----------------------------------
      if (!cancelled()) {
        onProgress?.call(const SyncProgress(phase: SyncPhase.reconciliations));
        final since = await _since(ReplicaTable.reconciliations);
        final rows = await client.fetchReconciliations(updatedFrom: since);
        reconciliations = await replica.upsertReconciliations(rows);
        await _advance(
            ReplicaTable.reconciliations, rows, (r) => r.updatedAt ?? r.periodEnd);
      }

      // -- tanques (catalogo completo) --------------------------------------
      if (!cancelled()) {
        onProgress?.call(const SyncProgress(phase: SyncPhase.tanks));
        final rows = await client.fetchTanks();
        // Un catalogo vacio casi siempre es un permiso faltante, no un sitio
        // sin tanques: no se borra lo replicado por una respuesta vacia.
        if (rows.isNotEmpty) {
          await replica.replaceAll(
              ReplicaTable.tanks, rows.map((t) => t.toJson()));
          tanks = rows.length;
        }
        await replica.setWatermark(ReplicaTable.tanks, DateTime.now().toUtc());
      }

      // -- equipos + limites SFL (catalogo completo) ------------------------
      if (!cancelled()) {
        onProgress?.call(const SyncProgress(phase: SyncPhase.equipment));
        final master = await client.fetchEquipment();
        if (master.equipment.isNotEmpty) {
          await replica.replaceAll(
            ReplicaTable.equipment,
            master.equipment
                .where((e) => e.equipmentId != null)
                .map((e) => e.toJson()),
          );
          equipment = master.equipment.length;
          // Observa las asignaciones de tag vigentes ANTES de que cambien: es
          // la unica forma de saber luego de quien era un tag ya removido.
          await replica.recordRfidAssignments(master.equipment);
        }
        if (master.limits.isNotEmpty) {
          await replica.replaceAll(ReplicaTable.consumptionLimits,
              master.limits.map((l) => l.toJson()));
          limits = master.limits.length;
        }
        await replica.setWatermark(
            ReplicaTable.equipment, DateTime.now().toUtc());
      }

      // -- log de auditoria (incremental) -----------------------------------
      if (!cancelled()) {
        onProgress?.call(const SyncProgress(phase: SyncPhase.changes));
        final since = await _since(ReplicaTable.changeEvents);
        final rows = await client.fetchAllChanges(
          changesFrom: since,
          onProgress: (records) => onProgress
              ?.call(SyncProgress(phase: SyncPhase.changes, records: records)),
          isCancelled: isCancelled,
        );
        if (!cancelled()) {
          changes = await replica.upsertChangeEvents(rows);
          await _advance(ReplicaTable.changeEvents, rows, (c) => c.changedAt);
        }
      }

      onCachesDiscovered?.call(
        client.siteId,
        client.equipmentField,
        client.discoveredDispenseFields,
      );

      // -- poda -------------------------------------------------------------
      if (!cancelled()) {
        onProgress?.call(const SyncProgress(phase: SyncPhase.pruning));
        await replica.pruneOlderThan(replicaHistoryStart());
      }

      return SyncResult(
        movements: movements,
        reconciliations: reconciliations,
        tanks: tanks,
        equipment: equipment,
        limits: limits,
        changes: changes,
        elapsed: DateTime.now().difference(started),
        cancelled: cancelled(),
      );
    } finally {
      client.close();
    }
  }

  /// Desde cuando pedir una entidad: su watermark menos el solapamiento, o el
  /// inicio de la ventana de retencion si nunca se sincronizo.
  Future<DateTime> _since(String entity) async {
    final mark = await replica.watermark(entity);
    return mark == null
        ? replicaHistoryStart()
        : mark.subtract(kWatermarkOverlap);
  }

  /// Avanza el watermark al instante MAS ALTO efectivamente replicado.
  ///
  /// Se toma del lote, no del reloj local: si el servidor va atrasado respecto
  /// a nosotros, usar `DateTime.now()` saltaria por encima de registros que
  /// todavia no habia escrito y nunca se descargarian. Un lote vacio deja el
  /// watermark como estaba.
  Future<void> _advance<T>(
    String entity,
    List<T> rows,
    DateTime? Function(T) dateOf,
  ) async {
    final highest = rows.map(dateOf).whereType<DateTime>().fold<DateTime?>(
        null, (acc, d) => acc == null || d.isAfter(acc) ? d : acc);
    if (highest != null) await replica.setWatermark(entity, highest);
  }
}

/// Conjunto de datos que alimenta las pantallas portadas, leido de la replica.
///
/// Se carga de una vez y se pasa a los servicios de analitica: cada pantalla
/// arma sus vistas sobre el mismo conjunto en memoria, sin volver a consultar
/// SQLite por cada tabla.
class MsgqDataset {
  const MsgqDataset({
    required this.movements,
    required this.equipment,
    required this.tanks,
    required this.reconciliations,
    required this.changes,
    this.limits = const [],
    this.rfidHistory = const [],
    required this.loadedAt,
    this.lastSyncedAt,
  });

  final List<Movement> movements;
  final List<Equipment> equipment;
  final List<Tank> tanks;
  final List<Reconciliation> reconciliations;
  final List<ChangeEvent> changes;

  /// Safe Fill Levels por equipo y producto (fuente primaria del producto
  /// asignado en el reporte de RFID).
  final List<ConsumptionLimit> limits;

  /// Historial observado de tag -> equipo.
  final List<RfidAssignment> rfidHistory;

  /// Momento en que se leyo la replica.
  final DateTime loadedAt;

  /// Momento del ultimo ciclo de sincronizacion contra la API.
  final DateTime? lastSyncedAt;

  bool get isEmpty =>
      movements.isEmpty && equipment.isEmpty && reconciliations.isEmpty;
}
