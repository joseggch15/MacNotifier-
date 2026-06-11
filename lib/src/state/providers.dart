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

import '../background/background_scheduler.dart';
import '../background/health_runner.dart';
import '../config/app_settings.dart';
import '../core/health_check.dart';
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
