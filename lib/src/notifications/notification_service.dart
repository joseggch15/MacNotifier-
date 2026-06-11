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
import '../core/delivery_check.dart';
import '../core/health_check.dart';
import '../core/util.dart';
import '../models/delivery.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const int maxIndividual = 4;
  static const int _summaryNotificationId = 0x00ADAC; // fijo: el resumen se actualiza a si mismo
  static const int _deliverySummaryNotificationId = 0x00DE11;

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

  /// Publica las notificaciones de un ciclo de auditoria de ENTREGAS.
  ///
  /// Mismas reglas de presentacion que las consolas: id estable por
  /// (entrega, condicion), la confirmacion reemplaza a la alerta de
  /// "sin confirmar" en la bandeja, y un ciclo con muchas alzas (p. ej. la
  /// primera sincronizacion) se agrupa en una notificacion resumen.
  Future<void> showDeliveryEvents(
      List<DeliveryEvent> events, AppSettings settings) async {
    if (!_supported || events.isEmpty) return;
    await init();

    final raised = [for (final e in events) if (e.active) e];
    final cleared = [for (final e in events) if (!e.active) e];

    for (final event in cleared) {
      final id = _deliveryIdFor(event);
      // La unica "recuperacion" noticiable es la CONFIRMACION de una entrega
      // que estaba sin confirmar; una varianza que se corrige (entrega
      // editada) simplemente retira la alerta de la bandeja.
      if (event.condition == DeliveryCondition.unconfirmed &&
          settings.notifyRecovery) {
        await _show(
          id: id,
          title: '🟢 Entrega ${event.delivery.label} confirmada',
          body: _deliveryContext(event.delivery),
          channel: _Channel.status,
        );
      } else {
        await _plugin.cancel(id);
      }
    }

    if (raised.length > maxIndividual) {
      final lines = [
        for (final e in raised)
          '${e.delivery.label} — ${_deliveryConditionLabel(e)}',
      ];
      await _show(
        id: _deliverySummaryNotificationId,
        title: '⛽ ${raised.length} entregas con anomalias',
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
    } else {
      for (final event in raised) {
        await _show(
          id: _deliveryIdFor(event),
          title: _deliveryAlertTitle(event),
          body: _deliveryAlertBody(event),
          channel: event.condition == DeliveryCondition.unconfirmed ||
                  event.isCritical
              ? _Channel.critical
              : _Channel.warning,
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

  int _deliveryIdFor(DeliveryEvent e) =>
      stableId('delivery/${e.delivery.id}/${e.condition.name}');

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  String _deliveryConditionLabel(DeliveryEvent e) =>
      switch (e.condition) {
        DeliveryCondition.unconfirmed => 'sin confirmar',
        DeliveryCondition.highVariance =>
          'varianza ${e.delivery.deviationPct?.toStringAsFixed(2) ?? '?'}%',
      };

  String _deliveryAlertTitle(DeliveryEvent e) => switch (e.condition) {
        DeliveryCondition.unconfirmed =>
          '🟡 Entrega ${e.delivery.label} sin confirmar',
        DeliveryCondition.highVariance =>
          '${e.isCritical ? '🔴' : '🟠'} Varianza '
              '${e.delivery.deviationPct?.toStringAsFixed(2) ?? '?'}% '
              'en entrega ${e.delivery.label}',
      };

  String _deliveryAlertBody(DeliveryEvent e) {
    final d = e.delivery;
    final parts = <String>[_deliveryContext(d)];
    final measured = d.volume, field = d.secondaryVolume;
    if (measured != null && field != null) {
      parts.add(
          'Medido ${_litres.format(measured)} L vs guia ${_litres.format(field)} L');
      final dev = d.deviationL ?? 0;
      if (dev < 0) {
        // La guia reclama mas litros de los que entraron al tanque: el caso
        // de sobre-facturacion / entrega partida.
        parts.add('faltan ${_litres.format(dev.abs())} L');
      } else if (dev > 0) {
        parts.add('exceso de ${_litres.format(dev)} L sobre la guia');
      }
    }
    return parts.where((p) => p.isNotEmpty).join(' · ');
  }

  String _deliveryContext(Delivery d) {
    final when = d.collectedAt;
    return [
      if ((d.tank ?? '').isNotEmpty) d.tank!,
      if ((d.product ?? '').isNotEmpty) d.product!,
      if (when != null) DateFormat('dd/MM HH:mm').format(when.toLocal()),
    ].join(' · ');
  }

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
