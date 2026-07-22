/// Capa de estado de los modulos MSGQ (Riverpod).
///
/// Misma eleccion que el resto de la app —Riverpod sobre BLoC— y por la misma
/// razon: esto es "un valor asincrono que se refresca" mas un puñado de
/// filtros, no una maquina de estados con transiciones explicitas.
///
/// La separacion que sostiene todo el modulo:
///
///   * [msgqDatasetProvider] es la UNICA fuente de datos: lee la replica local
///     y expone el conjunto en memoria.
///   * Los providers de analitica son DERIVADOS y sincronos: recalculan al
///     vuelo cuando cambia un filtro, sin tocar ni la red ni SQLite. Por eso
///     cambiar de circuito o de periodo es instantaneo.
///   * La sincronizacion contra la API es una accion explicita
///     ([MsgqDatasetController.syncNow]), nunca un efecto secundario de pintar
///     una pantalla.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../analytics/activity_audit.dart';
import '../analytics/burn_rate.dart';
import '../analytics/equipment_analytics.dart';
import '../analytics/grouping.dart';
import '../analytics/hardware_health.dart';
import '../analytics/product_audit.dart';
import '../analytics/rfid_inventory.dart';
import '../analytics/tag_hopping.dart';
import '../analytics/tank_analytics.dart';
import '../data/msgq_sync_service.dart';
import '../data/replica_database.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/equipment.dart';

/// Replica local, abierta una sola vez por sesion.
final replicaProvider = FutureProvider<ReplicaDatabase>((ref) async {
  final db = await ReplicaDatabase.open();
  ref.onDispose(db.close);
  return db;
});

/// Fase y avance del ciclo de sincronizacion en curso (`null` = inactivo).
final msgqSyncProgressProvider = StateProvider<SyncProgress?>((_) => null);

/// Ultimo error de sincronizacion. Se muestra como banner SIN vaciar los datos:
/// una pasada fallida no invalida lo que ya estaba replicado.
final msgqSyncErrorProvider = StateProvider<String?>((_) => null);

/// Rango de historico que se analiza.
enum MsgqRange {
  days30('30 dias', Duration(days: 30)),
  days90('90 dias', Duration(days: 90)),
  days180('6 meses', Duration(days: 180)),
  all('Todo', kReplicaRetention);

  const MsgqRange(this.label, this.window);

  final String label;
  final Duration window;

  DateTime start({DateTime? now}) =>
      (now ?? DateTime.now().toUtc()).subtract(window);
}

final msgqRangeProvider = StateProvider<MsgqRange>((_) => MsgqRange.days90);

/// Circuito seleccionado (`null` = todos).
final msgqCircuitProvider = StateProvider<Circuit?>((_) => null);

/// Granularidad de las series temporales.
final msgqPeriodProvider =
    StateProvider<AnalyticsPeriod>((_) => AnalyticsPeriod.daily);

/// Dimension por la que se agrupa la flota y el consumo.
final msgqDimensionProvider =
    StateProvider<EquipmentDimension>((_) => EquipmentDimension.group);

/// Conjunto de datos leido de la replica.
final msgqDatasetProvider =
    AsyncNotifierProvider<MsgqDatasetController, MsgqDataset>(
        MsgqDatasetController.new);

class MsgqDatasetController extends AsyncNotifier<MsgqDataset> {
  bool _syncing = false;
  bool _cancelled = false;

  /// Si ya se intento la siembra automatica, y con que sitio (asi se re-siembra
  /// al cambiar de sitio pero no se reintenta en cada rebuild).
  bool _seedAttempted = false;
  String? _seedSite;

  @override
  Future<MsgqDataset> build() async {
    // El rango cambia QUE se lee de la replica, asi que el dataset depende de
    // el; los demas filtros son locales y no justifican releer SQLite.
    final range = ref.watch(msgqRangeProvider);
    final replica = await ref.watch(replicaProvider.future);
    final dataset = await _load(replica, range);
    // Replica vacia y app configurada: siembra en segundo plano para que la
    // primera apertura no sea una pantalla en blanco.
    if (dataset.isEmpty) unawaited(Future.microtask(_seedIfNeeded));
    return dataset;
  }

  Future<MsgqDataset> _load(ReplicaDatabase replica, MsgqRange range) async {
    final from = range.start();
    return MsgqDataset(
      movements: await replica.movements(from: from),
      equipment: await replica.equipmentAll(),
      tanks: await replica.tanksAll(),
      reconciliations: await replica.reconciliations(from: from),
      changes: await replica.changeEvents(from: from),
      limits: await replica.consumptionLimits(),
      rfidHistory: await replica.rfidHistory(),
      productHistory: await replica.productHistory(),
      loadedAt: DateTime.now().toUtc(),
      lastSyncedAt: await replica.lastSyncedAt(ReplicaTable.movements),
    );
  }

  /// Relee la replica sin tocar la red (tras una sincronizacion o un cambio de
  /// rango).
  Future<void> reload() async {
    final replica = await ref.read(replicaProvider.future);
    state = AsyncData(await _load(replica, ref.read(msgqRangeProvider)));
  }

  /// Un ciclo de sincronizacion contra la API, y despues relee la replica.
  ///
  /// Si falla, CONSERVA los datos actuales y solo registra el error: un timeout
  /// no debe dejar en blanco un dashboard que ya tenia meses replicados.
  Future<void> syncNow() async {
    if (_syncing) return; // un ciclo lento no debe solaparse con el siguiente
    final settings = ref.read(settingsProvider);
    if (!settings.isConfigured) {
      ref.read(msgqSyncErrorProvider.notifier).state =
          'Falta el token de la API: configuralo antes de sincronizar.';
      return;
    }
    _syncing = true;
    _cancelled = false;
    ref.read(msgqSyncErrorProvider.notifier).state = null;
    final store = ref.read(appStoreProvider);
    try {
      final replica = await ref.read(replicaProvider.future);
      final service = MsgqSyncService(replica: replica, settings: settings);
      await service.sync(
        cachedSiteId: store.cachedSiteId ?? _nullIfEmpty(settings.siteId),
        cachedEquipmentField: store.cachedEquipmentField,
        cachedDispenseFields: _dispenseFields,
        isCancelled: () => _cancelled,
        onProgress: (p) =>
            ref.read(msgqSyncProgressProvider.notifier).state = p,
        onCachesDiscovered: (siteId, _, dispenseFields) {
          _dispenseFields = dispenseFields;
          if (siteId != null) unawaited(store.saveCachedSiteId(siteId));
        },
      );
      await reload();
    } on Object catch (e) {
      ref.read(msgqSyncErrorProvider.notifier).state = e.toString();
      if (state.valueOrNull == null) state = AsyncError(e, StackTrace.current);
    } finally {
      _syncing = false;
      ref.read(msgqSyncProgressProvider.notifier).state = null;
    }
  }

  /// Corta la pasada en curso (el usuario salio o pulso cancelar).
  void cancelSync() => _cancelled = true;

  bool get isSyncing => _syncing;

  /// Campos opcionales del despacho descubiertos en esta sesion. No se
  /// persisten: es UNA peticion de introspeccion por arranque, y cachearla en
  /// disco arriesga quedarse con un esquema viejo tras un cambio del tenant.
  Set<String>? _dispenseFields;

  Future<void> _seedIfNeeded() async {
    final settings = ref.read(settingsProvider);
    if (!settings.isConfigured) return;
    final store = ref.read(appStoreProvider);
    final site = store.cachedSiteId ?? settings.siteId;
    if (_seedAttempted && _seedSite == site) return;
    _seedAttempted = true;
    _seedSite = site;
    await syncNow();
  }
}

String? _nullIfEmpty(String value) => value.trim().isEmpty ? null : value.trim();

// ===========================================================================
// Analitica derivada (sincrona: no toca red ni disco)
// ===========================================================================

/// Servicio de tanques ya filtrado por circuito y rango. `null` mientras el
/// dataset esta cargando o fallo.
final tankAnalyticsProvider = Provider<TankAnalytics?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  final circuit = ref.watch(msgqCircuitProvider);
  return TankAnalytics(
    movements: dataset.movements,
    equipment: dataset.equipment,
    reconciliations: dataset.reconciliations,
    tanks: dataset.tanks,
  ).filterCircuit(circuit);
});

/// Servicio de flota. No se filtra por circuito: un equipo no pertenece a un
/// circuito de producto, sino que consume de varios.
final equipmentAnalyticsProvider = Provider<EquipmentAnalytics?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  return EquipmentAnalytics(
    equipment: dataset.equipment,
    changes: dataset.changes,
  );
});

/// Transiciones de estado, calculadas UNA vez y compartidas: casi todas las
/// vistas de la pantalla de equipos parten de ellas, y recorren el log entero.
final statusTransitionsProvider = Provider<List<StatusTransition>>((ref) {
  final analytics = ref.watch(equipmentAnalyticsProvider);
  return analytics?.statusTransitions() ?? const [];
});

/// Producto seleccionado en Burn Rate (`null` = todos agregados).
final burnRateProductProvider = StateProvider<String?>((_) => null);

/// Auditoria de burn rate.
///
/// Se calcula en DOS pasos a proposito: [_burnRateBaseProvider] hace la pasada
/// cara (encadenar los intervalos) y solo depende del dataset; cambiar de
/// producto re-proyecta el resultado ya calculado en memoria. Sin esa
/// separacion, tocar el desplegable de producto recorreria de nuevo todos los
/// movimientos.
final _burnRateBaseProvider = Provider<BurnRateAudit?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  return BurnRateAudit.run(
    movements: dataset.movements,
    equipment: dataset.equipment,
  );
});

final burnRateProvider = Provider<BurnRateAudit?>((ref) {
  final base = ref.watch(_burnRateBaseProvider);
  if (base == null) return null;
  final product = ref.watch(burnRateProductProvider);
  return product == base.product ? base : base.forProduct(product);
});

/// Auditoria de salud de hardware y sensores.
final hardwareHealthProvider = Provider<HardwareAudit?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  return HardwareAudit.run(
    movements: dataset.movements,
    equipment: dataset.equipment,
    changes: dataset.changes,
  );
});

/// Reporte de inventario de tags RFID, acotado al rango seleccionado.
///
/// El rango se pasa como fechas LOCALES del sitio, igual que en el escritorio:
/// el log guarda UTC y una instalacion nocturna caeria en el dia siguiente.
final rfidInventoryProvider = Provider<RfidInventoryAudit?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  final range = ref.watch(msgqRangeProvider);
  return RfidInventoryAudit.run(
    changes: dataset.changes,
    equipment: dataset.equipment,
    movements: dataset.movements,
    limits: dataset.limits,
    history: dataset.rfidHistory,
    from: range.start().add(const Duration(hours: siteUtcOffsetHours)),
    tzOffsetHours: siteUtcOffsetHours,
  );
});

/// Auditoria de tag hopping.
final tagHoppingProvider = Provider<TagHopAudit?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  return TagHopAudit.run(
    movements: dataset.movements,
    equipment: dataset.equipment,
  );
});

/// Umbral de dias sin despachar para considerar fantasma a un equipo.
final idleDaysProvider = StateProvider<int>((_) => idleAssetDays);

/// Auditoria de actividad (equipos fantasma, combustible no registrado, SMU
/// congelado).
final activityAuditProvider = Provider<ActivityAudit?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  return ActivityAudit.run(
    movements: dataset.movements,
    equipment: dataset.equipment,
    limits: dataset.limits,
    idleDays: ref.watch(idleDaysProvider),
  );
});

/// Auditoria de coherencia producto <-> equipo.
final productAuditProvider = Provider<ProductAudit?>((ref) {
  final dataset = ref.watch(msgqDatasetProvider).valueOrNull;
  if (dataset == null) return null;
  return ProductAudit.run(
    movements: dataset.movements,
    limits: dataset.limits,
    productHistory: dataset.productHistory,
  );
});

/// Filas por tabla de la replica (panel de diagnostico).
final replicaCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  // Se recalcula tras cada sincronizacion, porque el dataset cambia con ella.
  ref.watch(msgqDatasetProvider);
  final replica = await ref.watch(replicaProvider.future);
  return replica.rowCounts();
});
