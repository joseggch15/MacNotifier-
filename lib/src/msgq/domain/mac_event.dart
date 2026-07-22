/// Eventos observados de salud de consolas AdaptMAC — port de
/// `transform.adaptmac_events_df` + `ADAPTMAC_HISTORY_COLS`.
///
/// El endpoint NO guarda historial de consolas: verificado en vivo, el log de
/// auditoria no registra AdaptMacs y el tipo solo expone el estado ACTUAL mas
/// `lastSuccessfulComms` / `lastFailedComms`. El historial se construye por
/// OBSERVACION — comparando el maestro recien descargado contra el replicado —
/// y es lo unico que permite responder "cuantas veces se cayo esta consola" o
/// "cuanto duro el corte".
///
/// Consecuencia que conviene tener presente al leer los datos: el historial es
/// FORWARD-ONLY. Solo existe desde que la app empezo a observar; lo anterior no
/// se puede reconstruir.
///
/// Dart puro y null-safe.
library;

import '../../models/adapt_mac.dart';
import 'node_parsing.dart';

/// Taxonomia OBSERVABLE de fallas. La API no expone codigos de falla del
/// hardware, asi que esto es todo lo que se puede afirmar desde fuera.
enum MacEventKind {
  offline('OFFLINE', 'Caida de conexion'),
  online('ONLINE', 'Recuperacion'),
  failedComms('FAILED_COMMS', 'Fallo de comunicacion'),
  bypassOn('BYPASS_ON', 'Bypass activado'),
  bypassOff('BYPASS_OFF', 'Bypass desactivado');

  const MacEventKind(this.wire, this.label);

  final String wire;
  final String label;

  /// Eventos que cuentan como FALLA en los resumenes. La recuperacion y el fin
  /// del bypass son informativos: contarlos como problema inflaria cada conteo.
  bool get isFault =>
      this == MacEventKind.offline ||
      this == MacEventKind.failedComms ||
      this == MacEventKind.bypassOn;

  static MacEventKind? fromWire(String? value) {
    if (value == null) return null;
    final up = value.trim().toUpperCase();
    for (final k in MacEventKind.values) {
      if (k.wire == up) return k;
    }
    return null;
  }
}

/// Un evento observado de salud de consola.
class MacEvent {
  const MacEvent({
    required this.eventKey,
    required this.code,
    this.description,
    required this.kind,
    required this.ts,
    this.detail,
    this.online,
    this.keyBypass,
  });

  /// `code|kind|ts` — PK sintetica que hace idempotente el upsert entre ciclos.
  final String eventKey;

  final String code;
  final String? description;
  final MacEventKind kind;

  /// Instante REAL del dispositivo cuando se conoce (`lastFailedComms` o el
  /// `lastSuccessfulComms` congelado al caer); si no, el de observacion.
  final DateTime ts;

  final String? detail;
  final bool? online;
  final bool? keyBypass;

  factory MacEvent.fromJson(Map<String, dynamic> json) => MacEvent(
        eventKey: (json['event_key'] ?? '').toString(),
        code: (json['code'] ?? '').toString(),
        description: asText(json['description']),
        kind: MacEventKind.fromWire(json['kind'] as String?) ??
            MacEventKind.offline,
        ts: asDate(json['ts']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        detail: asText(json['detail']),
        online: asBool(json['online']),
        keyBypass: asBool(json['key_bypass']),
      );

  Map<String, dynamic> toJson() => {
        'event_key': eventKey,
        'code': code,
        'description': description,
        'kind': kind.wire,
        'ts': isoOrNull(ts),
        'detail': detail,
        'online': online,
        'key_bypass': keyBypass,
      };

  @override
  String toString() => 'MacEvent($code ${kind.wire} @ $ts)';
}

/// Deriva los eventos comparando el maestro recien descargado contra el
/// replicado.
///
/// Reglas, y el porque de cada timestamp:
///
///   * `online` true -> false: CAIDA. El dispositivo congela
///     `lastSuccessfulComms` justo al caer, asi que ese es el momento REAL del
///     corte — mejor que la hora de observacion, que llega hasta un ciclo tarde.
///   * `online` false -> true: RECUPERACION, con la misma logica al reves.
///   * `lastFailedComms` avanza: FALLO DE COMUNICACION, con el timestamp del
///     equipo aunque el fallo haya ocurrido entre dos sincronizaciones.
///   * `keyBypass` on/off: BYPASS, con la hora de observacion (no hay marca del
///     dispositivo para esto).
///
/// Una consola SIN fila previa no emite transiciones —no hay contra que
/// comparar, y hacerlo inundaria el historial al estrenar la tabla—, salvo dos
/// siembras deliberadas: su ultimo fallo conocido, y el inicio del corte si ya
/// esta caida. Sin esa segunda siembra, una consola caida desde antes del
/// monitoreo no tendria episodio nunca.
List<MacEvent> diffMacSnapshots({
  required List<AdaptMac> previous,
  required List<AdaptMac> current,
  required DateTime observedAt,
}) {
  final before = {for (final m in previous) m.code: m};
  final events = <MacEvent>[];

  void emit(
    AdaptMac console,
    MacEventKind kind,
    DateTime ts,
    String detail,
  ) {
    events.add(MacEvent(
      eventKey: '${console.code}|${kind.wire}|${ts.toUtc().toIso8601String()}',
      code: console.code,
      description: console.description,
      kind: kind,
      ts: ts.toUtc(),
      detail: detail,
      online: console.online,
      keyBypass: console.keyBypass,
    ));
  }

  for (final now in current) {
    if (now.code.isEmpty) continue;
    final prev = before[now.code];
    final failed = now.lastFailedComms;
    final ok = now.lastSuccessfulComms;

    if (prev == null) {
      if (failed != null) {
        emit(now, MacEventKind.failedComms, failed,
            'Ultimo fallo de comunicacion conocido (siembra)');
      }
      if (now.online == false) {
        emit(now, MacEventKind.offline, ok ?? observedAt,
            'Consola fuera de linea al iniciar el monitoreo');
      }
      continue;
    }

    if (prev.online == true && now.online == false) {
      final at = ok ?? observedAt;
      emit(now, MacEventKind.offline, at,
          ok == null ? 'Consola dejo de responder' : 'Consola dejo de responder '
              '(ultima comm OK: ${_stamp(ok)})');
    } else if (prev.online == false && now.online == true) {
      emit(now, MacEventKind.online, ok ?? observedAt,
          'Consola recupero conexion');
    }

    final prevFailed = prev.lastFailedComms;
    if (failed != null && (prevFailed == null || failed.isAfter(prevFailed))) {
      emit(now, MacEventKind.failedComms, failed,
          'Fallo de comunicacion reportado por el equipo '
          '(${now.online == false ? "offline" : "online"})');
    }

    if (prev.keyBypass == false && now.keyBypass == true) {
      emit(now, MacEventKind.bypassOn, observedAt, 'Modo bypass ACTIVADO');
    } else if (prev.keyBypass == true && now.keyBypass == false) {
      emit(now, MacEventKind.bypassOff, observedAt, 'Modo bypass desactivado');
    }
  }
  return List.unmodifiable(events);
}

String _stamp(DateTime at) {
  final local = at.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Fila de la replica para una consola del maestro.
///
/// El modelo [AdaptMac] es el del notificador y serializa en camelCase; la
/// replica usa el esquema canonico de MSGQ (snake_case) para poder compararse
/// fila a fila con el escritorio, asi que la conversion vive aqui.
Map<String, dynamic> macConsoleToRow(AdaptMac console) => {
      'code': console.code,
      'description': console.description,
      'site': console.site,
      'erp_reference': console.erpReference,
      'online': console.online,
      'key_bypass': console.keyBypass,
      'last_successful_comms': isoOrNull(console.lastSuccessfulComms),
      'last_failed_comms': isoOrNull(console.lastFailedComms),
      'updated_at': isoOrNull(console.updatedAt),
    };

AdaptMac macConsoleFromRow(Map<String, dynamic> row) => AdaptMac(
      code: (row['code'] ?? '').toString(),
      description: asText(row['description']),
      site: asText(row['site']),
      erpReference: asText(row['erp_reference']),
      online: asBool(row['online']),
      keyBypass: asBool(row['key_bypass']),
      lastSuccessfulComms: asDate(row['last_successful_comms']),
      lastFailedComms: asDate(row['last_failed_comms']),
      updatedAt: asDate(row['updated_at']),
    );
