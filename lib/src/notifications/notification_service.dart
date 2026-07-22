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
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';

import '../config/app_settings.dart';
import '../core/delivery_check.dart';
import '../core/flow_temp_check.dart';
import '../core/health_check.dart';
import '../core/sfl_check.dart';
import '../core/unauthorised_check.dart';
import '../core/util.dart';
import '../i18n/l10n.dart';
import '../models/adapt_mac.dart';
import '../models/delivery.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const int maxIndividual = 4;
  static const int _summaryNotificationId = 0x00ADAC; // fijo: el resumen se actualiza a si mismo
  static const int _deliverySummaryNotificationId = 0x00DE11;
  static const int _overfillSummaryNotificationId = 0x005F1;
  static const int _unauthorisedSummaryNotificationId = 0x00A17;
  static const int _flowTempSummaryNotificationId = 0x00F107;

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
    final l = L10n(settings.languageCode);

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
          title: _recoveryTitle(event, l),
          body: event.console.description ?? '',
          channel: _Channel.status,
        );
      } else {
        await _plugin.cancel(id);
      }
    }

    if (raised.length > maxIndividual) {
      final lines = [
        for (final e in raised)
          '${e.console.code} — ${_conditionLabel(e.condition, l)}',
      ];
      await _show(
        id: _summaryNotificationId,
        title: l.t('🔴 ${raised.length} consolas AdaptMAC con alertas',
            '🔴 ${raised.length} AdaptMAC consoles with alerts'),
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
    } else {
      for (final event in raised) {
        await _show(
          id: _idFor(event),
          title: _alertTitle(event, l),
          body: _alertBody(event, l),
          channel: event.condition == ConsoleCondition.stale
              ? _Channel.warning
              : _Channel.critical,
        );
      }
    }
  }

  /// Alarma "estilo despertador" para consolas OFFLINE no silenciadas que
  /// llevan caidas mas de `offlineAlarmMinutes`: canal de maxima importancia,
  /// sonido de alarma insistente, vibracion fuerte y, en Android, intent de
  /// pantalla completa. Cada consola tiene un id estable distinto del de su
  /// notificacion offline informativa, asi una NO reemplaza a la otra.
  Future<void> showOfflineAlarms(
    List<AdaptMac> consoles,
    AppSettings settings, {
    required Map<String, DateTime> offlineSince,
    required DateTime now,
  }) async {
    if (!_supported || consoles.isEmpty) return;
    await init();
    final l = L10n(settings.languageCode);
    for (final c in consoles) {
      final since = offlineSince[c.code];
      final mins =
          since == null ? settings.offlineAlarmMinutes : now.difference(since).inMinutes;
      await _showAlarm(
        id: stableId('offline-alarm/${c.code}'),
        title: l.t('⏰ ${c.code} lleva $mins min sin conexion',
            '⏰ ${c.code} offline for $mins min'),
        body: [
          if ((c.description ?? '').isNotEmpty) c.description!,
          l.t(
              'La consola sigue caida. Revisa la conexion del AdaptMAC.',
              'The console is still down. Check the AdaptMAC connection.'),
        ].join(' · '),
      );
    }
  }

  /// Publica las transiciones de despachos UNAUTHORISED sin ID. Una APERTURA
  /// (despacho no autorizado sin equipo) es una alerta; un CIERRE (AdaptIQ le
  /// asigno equipo) es una recuperacion que reemplaza a la alerta en la bandeja
  /// (o la retira si `notifyRecovery` esta apagado).
  Future<void> showUnauthorisedEvents(
      List<UnauthorisedEvent> events, AppSettings settings) async {
    if (!_supported || events.isEmpty) return;
    await init();
    final l = L10n(settings.languageCode);

    final raised = [for (final e in events) if (e.active) e];
    final cleared = [for (final e in events) if (!e.active) e];

    for (final event in cleared) {
      final id = stableId('unauth/${event.txn.id}');
      if (settings.notifyRecovery) {
        await _show(
          id: id,
          title: l.t('🟢 No autorizado con ID asignado',
              '🟢 Unauthorised dispense assigned an ID'),
          body: _unauthContext(event.txn, l),
          channel: _Channel.status,
        );
      } else {
        await _plugin.cancel(id);
      }
    }

    if (raised.length > maxIndividual) {
      final lines = [
        for (final e in raised)
          '${e.txn.shortRef} — ${_litres.format(e.txn.volume ?? 0)} L',
      ];
      await _show(
        id: _unauthorisedSummaryNotificationId,
        title: l.t('⚠️ ${raised.length} despachos sin ID (no autorizados)',
            '⚠️ ${raised.length} dispenses without ID (unauthorised)'),
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
    } else {
      for (final event in raised) {
        await _show(
          id: stableId('unauth/${event.txn.id}'),
          title: l.t('⚠️ Despacho no autorizado sin ID',
              '⚠️ Unauthorised dispense without ID'),
          body: _unauthContext(event.txn, l),
          channel: _Channel.critical,
        );
      }
    }
  }

  String _unauthContext(UnauthorisedTxn t, L10n l) => [
        if ((t.lane ?? '').isNotEmpty) t.lane!,
        if (t.volume != null) '${_litres.format(t.volume)} L',
        if ((t.product ?? '').isNotEmpty) t.product!,
        if ((t.fieldUser ?? '').isNotEmpty)
          '${l.t('Operador', 'Operator')}: ${t.fieldUser}',
        if (t.collectedAt != null)
          DateFormat('dd/MM HH:mm').format(t.collectedAt!.toLocal()),
      ].join(' · ');

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
    final l = L10n(settings.languageCode);

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
          title: l.t('🟢 Entrega ${event.delivery.label} confirmada',
              '🟢 Delivery ${event.delivery.label} confirmed'),
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
          '${e.delivery.label} — ${_deliveryConditionLabel(e, l)}',
      ];
      await _show(
        id: _deliverySummaryNotificationId,
        title: l.t('⛽ ${raised.length} entregas con anomalias',
            '⛽ ${raised.length} deliveries with anomalies'),
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
    } else {
      for (final event in raised) {
        await _show(
          id: _deliveryIdFor(event),
          title: _deliveryAlertTitle(event, l),
          body: _deliveryAlertBody(event, l),
          channel: event.condition == DeliveryCondition.unconfirmed ||
                  event.isCritical
              ? _Channel.critical
              : _Channel.warning,
        );
      }
    }
  }

  /// Publica los sobrellenados SFL nuevos del ciclo (eventos one-shot: el
  /// despacho ya ocurrio, no hay "recuperacion"). Mismo formato que la alarma
  /// "Equipment Overfill" de AdaptIQ: equipo + litros de exceso.
  Future<void> showOverfillEvents(
      List<OverfillAlert> alerts, AppSettings settings) async {
    if (!_supported || alerts.isEmpty) return;
    await init();
    final l = L10n(settings.languageCode);

    if (alerts.length > maxIndividual) {
      final lines = [
        for (final o in alerts)
          '${o.equipmentId} — ${l.t('exceso', 'excess')} ${_litres.format(o.excess)} L'
              '${(o.product ?? '').isEmpty ? '' : ' (${o.product})'}',
      ];
      await _show(
        id: _overfillSummaryNotificationId,
        title: l.t('🛢️ ${alerts.length} sobrellenados de SFL',
            '🛢️ ${alerts.length} SFL overfills'),
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
      return;
    }
    for (final o in alerts) {
      await _show(
        id: stableId('overfill/${o.dispenseId}'),
        title: l.t(
            '🛢️ ${o.equipmentId} sobrellenado +${_litres.format(o.excess)} L',
            '🛢️ ${o.equipmentId} overfill by ${_litres.format(o.excess)} L'),
        body: [
          if ((o.equipmentDescription ?? '').isNotEmpty)
            o.equipmentDescription!,
          if ((o.product ?? '').isNotEmpty) o.product!,
          '${_litres.format(o.volume)} L vs SFL ${_litres.format(o.sfl)} L',
          if ((o.fieldUser ?? '').isNotEmpty)
            '${l.t('Operador', 'Operator')}: ${o.fieldUser}',
          if (o.collectedAt != null)
            DateFormat('dd/MM HH:mm').format(o.collectedAt!.toLocal()),
        ].join(' · '),
        channel: o.isCritical ? _Channel.critical : _Channel.warning,
      );
    }
  }

  /// Publica las anomalias de caudal/temperatura nuevas del ciclo (eventos
  /// one-shot: el despacho ya ocurrio, no hay "recuperacion"). Un caudal alto o
  /// una temperatura alta son criticos (fraude/sensor roto); un caudal bajo,
  /// advertencia (obstruccion).
  Future<void> showFlowTempEvents(
      List<FlowTempAlert> alerts, AppSettings settings) async {
    if (!_supported || alerts.isEmpty) return;
    await init();
    final l = L10n(settings.languageCode);

    if (alerts.length > maxIndividual) {
      final lines = [
        for (final a in alerts)
          '${a.lane ?? a.equipmentId ?? a.dispenseId} — '
              '${_flowTempConditionLabel(a.conditions, a, l)}',
      ];
      await _show(
        id: _flowTempSummaryNotificationId,
        title: l.t('🌡️ ${alerts.length} anomalias de caudal/temperatura',
            '🌡️ ${alerts.length} flow/temperature anomalies'),
        body: lines.join(' · '),
        channel: _Channel.critical,
        inboxLines: lines,
      );
      return;
    }
    for (final a in alerts) {
      await _show(
        id: stableId('flowtemp/${a.dispenseId}'),
        title: _flowTempTitle(a, l),
        body: _flowTempBody(a, l),
        channel: a.isCritical ? _Channel.critical : _Channel.warning,
      );
    }
  }

  String _flowTempTitle(FlowTempAlert a, L10n l) {
    final icon = a.isCritical ? '🔴' : '🟠';
    final where = a.lane ?? a.equipmentId ?? a.dispenseId;
    return l.t('$icon ${_flowTempConditionLabel(a.conditions, a, l)} — $where',
        '$icon ${_flowTempConditionLabel(a.conditions, a, l)} — $where');
  }

  String _flowTempBody(FlowTempAlert a, L10n l) => [
        if (a.flowLpm != null)
          '${l.t('Caudal', 'Flow')} ${_litres.format(a.flowLpm)} L/min',
        if (a.peakFlowRate != null)
          '${l.t('pico', 'peak')} ${_litres.format(a.peakFlowRate)} L/min',
        if (a.temperatureC != null)
          '${a.temperatureC!.toStringAsFixed(1)} °C',
        if (a.volume != null) '${_litres.format(a.volume)} L',
        if ((a.product ?? '').isNotEmpty) a.product!,
        if ((a.fieldUser ?? '').isNotEmpty)
          '${l.t('Operador', 'Operator')}: ${a.fieldUser}',
        if (a.collectedAt != null)
          DateFormat('dd/MM HH:mm').format(a.collectedAt!.toLocal()),
      ].join(' · ');

  /// Etiqueta corta de la(s) anomalia(s) de una transaccion (la mas severa
  /// manda en el resumen). Caudal alto = medidor en vacio/bypass; bajo =
  /// obstruccion; temperatura fuera de rango = sensor averiado.
  String _flowTempConditionLabel(
      Set<FlowTempCondition> conditions, FlowTempAlert a, L10n l) {
    final parts = <String>[
      if (conditions.contains(FlowTempCondition.highFlow))
        l.t('caudal alto', 'high flow'),
      if (conditions.contains(FlowTempCondition.lowFlow))
        l.t('caudal bajo', 'low flow'),
      if (conditions.contains(FlowTempCondition.highTemp))
        l.t('temp. alta', 'high temp'),
      if (conditions.contains(FlowTempCondition.lowTemp))
        l.t('temp. baja', 'low temp'),
    ];
    return parts.join(' + ');
  }

  /// Notificacion de prueba desde la pantalla de configuracion.
  Future<void> showTest(L10n l) async {
    if (!_supported) return;
    await init();
    await _show(
      id: 1,
      title: l.t('✅ Notificaciones operativas', '✅ Notifications working'),
      body: l.t(
          'Asi se vera la alerta cuando una consola AdaptMAC pierda conexion.',
          'This is how the alert will look when an AdaptMAC console goes offline.'),
      channel: _Channel.status,
    );
  }

  // -- helpers -----------------------------------------------------------------

  int _idFor(ConsoleEvent e) => stableId('${e.console.code}/${e.condition.name}');

  int _deliveryIdFor(DeliveryEvent e) =>
      stableId('delivery/${e.delivery.id}/${e.condition.name}');

  static final NumberFormat _litres = NumberFormat('#,##0.0');

  String _deliveryConditionLabel(DeliveryEvent e, L10n l) =>
      switch (e.condition) {
        DeliveryCondition.unconfirmed => l.t('sin confirmar', 'unconfirmed'),
        DeliveryCondition.highVariance => l.t(
            'varianza ${e.delivery.deviationPct?.toStringAsFixed(2) ?? '?'}%',
            'variance ${e.delivery.deviationPct?.toStringAsFixed(2) ?? '?'}%'),
      };

  String _deliveryAlertTitle(DeliveryEvent e, L10n l) => switch (e.condition) {
        DeliveryCondition.unconfirmed => l.t(
            '🟡 Entrega ${e.delivery.label} sin confirmar',
            '🟡 Delivery ${e.delivery.label} unconfirmed'),
        DeliveryCondition.highVariance => l.t(
            '${e.isCritical ? '🔴' : '🟠'} Varianza '
                '${e.delivery.deviationPct?.toStringAsFixed(2) ?? '?'}% '
                'en entrega ${e.delivery.label}',
            '${e.isCritical ? '🔴' : '🟠'} Variance '
                '${e.delivery.deviationPct?.toStringAsFixed(2) ?? '?'}% '
                'on delivery ${e.delivery.label}'),
      };

  String _deliveryAlertBody(DeliveryEvent e, L10n l) {
    final d = e.delivery;
    final parts = <String>[_deliveryContext(d)];
    final measured = d.volume, field = d.secondaryVolume;
    if (measured != null && field != null) {
      parts.add(l.t(
          'Medido ${_litres.format(measured)} L vs guia ${_litres.format(field)} L',
          'Metered ${_litres.format(measured)} L vs docket ${_litres.format(field)} L'));
      final dev = d.deviationL ?? 0;
      if (dev < 0) {
        // La guia reclama mas litros de los que entraron al tanque: el caso
        // de sobre-facturacion / entrega partida.
        parts.add(l.t('faltan ${_litres.format(dev.abs())} L',
            '${_litres.format(dev.abs())} L short'));
      } else if (dev > 0) {
        parts.add(l.t('exceso de ${_litres.format(dev)} L sobre la guia',
            '${_litres.format(dev)} L over the docket'));
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

  String _conditionLabel(ConsoleCondition c, L10n l) => switch (c) {
        ConsoleCondition.offline => l.t('sin conexion', 'offline'),
        ConsoleCondition.keyBypass => l.t('modo BYPASS', 'BYPASS mode'),
        ConsoleCondition.stale => l.t('comunicacion stale', 'stale comms'),
      };

  String _alertTitle(ConsoleEvent e, L10n l) => switch (e.condition) {
        ConsoleCondition.offline => l.t('🔴 ${e.console.code} sin conexion',
            '🔴 ${e.console.code} offline'),
        ConsoleCondition.keyBypass => l.t(
            '🚨 ${e.console.code} en modo BYPASS',
            '🚨 ${e.console.code} in BYPASS mode'),
        ConsoleCondition.stale => l.t('🟠 ${e.console.code} sin comunicar',
            '🟠 ${e.console.code} not communicating'),
      };

  String _alertBody(ConsoleEvent e, L10n l) {
    final desc = e.console.description ?? '';
    switch (e.condition) {
      case ConsoleCondition.offline:
        final last = e.console.lastSuccessfulComms;
        final lastTxt = last == null
            ? ''
            : ' · ${l.t('Ult. comunicacion', 'Last comms')} '
                '${DateFormat('dd/MM HH:mm').format(last.toLocal())}';
        return '$desc$lastTxt'.trim();
      case ConsoleCondition.keyBypass:
        return '$desc · ${l.t('La consola despacha sin autorizacion: trazabilidad comprometida.', 'The console dispenses without authorisation: traceability compromised.')}'
            .trim();
      case ConsoleCondition.stale:
        final last = e.console.lastSuccessfulComms;
        final mins = last == null ? null : e.at.difference(last).inMinutes;
        return '$desc · ${l.t('En linea pero sin comunicacion exitosa', 'Online but without successful comms')}'
                '${mins == null ? '' : l.t(' hace $mins min', ' for $mins min')}.'
            .trim();
    }
  }

  String _recoveryTitle(ConsoleEvent e, L10n l) => switch (e.condition) {
        ConsoleCondition.offline => l.t('🟢 ${e.console.code} reconectada',
            '🟢 ${e.console.code} back online'),
        ConsoleCondition.keyBypass => l.t(
            '🟢 ${e.console.code} salio de modo BYPASS',
            '🟢 ${e.console.code} left BYPASS mode'),
        ConsoleCondition.stale => l.t(
            '🟢 ${e.console.code} comunicando de nuevo',
            '🟢 ${e.console.code} communicating again'),
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

  /// Variante "despertador": sonido de alarma insistente (se repite hasta
  /// descartar), vibracion fuerte, categoria alarm e intent de pantalla
  /// completa (Android). En iOS, nivel de interrupcion time-sensitive para
  /// romper el modo Concentracion sin requerir el permiso de alertas criticas.
  Future<void> _showAlarm({
    required int id,
    required String title,
    required String body,
  }) async {
    final android = AndroidNotificationDetails(
      _Channel.alarm.id,
      _Channel.alarm.name,
      channelDescription: _Channel.alarm.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // FLAG_INSISTENT (0x4): el sonido se repite hasta que el usuario la
      // descarta — el comportamiento "despertador" que pidio el operador.
      additionalFlags: Int32List.fromList(<int>[4]),
      enableVibration: true,
      vibrationPattern: Int64List.fromList(<int>[0, 600, 300, 600, 300, 600]),
    );
    const darwin = DarwinNotificationDetails(
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(android: android, iOS: darwin),
    );
  }
}

enum _Channel {
  alarm(
    'adaptmac_alarm',
    'Alarmas de caida prolongada',
    'Consola sin conexion 30+ min (alarma estilo despertador)',
    Importance.max,
    Priority.high,
  ),
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
