/// Vigilancia de despachos UNAUTHORISED sin equipo asignado.
///
/// En AdaptIQ, un despacho `Unauthorised` es combustible entregado sin validar
/// el tag/llave del equipo (key bypass o tag desconocido). El auditor lo revisa
/// en Movements -> Dispenses con el filtro `Types: Unauthorised`: algunos ya
/// traen un Equipment ID (AdaptIQ los reconcilio con un equipo) y otros quedan
/// SIN ID — esos son los que importan, porque ese combustible no esta cargado a
/// ningun equipo todavia.
///
/// Este monitor aisla, de un conjunto de lanes vigilados, los despachos
/// `Unauthorised` cuyo `equipmentId` esta en blanco. Tan pronto AdaptIQ le
/// asigna un equipo (el `recordUpdatedAt` cambia y la consulta incremental lo
/// vuelve a traer con ID), el despacho SALE de la lista y se considera resuelto.
///
/// "Sin ID" replica el set `_BLANK` de `msgq/core/tag_hopping.py`: AdaptIQ deja
/// el equipo vacio o literalmente `UNAUTHORISED` hasta reconciliar.
///
/// El dedup es el mismo patron incremental que entregas: se persiste el
/// conjunto de despachos ABIERTOS (id -> txn) y solo las transiciones —aparece
/// uno nuevo / se le asigna equipo— emiten eventos. Dart puro: testeable sin
/// emulador.
library;

import '../config/app_settings.dart';
import '../i18n/l10n.dart';
import '../models/dispense.dart';

/// Valores de `equipmentId` que cuentan como "sin ID asignado" (set `_BLANK`
/// de MSGQ, normalizados a mayusculas).
const _blankEquipmentIds = {'', '<NA>', 'NAN', 'NONE', 'NULL', 'UNAUTHORISED'};

/// Un `equipmentId` ausente, vacio o marcado como no autorizado = sin equipo.
bool isBlankEquipmentId(String? equipmentId) {
  final u = (equipmentId ?? '').trim().toUpperCase();
  return u.isEmpty || _blankEquipmentIds.contains(u);
}

/// Un despacho `Unauthorised` SIN equipo asignado, en un lane vigilado.
class UnauthorisedTxn {
  const UnauthorisedTxn({
    required this.id,
    this.lane,
    this.volume,
    this.product,
    this.fieldUser,
    this.adaptMac,
    this.collectedAt,
    this.firstSeen,
  });

  final String id;

  /// Punto de despacho (source aplanado): LFO Dispense Lane 2, etc.
  final String? lane;
  final double? volume;
  final String? product;
  final String? fieldUser;
  final String? adaptMac;

  /// Cuando ocurrio el despacho (recordCollectedAt).
  final DateTime? collectedAt;

  /// Cuando el monitor lo vio por primera vez como "abierto" (para podar
  /// entradas que nunca llegan a asignarse).
  final DateTime? firstSeen;

  /// Referencia corta para titulos/agrupados.
  String get shortRef => (lane ?? '').isNotEmpty ? lane! : id;

  factory UnauthorisedTxn.fromDispense(Dispense d, {DateTime? firstSeen}) =>
      UnauthorisedTxn(
        id: d.id,
        lane: dispensingPoint(d), // el lane (consola), no el tanque virtual
        volume: d.volume,
        product: d.product,
        fieldUser: d.fieldUser,
        adaptMac: d.adaptMac,
        collectedAt: d.collectedAt,
        firstSeen: firstSeen,
      );

  UnauthorisedTxn copyWith({DateTime? firstSeen}) => UnauthorisedTxn(
        id: id,
        lane: lane,
        volume: volume,
        product: product,
        fieldUser: fieldUser,
        adaptMac: adaptMac,
        collectedAt: collectedAt,
        firstSeen: firstSeen ?? this.firstSeen,
      );

  factory UnauthorisedTxn.fromJson(Map<String, dynamic> json) =>
      UnauthorisedTxn(
        id: (json['id'] ?? '').toString(),
        lane: json['lane'] as String?,
        volume: (json['volume'] as num?)?.toDouble(),
        product: json['product'] as String?,
        fieldUser: json['fieldUser'] as String?,
        adaptMac: json['adaptMac'] as String?,
        collectedAt: json['collectedAt'] is String
            ? DateTime.tryParse(json['collectedAt'] as String)?.toUtc()
            : null,
        firstSeen: json['firstSeen'] is String
            ? DateTime.tryParse(json['firstSeen'] as String)?.toUtc()
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'lane': lane,
        'volume': volume,
        'product': product,
        'fieldUser': fieldUser,
        'adaptMac': adaptMac,
        'collectedAt': collectedAt?.toIso8601String(),
        'firstSeen': firstSeen?.toIso8601String(),
      };
}

/// Una transicion: un despacho aparecio sin ID (`active = true`) o se le asigno
/// equipo / dejo de ser no autorizado (`active = false`).
class UnauthorisedEvent {
  const UnauthorisedEvent({
    required this.txn,
    required this.active,
    required this.at,
  });

  final UnauthorisedTxn txn;
  final bool active;
  final DateTime at;
}

/// El "Dispensing Point" (lane) del despacho. La API NO expone el medidor como
/// campo del Dispense; el lane se identifica por la CONSOLA AdaptMAC (su
/// descripcion = "LFO Dispense Lane 3", su codigo = "MER.3"). El tanque origen
/// ("LFO - Virtual Tank") es comun a los 3 lanes y NO sirve para distinguir.
String? dispensingPoint(Dispense d) {
  final desc = (d.adaptMacDescription ?? '').trim();
  if (desc.isNotEmpty) return desc;
  final code = (d.adaptMac ?? '').trim();
  if (code.isNotEmpty) return code;
  final tank = (d.tank ?? '').trim();
  return tank.isEmpty ? null : tank;
}

/// ¿El despacho ocurrio en alguno de los lanes vigilados? Se acepta cualquier
/// coincidencia entre la descripcion de la consola, su codigo o (como ultimo
/// recurso) el tanque — asi el usuario puede configurar el lane por su nombre
/// ("LFO Dispense Lane 3") o por el codigo de consola ("MER.3").
bool laneMatches(Dispense d, Set<String> normalizedLanes) {
  for (final candidate in [d.adaptMacDescription, d.adaptMac, d.tank]) {
    final n = normProduct(candidate);
    if (n.isNotEmpty && normalizedLanes.contains(n)) return true;
  }
  return false;
}

/// Predicado: ¿es este despacho un `Unauthorised` SIN ID en un lane vigilado?
///
/// AdaptIQ marca "no autorizado" por DOS vias (ver `_BLANK` en MSGQ): el `type`
/// del movimiento ("Unauthorised") y/o el `equipmentId` puesto literalmente en
/// "UNAUTHORISED". Basta cualquiera de las dos — ambas ramas exigen ademas lane
/// vigilado y equipo en blanco, asi que un despacho AUTORIZADO con id vacio (una
/// captura manual rara) no se cuela.
bool isUnassignedUnauthorised(Dispense d, Set<String> normalizedLanes) {
  if (!laneMatches(d, normalizedLanes)) return false;
  if (!isBlankEquipmentId(d.equipmentId)) return false;
  final typeIsUnauth = (d.type ?? '').toUpperCase().contains('UNAUTH');
  final idIsUnauthMarker =
      (d.equipmentId ?? '').trim().toUpperCase() == 'UNAUTHORISED';
  return typeIsUnauth || idIsUnauthMarker;
}

/// Compara los despachos RECIEN consultados contra los abiertos ya conocidos y
/// devuelve los eventos + el mapa actualizado de abiertos para persistir.
///
/// Solo se evaluan los despachos presentes en [fetched] (la consulta es
/// incremental): un abierto que no cambio no aparece en [fetched] y permanece
/// intacto. Cuando un abierto reaparece con ID asignado (o ya no es
/// unauthorised), se cierra y emite un evento `active = false`.
({List<UnauthorisedEvent> events, Map<String, UnauthorisedTxn> updatedOpen})
    diffUnauthorised({
  required Map<String, UnauthorisedTxn> previousOpen,
  required List<Dispense> fetched,
  required Set<String> normalizedLanes,
  required DateTime now,
}) {
  final open = {...previousOpen};
  final events = <UnauthorisedEvent>[];
  for (final d in fetched) {
    final was = previousOpen[d.id];
    if (isUnassignedUnauthorised(d, normalizedLanes)) {
      // Conserva el firstSeen original si ya estaba abierto.
      final txn =
          UnauthorisedTxn.fromDispense(d, firstSeen: was?.firstSeen ?? now);
      open[d.id] = txn;
      if (was == null) {
        events.add(UnauthorisedEvent(txn: txn, active: true, at: now));
      }
    } else if (was != null) {
      // Reaparecio reconciliado (con ID) o cambio de tipo: se cierra.
      open.remove(d.id);
      events.add(UnauthorisedEvent(txn: was, active: false, at: now));
    }
  }
  events.sort((a, b) {
    if (a.active != b.active) return a.active ? -1 : 1; // aperturas primero
    final ta = a.txn.collectedAt ?? DateTime(0);
    final tb = b.txn.collectedAt ?? DateTime(0);
    return tb.compareTo(ta);
  });
  return (events: events, updatedOpen: open);
}

/// Ordena los abiertos para la UI: mas recientes primero.
List<UnauthorisedTxn> sortedOpen(Iterable<UnauthorisedTxn> open) {
  final list = open.toList()
    ..sort((a, b) {
      final ta = a.collectedAt ?? DateTime(0);
      final tb = b.collectedAt ?? DateTime(0);
      return tb.compareTo(ta);
    });
  return list;
}

/// Segmento temporal de la pestaña "Sin ID", inspirado en las ventanas de
/// Reportes (diario/semanal/mensual/anual) + un "Todos" sin recorte. La API no
/// permite filtrar por tipo ni por equipo-en-blanco server-side (MovementQuery
/// solo expone updatedFrom/updatedTo/createdFrom/createdTo/excludeType), asi que
/// el segmento define la VENTANA a consultar y el filtro de no-autorizado-sin-ID
/// se aplica client-side, igual que Reportes.
enum UnauthPeriod { all, daily, weekly, monthly, yearly }

extension UnauthPeriodX on UnauthPeriod {
  String label(L10n l) => switch (this) {
        UnauthPeriod.all => l.t('Todos', 'All'),
        UnauthPeriod.daily => l.t('Diario', 'Daily'),
        UnauthPeriod.weekly => l.t('Semanal', 'Weekly'),
        UnauthPeriod.monthly => l.t('Mensual', 'Monthly'),
        UnauthPeriod.yearly => l.t('Anual', 'Yearly'),
      };

  /// Rango [start, end) en hora LOCAL (cortes de dia del auditor), en UTC para
  /// la API. `start == null` ("Todos") = sin recorte hacia atras.
  ({DateTime? start, DateTime end}) range(DateTime nowLocal) {
    final today = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final start = switch (this) {
      UnauthPeriod.all => null,
      UnauthPeriod.daily => today,
      UnauthPeriod.weekly => today.subtract(const Duration(days: 6)),
      UnauthPeriod.monthly => DateTime(nowLocal.year, nowLocal.month, 1),
      UnauthPeriod.yearly => DateTime(nowLocal.year, 1, 1),
    };
    return (start: start?.toUtc(), end: nowLocal.toUtc());
  }
}

/// Filtra el conjunto de ABIERTOS (todos ya sin-ID en lanes vigilados, tal
/// como los mantiene el poller incremental) a la ventana [start, end) por
/// `collectedAt`. Es lo que usa el selector de periodo de la pestaña "Sin ID":
/// un filtro LOCAL sobre el set ya en memoria, sin re-descargar la ventana de
/// la API. Misma semantica de ventana que [detectUnassignedUnauthorised]
/// (start nulo = "Todos", incluye lo viejo y lo sin fecha).
List<UnauthorisedTxn> openInWindow(
  Iterable<UnauthorisedTxn> open, {
  DateTime? start,
  DateTime? end,
}) {
  final out = <UnauthorisedTxn>[];
  for (final t in open) {
    final at = t.collectedAt;
    if (start != null && (at == null || at.isBefore(start))) continue;
    if (end != null && at != null && at.isAfter(end)) continue;
    out.add(t);
  }
  return sortedOpen(out);
}

/// Filtra una tanda de despachos a los no-autorizados SIN ID en los lanes
/// vigilados y dentro de la ventana [start, end] (por `recordCollectedAt`).
/// Alimenta el BACKFILL puntual (siembra el set de abiertos la primera vez); el
/// poller incremental lo mantiene despues. Ve TODO lo que sigue sin asignar en
/// la ventana, sin depender del watermark del poller.
List<UnauthorisedTxn> detectUnassignedUnauthorised({
  required List<Dispense> dispenses,
  required Set<String> normalizedLanes,
  DateTime? start,
  DateTime? end,
}) {
  final out = <UnauthorisedTxn>[];
  for (final d in dispenses) {
    if (!isUnassignedUnauthorised(d, normalizedLanes)) continue;
    final at = d.collectedAt;
    if (start != null && (at == null || at.isBefore(start))) continue;
    if (end != null && at != null && at.isAfter(end)) continue;
    out.add(UnauthorisedTxn.fromDispense(d));
  }
  return sortedOpen(out);
}
