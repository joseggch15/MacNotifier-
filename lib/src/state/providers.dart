/// Capa de estado (Riverpod).
///
/// Se eligio Riverpod sobre BLoC porque este flujo es esencialmente "un valor
/// asincrono que se refresca solo" (AsyncNotifier + Timer) mas un puñado de
/// ajustes: no hay maquinas de estados complejas que justifiquen eventos/
/// transiciones explicitas, y Riverpod permite leer providers fuera del arbol
/// de widgets (util para disparar chequeos desde callbacks).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/adaptiq_client.dart';
import '../background/background_scheduler.dart';
import '../background/health_runner.dart';
import '../config/app_settings.dart';
import '../core/health_check.dart';
import '../core/unauthorised_check.dart';
import '../storage/app_store.dart';

/// Inyectado en `main()` con la instancia real respaldada por
/// shared_preferences (asi los tests pueden sustituirlo).
final appStoreProvider = Provider<AppStore>(
  (ref) => throw UnimplementedError('appStoreProvider se inyecta en main()'),
);

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(appStoreProvider).loadSettings();

  Future<void> save(AppSettings next) async {
    final store = ref.read(appStoreProvider);
    final prev = state;
    await store.saveSettings(next);
    // Cambio de endpoint/sitio: el site id y el esquema cacheados ya no valen.
    if (prev.endpoint != next.endpoint ||
        prev.siteMatch != next.siteMatch ||
        prev.siteId != next.siteId) {
      await store.clearApiCaches();
    }
    state = next;
    await BackgroundScheduler.sync(next);
  }
}

/// Ultimo error de sincronizacion (la UI lo muestra como banner sin perder los
/// datos del ultimo ciclo bueno — mismo patron que el indicador LIVE de MSGQ).
final lastSyncErrorProvider = StateProvider<String?>(
  (ref) => ref.watch(appStoreProvider).lastError,
);

final consolesProvider =
    AsyncNotifierProvider<ConsolesController, HealthCheckResult>(
        ConsolesController.new);

class ConsolesController extends AsyncNotifier<HealthCheckResult> {
  bool _checking = false;

  @override
  FutureOr<HealthCheckResult> build() {
    final settings = ref.watch(settingsProvider);
    if (!settings.isConfigured) throw const NotConfiguredException();

    final timer = Timer.periodic(
      Duration(seconds: settings.pollSeconds.clamp(5, 3600)),
      (_) => refreshNow(),
    );
    ref.onDispose(timer.cancel);

    // Si hay snapshot persistido, pinta la UI al instante con el ultimo estado
    // conocido y dispara un ciclo real de inmediato.
    final cached = ref.read(appStoreProvider).loadSnapshot();
    if (cached != null) {
      Future.microtask(refreshNow);
      return cached;
    }
    return _check();
  }

  Future<HealthCheckResult> _check() =>
      runHealthCheck(store: ref.read(appStoreProvider));

  /// Un ciclo de chequeo. Si falla y ya habia datos, los CONSERVA y solo
  /// registra el error (el dashboard no se queda en blanco por un timeout).
  Future<void> refreshNow() async {
    if (_checking) return; // un ciclo lento no debe solaparse con el siguiente
    _checking = true;
    try {
      final result = await _check();
      state = AsyncData(result);
      ref.read(lastSyncErrorProvider.notifier).state = null;
    } on Object catch (e, st) {
      ref.read(lastSyncErrorProvider.notifier).state = e.toString();
      if (state.valueOrNull == null) state = AsyncError(e, st);
    } finally {
      _checking = false;
    }
  }
}

/// Segmento temporal seleccionado en la pestaña "Sin ID". Por defecto semanal:
/// suficiente para no perder lo reciente. AHORA es solo un filtro LOCAL sobre el
/// conjunto de abiertos que el poller ya mantiene (ver [HealthCheckResult.
/// unauthorised]); cambiar de periodo ya NO dispara descargas — es instantaneo.
final unauthPeriodProvider =
    StateProvider<UnauthPeriod>((_) => UnauthPeriod.weekly);

/// Progreso del BACKFILL puntual de "Sin ID".
///
/// La pestaña se sirve del set de abiertos incremental (instantaneo), pero ese
/// set solo cubre lo que el poller ha visto desde que arranco. Este backfill
/// hace UNA pasada paginada y acotada ([kUnauthorisedBackfillWindow]) la primera
/// vez por sitio para sembrar los "sin ID" abiertos previos; despues el poller
/// los mantiene. Es interrumpible y reporta progreso (en vez del spinner
/// infinito que tenia la vista live al paginar ventanas largas).
class UnauthBackfillState {
  const UnauthBackfillState({
    this.running = false,
    this.pages = 0,
    this.scanned = 0,
    this.found = 0,
    this.error,
  });

  /// Backfill en curso.
  final bool running;

  /// Paginas ya traidas (progreso visible).
  final int pages;

  /// Despachos revisados hasta ahora.
  final int scanned;

  /// "Sin ID" abiertos sembrados al terminar.
  final int found;

  /// Mensaje del ultimo fallo (null = sin error).
  final String? error;

  UnauthBackfillState copyWith({
    bool? running,
    int? pages,
    int? scanned,
    int? found,
    String? error,
  }) =>
      UnauthBackfillState(
        running: running ?? this.running,
        pages: pages ?? this.pages,
        scanned: scanned ?? this.scanned,
        found: found ?? this.found,
        error: error,
      );
}

final unauthBackfillProvider =
    NotifierProvider<UnauthBackfillController, UnauthBackfillState>(
        UnauthBackfillController.new);

class UnauthBackfillController extends Notifier<UnauthBackfillState> {
  bool _cancelled = false;

  /// Si ya se intento el arranque automatico, y para que sitio (asi se
  /// re-siembra al cambiar de sitio pero no se reintenta en cada rebuild).
  bool _attempted = false;
  String? _attemptedSite;

  @override
  UnauthBackfillState build() => const UnauthBackfillState();

  /// Disparo AUTOMATICO (al abrir la pestaña): arranca a lo sumo una vez por
  /// sitio observado. Idempotente — la pestaña puede llamarlo en cada
  /// construccion. Respeta la cancelacion (no auto-reintenta el mismo sitio),
  /// pero vuelve a sembrar si cambia el sitio.
  Future<void> ensureStarted() async {
    final store = ref.read(appStoreProvider);
    final settings = ref.read(settingsProvider);
    final knownSite = store.cachedSiteId ?? settings.siteId;
    if (_attempted && _attemptedSite == knownSite) return;
    _attempted = true;
    _attemptedSite = knownSite;
    await _run();
  }

  /// Disparo EXPLICITO (pull-to-refresh / reintentar): vuelve a intentar aunque
  /// antes se cancelara o fallara. No-op si ya esta sembrado o corriendo.
  Future<void> restart() => _run();

  Future<void> _run() async {
    if (state.running) return;
    final settings = ref.read(settingsProvider);
    if (!settings.isConfigured || !settings.monitorUnauthorised) return;
    final store = ref.read(appStoreProvider);
    final knownSite = store.cachedSiteId ?? settings.siteId;
    // Ya sembrado para este sitio: nada que hacer (el poller lo mantiene).
    if (knownSite.isNotEmpty && store.unauthBackfilledSite == knownSite) return;

    _cancelled = false;
    state = const UnauthBackfillState(running: true);
    final client = AdaptIQClient(
      settings,
      siteId: store.cachedSiteId,
      knownOptionalFields: store.cachedAdaptMacFields,
      equipmentField: store.cachedEquipmentField,
    );
    try {
      final now = DateTime.now().toUtc();
      final dispenses = await client.fetchDispensesProgressive(
        updatedFrom: now.subtract(kUnauthorisedBackfillWindow),
        isCancelled: () => _cancelled,
        onPage: (pages, scanned) =>
            state = state.copyWith(pages: pages, scanned: scanned),
      );
      if (_cancelled) {
        // Cancelado: no se marca el sitio como sembrado (restart() lo reintenta).
        state = const UnauthBackfillState();
        return;
      }
      // Todos los sin-ID del lote (ya acotado por la ventana del backfill); la
      // retencion y el filtro de periodo de la UI los acotan al mostrarlos.
      final found = detectUnassignedUnauthorised(
        dispenses: dispenses,
        normalizedLanes: settings.normalizedUnauthorisedLanes,
      );
      await store.mergeUnauthorisedOpen(found, now: now);
      await store.saveCachedSiteId(client.siteId);
      await store.saveUnauthBackfilledSite(client.siteId ?? knownSite);
      state = state.copyWith(running: false, found: found.length);
      // Republica el set recien sembrado en la UI (el poll incremental relee
      // el set fundido y lo expone en HealthCheckResult.unauthorised).
      await ref.read(consolesProvider.notifier).refreshNow();
    } on Object catch (e) {
      state = UnauthBackfillState(error: e.toString());
    } finally {
      client.close();
    }
  }

  /// Corta la pasada en curso (el usuario salio o pulso cancelar).
  void cancel() => _cancelled = true;
}
