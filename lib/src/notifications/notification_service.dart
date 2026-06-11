/// Notificaciones locales de salud de consolas.
///
/// Reglas de presentacion:
///
///   * Cada (consola, condicion) tiene un id de notificacion ESTABLE: la
///     recuperacion reemplaza a la alerta en la bandeja (no se apilan), y si
///     la recuperacion esta desactivada, la alerta simplemente se retira.
///   * Mas de [maxIndividual] alzas en un mismo ciclo se agrupan en UNA
///     notificacion resumen — una caida de red del sitio tumbaria las 22
///     consolas a la vez y no queremos 22 banners.
///   * Canales Android separados por gravedad, para que el usuario pueda
///     silenciar lo informativo sin perder lo critico.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';

import '../config/app_settings.dart';
import '../core/health_check.dart';
import '../core/util.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const int maxIndividual = 4;
  static const int _summaryNotificationId = 0x00ADAC; // fijo: el resumen se actualiza a si mismo

  static bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> init() async {
    if (_ready || !_supported) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    // Los permisos NO se piden aqui: init() tambien corre en el isolate de
    // background, donde no hay UI para el dialogo. Se piden desde la pantalla
    // principal via requestPermissions().
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
    );
    _ready = true;
  }

  Future<void> requestPermissions() async {
    if (!_supported) return;
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  /// Publica las notificaciones de un ciclo de chequeo.
  Future<void> showEvents(List<ConsoleEvent> events, AppSettings settings) async {
    if (!_supported || events.isEmpty) return;
    await init();

    final raised = [for (final e in events) if (e.active) e];
    final cleared = [for (final e in events) if (!e.active) e];

    for (final event in cleared) {
      final id = _idFor(event);
      // Solo offline y bypass tienen recuperacion "noticiable"; el stale que
      // se despeja sale de la bandeja en silencio.
      final notify = settings.notifyRecovery &&
          (event.condition == ConsoleCondition.offline ||
              event.condition == ConsoleCondition.keyBypass);
      if (notify) {
        await _show(
          id: id,
          title: _recoveryTitle(event),
          body: event.console.description ?? '',
          channel: _Channel.status,
        );
      } else {
        await _plugin.cancel(id);
      }
    }

    if (raised.length > maxIndividual) {
      final lines = [
        for (final e in raised) '${e.console.code} — ${_conditionLabel(e.condition)}',
      ];
      await _show(
        id: _summaryNotificationId,
        title: '🔴 ${raised.length} consolas AdaptMAC con alertas',
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
    } else {
      for (final event in raised) {
        await _show(
          id: _idFor(event),
          title: _alertTitle(event),
          body: _alertBody(event),
          channel: event.condition == ConsoleCondition.stale
              ? _Channel.warning
              : _Channel.critical,
        );
      }
    }
  }

  /// Notificacion de prueba desde la pantalla de configuracion.
  Future<void> showTest() async {
    if (!_supported) return;
    await init();
    await _show(
      id: 1,
      title: '✅ Notificaciones operativas',
      body: 'Asi se vera la alerta cuando una consola AdaptMAC pierda conexion.',
      channel: _Channel.status,
    );
  }

  // -- helpers -----------------------------------------------------------------

  int _idFor(ConsoleEvent e) => stableId('${e.console.code}/${e.condition.name}');

  String _conditionLabel(ConsoleCondition c) => switch (c) {
        ConsoleCondition.offline => 'sin conexion',
        ConsoleCondition.keyBypass => 'modo BYPASS',
        ConsoleCondition.stale => 'comunicacion stale',
      };

  String _alertTitle(ConsoleEvent e) => switch (e.condition) {
        ConsoleCondition.offline => '🔴 ${e.console.code} sin conexion',
        ConsoleCondition.keyBypass => '🚨 ${e.console.code} en modo BYPASS',
        ConsoleCondition.stale => '🟠 ${e.console.code} sin comunicar',
      };

  String _alertBody(ConsoleEvent e) {
    final desc = e.console.description ?? '';
    switch (e.condition) {
      case ConsoleCondition.offline:
        final last = e.console.lastSuccessfulComms;
        final lastTxt = last == null
            ? ''
            : ' · Ult. comunicacion ${DateFormat('dd/MM HH:mm').format(last.toLocal())}';
        return '$desc$lastTxt'.trim();
      case ConsoleCondition.keyBypass:
        return '$desc · La consola despacha sin autorizacion: trazabilidad comprometida.'
            .trim();
      case ConsoleCondition.stale:
        final last = e.console.lastSuccessfulComms;
        final mins = last == null ? null : e.at.difference(last).inMinutes;
        return '$desc · En linea pero sin comunicacion exitosa'
                '${mins == null ? '' : ' hace $mins min'}.'
            .trim();
    }
  }

  String _recoveryTitle(ConsoleEvent e) => switch (e.condition) {
        ConsoleCondition.offline => '🟢 ${e.console.code} reconectada',
        ConsoleCondition.keyBypass => '🟢 ${e.console.code} salio de modo BYPASS',
        ConsoleCondition.stale => '🟢 ${e.console.code} comunicando de nuevo',
      };

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required _Channel channel,
    List<String>? inboxLines,
  }) async {
    final android = AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: channel.importance,
      priority: channel.priority,
      styleInformation: inboxLines == null
          ? null
          : InboxStyleInformation(inboxLines, summaryText: 'AdaptMAC Monitor'),
    );
    const darwin = DarwinNotificationDetails();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: darwin),
    );
  }
}

enum _Channel {
  critical(
    'adaptmac_critical',
    'Alertas criticas',
    'Consola sin conexion o en modo bypass',
    Importance.max,
    Priority.high,
  ),
  warning(
    'adaptmac_warning',
    'Advertencias',
    'Comunicacion stale y otras advertencias',
    Importance.defaultImportance,
    Priority.defaultPriority,
  ),
  status(
    'adaptmac_status',
    'Estado',
    'Recuperaciones y avisos informativos',
    Importance.defaultImportance,
    Priority.defaultPriority,
  );

  const _Channel(this.id, this.name, this.description, this.importance, this.priority);

  final String id;
  final String name;
  final String description;
  final Importance importance;
  final Priority priority;
}
