/// Auditoria de Tag Hopping ("el tag en el bolsillo") — port de
/// `msgq/core/tag_hopping.py`.
///
/// El tag RFID identifica al equipo: cada despacho queda imputado al equipo cuyo
/// tag se leyo. Si el MISMO tag autoriza dos despachos en puntos fisicamente
/// distintos en un lapso imposible, alguien removio el tag del equipo para robar
/// combustible — o el tag esta clonado. Se detecta de dos formas
/// COMPLEMENTARIAS:
///
///   1. SOLAPAMIENTO temporal (sin coordenadas): si dos despachos consecutivos
///      del mismo equipo ocurren en puntos distintos y sus intervalos
///      [inicio, inicio+duracion] se solapan mas que la holgura de reloj, es
///      fisicamente imposible -> CRITICO. Cubre el ~99% de despachos de islas
///      fijas, que no traen GPS por transaccion: es la señal de mayor cobertura.
///   2. VELOCIDAD implicita (con coordenadas): cuando ambos despachos traen GPS
///      —o el punto figura en el mapa opcional de islas fijas— se calcula
///      distancia (haversine) sobre tiempo. Por encima de lo plausible para ese
///      equipo, se marca.
///
/// Dos decisiones que evitan falsos positivos REALES observados en Merian:
///
///   * El "lugar" es el ACTIVO SURTIDOR, no el tanque de producto: el primer
///     segmento de la etiqueta ("TFL0847 - Diesel - iTank 6" -> "TFL0847"). Un
///     service truck lleva varios tanques y sirve diesel y lubricante al mismo
///     equipo a la vez; con el tanque exacto eso se marcaba como hopping.
///   * El solapamiento solo cuenta si es el MISMO producto en ambos puntos: dos
///     productos distintos a la vez es servicio multi-producto legitimo. La
///     regla de velocidad no filtra por producto — un teletransporte es
///     imposible igual.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import 'dart:math' as math;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';

/// Un par de despachos del mismo tag en dos lugares, en un lapso imposible.
class TagHopEvent {
  const TagHopEvent({
    required this.equipmentId,
    this.equipmentDescription,
    this.tag,
    required this.category,
    required this.previousDate,
    required this.previousLocation,
    required this.date,
    required this.location,
    required this.gapMinutes,
    this.distanceKm,
    this.speedKmh,
    required this.reason,
    required this.critical,
    this.previousSourceId,
    this.sourceId,
  });

  final String equipmentId;
  final String? equipmentDescription;

  /// Tag vigente del equipo segun el maestro (`null` si no se pudo resolver).
  final String? tag;

  final String category;

  final DateTime previousDate;

  /// Etiqueta DETALLADA del punto anterior (tanque o medidor exacto).
  final String previousLocation;

  final DateTime date;
  final String location;

  /// Minutos entre el inicio de un despacho y el del otro.
  final double gapMinutes;

  /// Distancia entre puntos. `null` cuando no hay coordenadas en ambos extremos.
  final double? distanceKm;

  /// Velocidad implicita. `null` cuando no hay coordenadas, o cuando el lapso es
  /// cero — un teletransporte se reporta como tal, no como un numero infinito.
  final double? speedKmh;

  /// [tagHopReasonOverlap] o [tagHopReasonSpeed].
  final String reason;

  /// Solapamiento temporal o teletransporte. Lo demas (velocidad alta pero
  /// finita) es advertencia.
  final bool critical;

  final String? previousSourceId;
  final String? sourceId;
}

class TagHopKpis {
  const TagHopKpis({
    required this.events,
    required this.critical,
    required this.equipmentInvolved,
    required this.bySpeed,
  });

  final int events;
  final int critical;
  final int equipmentInvolved;
  final int bySpeed;
}

class TagHopAudit {
  const TagHopAudit._({required this.events, required this.kpis});

  final List<TagHopEvent> events;
  final TagHopKpis kpis;

  List<TagHopEvent> get criticalEvents =>
      events.where((e) => e.critical).toList(growable: false);

  /// Calcula la auditoria completa.
  ///
  /// [pointCoords] mapea una etiqueta de ubicacion a (lat, lon) y es OPCIONAL:
  /// extiende la regla de velocidad a las islas fijas, que no emiten GPS por
  /// transaccion.
  static TagHopAudit run({
    required List<Movement> movements,
    List<Equipment> equipment = const [],
    Map<String, Coordinates> pointCoords = const {},
  }) {
    final events = tagHops(
      movements: movements,
      equipment: equipment,
      pointCoords: pointCoords,
    );
    return TagHopAudit._(
      events: events,
      kpis: TagHopKpis(
        events: events.length,
        critical: events.where((e) => e.critical).length,
        equipmentInvolved: events.map((e) => e.equipmentId).toSet().length,
        bySpeed: events.where((e) => e.reason == tagHopReasonSpeed).length,
      ),
    );
  }
}

/// Par (lat, lon).
class Coordinates {
  const Coordinates(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  String toString() => '$latitude,$longitude';
}

/// Parsea unas coordenadas "lat,lon". `null` si no son validas.
///
/// El (0,0) se rechaza a proposito: es el "sin fix" tipico de un receptor GPS,
/// no un lugar en el golfo de Guinea. Tratarlo como posicion real produciria
/// miles de kilometros de distancia implicita contra cualquier otro punto.
Coordinates? parseCoords(String? value) {
  final text = asText(value);
  if (text == null) return null;
  final parts = text.split(',');
  if (parts.length < 2) return null;
  final lat = double.tryParse(parts[0].trim());
  final lon = double.tryParse(parts.sublist(1).join(',').trim());
  if (lat == null || lon == null) return null;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  if (lat == 0 && lon == 0) return null;
  return Coordinates(lat, lon);
}

const double _earthRadiusKm = 6371.0088;

/// Distancia en km entre dos coordenadas (formula del haversine).
double haversineKm(Coordinates a, Coordinates b) {
  double rad(double deg) => deg * math.pi / 180;
  final lat1 = rad(a.latitude);
  final lat2 = rad(b.latitude);
  final dLat = lat2 - lat1;
  final dLon = rad(b.longitude - a.longitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusKm * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Ubicacion FISICA (el activo surtidor) derivada de la etiqueta detallada.
///
/// "TFL0847 - Diesel - iTank 6" -> "TFL0847": dos tanques de producto distintos
/// sobre el MISMO camion son el mismo lugar. Una etiqueta de medidor sin " - "
/// ("MER.13.1.6") colapsa a su consola fisica ("MER.13"): dos boquillas de la
/// misma consola tampoco son dos lugares.
String dispensingSite(String location) {
  final text = location.trim();
  if (text.isEmpty) return text;
  if (text.contains(' - ')) {
    final head = text.split(' - ').first.trim();
    return head.isEmpty ? text : head;
  }
  // Etiqueta de medidor: prefijo sin puntos seguido de un segmento numerico.
  if (RegExp(r'^[^.]+\.\d').hasMatch(text)) {
    final parts = text.split('.');
    if (parts.length >= 2) return '${parts[0]}.${parts[1]}';
  }
  return text;
}

/// Pares de despachos del mismo equipo en puntos distintos con un lapso
/// fisicamente imposible.
List<TagHopEvent> tagHops({
  required List<Movement> movements,
  List<Equipment> equipment = const [],
  Map<String, Coordinates> pointCoords = const {},
}) {
  final tagById = <String, String>{};
  final categoryById = <String, String>{};
  final descriptionById = <String, String>{};
  final lightVehicles = <String>{};
  for (final e in equipment) {
    final id = realEquipmentId(e.equipmentId);
    if (id == null) continue;
    final tags = e.rfidTags;
    if (tags.isNotEmpty) tagById[id] = tags.first.toUpperCase();
    if (e.category != null) categoryById[id] = e.category!;
    if (e.description != null) descriptionById[id] = e.description!;
    if (e.isLightVehicle == true) lightVehicles.add(id);
  }

  final byEquipment = <String, List<_Stop>>{};
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    final at = m.recordCollectedAt ?? m.updatedAt;
    // El punto se identifica por el tanque; si falta, por el medidor.
    final location = asText(m.tank) ?? asText(m.meterId);
    if (id == null || at == null || location == null) continue;
    byEquipment.putIfAbsent(id, () => <_Stop>[]).add(_Stop(
          equipmentId: id,
          description: asText(m.equipmentDescription),
          at: at,
          location: location,
          site: dispensingSite(location),
          product: asText(m.product)?.toUpperCase(),
          // Una duracion ausente se trata como 0: sin ella no se puede afirmar
          // que el despacho seguia en curso, y marcar por suposicion seria peor
          // que no marcar.
          durationSeconds: (m.flowDurationS ?? 0).clamp(0, double.infinity),
          coords: parseCoords(m.gpsCoordinates) ?? pointCoords[location],
          sourceId: m.id,
        ));
  }

  final slack = tagHopClockSlackMinutes < 0 ? 0.0 : tagHopClockSlackMinutes;
  final out = <TagHopEvent>[];
  for (final stops in byEquipment.values) {
    stops.sort((a, b) => a.at.compareTo(b.at));
    for (var i = 1; i < stops.length; i++) {
      final prev = stops[i - 1];
      final curr = stops[i];
      if (prev.site == curr.site) continue; // mismo activo surtidor: no es hopping

      final gapMinutes = curr.at.difference(prev.at).inMilliseconds / 60000.0;

      // Regla 1 — solapamiento, solo si es el mismo producto en ambos puntos.
      final sameProduct = prev.product != null &&
          curr.product != null &&
          prev.product == curr.product;
      final overlapMinutes = prev.durationSeconds / 60.0 - gapMinutes;
      final isOverlap = sameProduct && overlapMinutes > slack;

      // Regla 2 — velocidad implicita, solo con coordenadas en ambos extremos.
      double? distanceKm;
      double? speedKmh;
      var isSpeed = false;
      final from = prev.coords;
      final to = curr.coords;
      if (from != null && to != null) {
        final distance = haversineKm(from, to);
        distanceKm = roundTo(distance, 2);
        if (distance >= tagHopMinDistanceKm) {
          final hours = gapMinutes / 60.0;
          final limit = lightVehicles.contains(curr.equipmentId)
              ? tagHopLightMaxSpeedKmh
              : tagHopMaxSpeedKmh;
          if (hours <= 0) {
            isSpeed = true; // teletransporte: distancia sin tiempo
          } else {
            final speed = distance / hours;
            speedKmh = roundTo(speed, 1);
            isSpeed = speed > limit;
          }
        }
      }

      if (!isOverlap && !isSpeed) continue;
      final teleport = gapMinutes <= slack;
      out.add(TagHopEvent(
        equipmentId: curr.equipmentId,
        equipmentDescription:
            curr.description ?? descriptionById[curr.equipmentId],
        tag: tagById[curr.equipmentId],
        category: categoryById[curr.equipmentId] ?? noDataLabel,
        previousDate: prev.at,
        previousLocation: prev.location,
        date: curr.at,
        location: curr.location,
        gapMinutes: roundTo(gapMinutes),
        distanceKm: distanceKm,
        speedKmh: speedKmh,
        reason: isOverlap ? tagHopReasonOverlap : tagHopReasonSpeed,
        critical: isOverlap || teleport,
        previousSourceId: prev.sourceId,
        sourceId: curr.sourceId,
      ));
    }
  }
  // Criticos primero, luego los mas recientes.
  out.sort((a, b) {
    if (a.critical != b.critical) return a.critical ? -1 : 1;
    return b.date.compareTo(a.date);
  });
  return List.unmodifiable(out);
}

class _Stop {
  const _Stop({
    required this.equipmentId,
    this.description,
    required this.at,
    required this.location,
    required this.site,
    this.product,
    required this.durationSeconds,
    this.coords,
    this.sourceId,
  });

  final String equipmentId;
  final String? description;
  final DateTime at;

  /// Etiqueta detallada (para mostrar).
  final String location;

  /// Activo surtidor (para decidir si hubo cambio de lugar).
  final String site;

  final String? product;
  final double durationSeconds;
  final Coordinates? coords;
  final String? sourceId;
}
