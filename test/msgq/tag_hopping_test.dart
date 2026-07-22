import 'package:adapt_mac_notifier/src/msgq/analytics/tag_hopping.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';

Movement disp(
  String id, {
  required String equipmentId,
  required String tank,
  required DateTime at,
  String product = 'Diesel',
  double durationSeconds = 0,
  String? gps,
}) =>
    Movement(
      id: id,
      kind: MovementKind.dispense,
      equipmentId: equipmentId,
      tank: tank,
      product: product,
      flowDurationS: durationSeconds,
      gpsCoordinates: gps,
      recordCollectedAt: at,
    );

void main() {
  group('coordenadas', () {
    test('parsea "lat,lon" y rechaza lo invalido', () {
      final c = parseCoords('5.1234, -55.4321')!;
      expect(c.latitude, 5.1234);
      expect(c.longitude, -55.4321);
      expect(parseCoords('no soy coordenadas'), isNull);
      expect(parseCoords('91,0'), isNull); // fuera de rango
      expect(parseCoords(null), isNull);
    });

    test('(0,0) se rechaza: es el "sin fix" del receptor, no un lugar', () {
      expect(parseCoords('0,0'), isNull);
      expect(parseCoords('0.0, 0.0'), isNull);
    });

    test('la distancia haversine es coherente', () {
      // Un grado de latitud son ~111 km.
      final d = haversineKm(const Coordinates(5, -55), const Coordinates(6, -55));
      expect(d, closeTo(111.2, 1.0));
      expect(haversineKm(const Coordinates(5, -55), const Coordinates(5, -55)),
          0);
    });
  });

  group('ubicacion fisica', () {
    test('el activo surtidor es el primer segmento del tanque', () {
      expect(dispensingSite('TFL0847 - Diesel - iTank 6'), 'TFL0847');
      expect(dispensingSite('TFL0847 - Hydraulic Oil'), 'TFL0847');
    });

    test('una etiqueta de medidor colapsa a su consola fisica', () {
      expect(dispensingSite('MER.13.1.6'), 'MER.13');
      expect(dispensingSite('MER.13.2.1'), 'MER.13');
    });

    test('una etiqueta simple se conserva', () {
      expect(dispensingSite('Taller'), 'Taller');
    });
  });

  group('solapamiento temporal', () {
    test('marca dos despachos solapados del mismo producto en sitios distintos',
        () {
      final events = tagHops(movements: [
        // Empieza a las 10:00 y dura 30 min.
        disp('a', equipmentId: 'EX01', tank: 'TFL0847 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 1800),
        // Otro despacho a los 10 min, en otro camion: imposible.
        disp('b', equipmentId: 'EX01', tank: 'TFL0999 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10, 10)),
      ]);
      final e = events.single;
      expect(e.reason, tagHopReasonOverlap);
      expect(e.critical, isTrue);
      expect(e.gapMinutes, 10);
      expect(e.previousLocation, 'TFL0847 - Diesel');
      expect(e.location, 'TFL0999 - Diesel');
    });

    test('dos tanques del MISMO camion no son dos lugares', () {
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'TFL0847 - Diesel - iTank 6',
            at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 1800),
        disp('b', equipmentId: 'EX01', tank: 'TFL0847 - Hydraulic Oil',
            at: DateTime.utc(2026, 6, 1, 10, 10)),
      ]);
      expect(events, isEmpty);
    });

    test('productos distintos solapados son servicio multi-producto legitimo',
        () {
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'TFL0847 - Diesel',
            product: 'Diesel', at: DateTime.utc(2026, 6, 1, 10),
            durationSeconds: 1800),
        disp('b', equipmentId: 'EX01', tank: 'Taller - Coolant',
            product: 'Coolant', at: DateTime.utc(2026, 6, 1, 10, 10)),
      ]);
      expect(events, isEmpty);
    });

    test('sin solapamiento real no se marca', () {
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'TFL0847 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 300),
        // El primero termino a las 10:05; el segundo empieza a las 11:00.
        disp('b', equipmentId: 'EX01', tank: 'TFL0999 - Diesel',
            at: DateTime.utc(2026, 6, 1, 11)),
      ]);
      expect(events, isEmpty);
    });

    test('la holgura de reloj absorbe un solapamiento marginal', () {
      final events = tagHops(movements: [
        // Dura 10 min; el siguiente empieza a los 9,5: solapa 0,5 min.
        disp('a', equipmentId: 'EX01', tank: 'A - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 600),
        disp('b', equipmentId: 'EX01', tank: 'B - Diesel',
            at: DateTime.utc(2026, 6, 1, 10, 9, 30)),
      ]);
      expect(events, isEmpty);
    });

    test('sin duracion registrada no se afirma solapamiento', () {
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'A - Diesel',
            at: DateTime.utc(2026, 6, 1, 10)),
        disp('b', equipmentId: 'EX01', tank: 'B - Diesel',
            at: DateTime.utc(2026, 6, 1, 10, 1)),
      ]);
      expect(events, isEmpty);
    });
  });

  group('velocidad implicita', () {
    test('marca la velocidad implausible para un equipo pesado', () {
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'A - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), gps: '5.0,-55.0'),
        // ~111 km en 1 hora: imposible para maquinaria pesada.
        disp('b', equipmentId: 'EX01', tank: 'B - Diesel',
            at: DateTime.utc(2026, 6, 1, 11), gps: '6.0,-55.0'),
      ]);
      final e = events.single;
      expect(e.reason, tagHopReasonSpeed);
      expect(e.distanceKm, closeTo(111.2, 1));
      expect(e.speedKmh, closeTo(111.2, 1));
      expect(e.critical, isFalse); // velocidad alta pero finita = advertencia
    });

    test('un vehiculo ligero tiene un umbral mas alto', () {
      final movements = [
        disp('a', equipmentId: 'LV02', tank: 'A - Gasolina',
            at: DateTime.utc(2026, 6, 1, 10), gps: '5.0,-55.0'),
        disp('b', equipmentId: 'LV02', tank: 'B - Gasolina',
            at: DateTime.utc(2026, 6, 1, 11, 30), gps: '5.5,-55.0'),
      ];
      // ~55,6 km en 1,5 h = ~37 km/h: bajo ambos umbrales (40 y 100).
      expect(tagHops(movements: movements), isEmpty);

      // El mismo recorrido en 1 h (~55,6 km/h) queda ENTRE ambos umbrales:
      // implausible para maquinaria pesada, normal para una camioneta.
      final fast = [
        movements.first,
        disp('b', equipmentId: 'LV02', tank: 'B - Gasolina',
            at: DateTime.utc(2026, 6, 1, 11), gps: '5.5,-55.0'),
      ];
      expect(
        tagHops(
          movements: fast,
          equipment: const [Equipment(equipmentId: 'LV02', isLightVehicle: true)],
        ),
        isEmpty,
      );
      expect(
        tagHops(
          movements: fast,
          equipment: const [Equipment(equipmentId: 'LV02', isLightVehicle: false)],
        ),
        hasLength(1),
      );
    });

    test('el jitter del GPS por debajo del minimo se ignora', () {
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'A - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), gps: '5.00000,-55.00000'),
        disp('b', equipmentId: 'EX01', tank: 'B - Diesel',
            at: DateTime.utc(2026, 6, 1, 10, 0, 1), gps: '5.00100,-55.00000'),
      ]);
      expect(events, isEmpty); // ~110 m: dentro del jitter del receptor
    });

    test('el teletransporte es critico y no reporta velocidad infinita', () {
      final at = DateTime.utc(2026, 6, 1, 10);
      final events = tagHops(movements: [
        disp('a', equipmentId: 'EX01', tank: 'A - Diesel', at: at,
            gps: '5.0,-55.0'),
        disp('b', equipmentId: 'EX01', tank: 'B - Diesel', at: at,
            gps: '6.0,-55.0'),
      ]);
      final e = events.single;
      expect(e.critical, isTrue);
      expect(e.gapMinutes, 0);
      expect(e.speedKmh, isNull);
      expect(e.distanceKm, isNotNull);
    });

    test('el mapa opcional de puntos extiende la regla a islas sin GPS', () {
      final events = tagHops(
        movements: [
          disp('a', equipmentId: 'EX01', tank: 'Isla Norte',
              at: DateTime.utc(2026, 6, 1, 10)),
          disp('b', equipmentId: 'EX01', tank: 'Isla Sur',
              at: DateTime.utc(2026, 6, 1, 10, 30)),
        ],
        pointCoords: const {
          'Isla Norte': Coordinates(5.0, -55.0),
          'Isla Sur': Coordinates(6.0, -55.0),
        },
      );
      expect(events, hasLength(1));
      expect(events.single.reason, tagHopReasonSpeed);
    });
  });

  group('auditoria completa', () {
    test('los criticos van primero y los KPIs los separan', () {
      final audit = TagHopAudit.run(movements: [
        // Advertencia por velocidad (equipo A).
        disp('a1', equipmentId: 'A', tank: 'P1 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), gps: '5.0,-55.0'),
        disp('a2', equipmentId: 'A', tank: 'P2 - Diesel',
            at: DateTime.utc(2026, 6, 1, 11), gps: '6.0,-55.0'),
        // Critico por solapamiento (equipo B).
        disp('b1', equipmentId: 'B', tank: 'P3 - Diesel',
            at: DateTime.utc(2026, 6, 2, 10), durationSeconds: 1800),
        disp('b2', equipmentId: 'B', tank: 'P4 - Diesel',
            at: DateTime.utc(2026, 6, 2, 10, 5)),
      ]);
      expect(audit.kpis.events, 2);
      expect(audit.kpis.critical, 1);
      expect(audit.kpis.bySpeed, 1);
      expect(audit.kpis.equipmentInvolved, 2);
      expect(audit.events.first.critical, isTrue);
      expect(audit.criticalEvents.single.equipmentId, 'B');
    });

    test('resuelve el tag vigente y la categoria desde el maestro', () {
      final audit = TagHopAudit.run(
        movements: [
          disp('a', equipmentId: 'EX01', tank: 'P1 - Diesel',
              at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 1800),
          disp('b', equipmentId: 'EX01', tank: 'P2 - Diesel',
              at: DateTime.utc(2026, 6, 1, 10, 5)),
        ],
        equipment: const [
          Equipment(equipmentId: 'EX01', rfid: 'aaa, bbb',
              category: 'Excavadoras', description: 'Excavadora 01'),
        ],
      );
      final e = audit.events.single;
      expect(e.tag, 'AAA'); // el primero, normalizado a mayusculas
      expect(e.category, 'Excavadoras');
      expect(e.equipmentDescription, 'Excavadora 01');
    });

    test('un despacho sin equipo real no genera eventos', () {
      final audit = TagHopAudit.run(movements: [
        disp('a', equipmentId: 'Unauthorised', tank: 'P1 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 1800),
        disp('b', equipmentId: 'Unauthorised', tank: 'P2 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10, 5)),
      ]);
      expect(audit.events, isEmpty);
    });

    test('sin categoria en el maestro cae en (sin dato)', () {
      final audit = TagHopAudit.run(movements: [
        disp('a', equipmentId: 'EX01', tank: 'P1 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10), durationSeconds: 1800),
        disp('b', equipmentId: 'EX01', tank: 'P2 - Diesel',
            at: DateTime.utc(2026, 6, 1, 10, 5)),
      ]);
      expect(audit.events.single.category, noDataLabel);
    });
  });
}
