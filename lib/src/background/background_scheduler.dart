/// Tareas periodicas con la app cerrada (Workmanager).
///
///   * Android: WorkManager nativo — periodicidad minima de 15 min, persiste
///     reinicios del dispositivo y respeta Doze. Se exige red conectada.
///   * iOS: BGAppRefreshTask (BGTaskScheduler) — el identificador debe estar
///     en `BGTaskSchedulerPermittedIdentifiers` (Info.plist) y registrado en
///     AppDelegate.swift, donde tambien se fija la frecuencia minima. iOS
///     decide el momento real segun el patron de uso de la app.
///
/// El callback corre en un isolate propio SIN acceso al estado de la app: por
/// eso `runHealthCheck` reconstruye todo desde shared_preferences.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:workmanager/workmanager.dart';

import '../config/app_settings.dart';
import 'health_runner.dart';

/// Nombre unico de registro (Android cancela/reemplaza por este nombre).
const kHealthTaskUniqueName = 'adaptmac-health-poll';

/// Nombre logico de la tarea que llega al dispatcher. En iOS es ADEMAS el
/// identificador de BGTaskScheduler: debe coincidir con el Info.plist y el
/// AppDelegate.swift.
const kHealthTaskName = 'io.veridapt.merian.adaptmac.healthCheck';

/// Punto de entrada del isolate de background. Debe ser una funcion top-level
/// con @pragma para sobrevivir al tree-shaking en release.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // Cualquier tarea que nos despierte (la periodica de Android o el fetch de
    // iOS) significa lo mismo: chequear la salud de las consolas.
    try {
      await runHealthCheck();
      return true;
    } on NotConfiguredException {
      return true; // sin token no hay nada que reintentar
    } on Object {
      return false; // transitorio: WorkManager re-agenda con backoff
    }
  });
}

class BackgroundScheduler {
  static bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<void> init() async {
    if (!_supported) return;
    await Workmanager().initialize(callbackDispatcher);
  }

  /// Alinea el registro de la tarea periodica con la configuracion actual.
  /// Idempotente: se llama en cada arranque y en cada guardado de ajustes.
  static Future<void> sync(AppSettings settings) async {
    if (!_supported) return;
    if (!settings.isConfigured || !settings.notificationsEnabled) {
      await Workmanager().cancelByUniqueName(
          Platform.isIOS ? kHealthTaskName : kHealthTaskUniqueName);
      return;
    }
    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        kHealthTaskUniqueName,
        kHealthTaskName,
        // Android impone un minimo de 15 min para tareas periodicas.
        frequency: Duration(minutes: settings.backgroundMinutes.clamp(15, 24 * 60)),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } else if (Platform.isIOS) {
      // El nombre unico DEBE ser el identificador permitido en Info.plist.
      // La frecuencia real la fija AppDelegate.swift; iOS la trata como "no
      // antes de" y la modula segun el uso de la app.
      await Workmanager().registerPeriodicTask(kHealthTaskName, kHealthTaskName);
    }
  }
}
