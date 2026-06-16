import 'package:flutter_test/flutter_test.dart';

import 'package:adapt_mac_notifier/src/config/app_settings.dart';
import 'package:adapt_mac_notifier/src/core/unauthorised_check.dart';
import 'package:adapt_mac_notifier/src/models/dispense.dart';

void main() {
  final now = DateTime.utc(2026, 6, 15, 12, 0, 0);
  final lanes = const AppSettings().normalizedUnauthorisedLanes;

  // Modela el dato real de Merian: el lane es la CONSOLA AdaptMAC (su
  // descripcion), NO el tanque origen — que es el virtual, comun a los 3 lanes.
  Dispense disp(
    String id, {
    String? type = 'Unauthorised',
    String? equipmentId,
    String? lane = 'LFO Dispense Lane 3',
    String? adaptMacCode = 'MER.3',
    String tank = 'LFO - Virtual Tank',
    double? volume = 50,
    DateTime? collectedAt,
    DateTime? updatedAt,
  }) =>
      Dispense(
        id: id,
        type: type,
        equipmentId: equipmentId,
        tank: tank,
        adaptMac: adaptMacCode,
        adaptMacDescription: lane,
        volume: volume,
        collectedAt: collectedAt ?? now,
        updatedAt: updatedAt ?? now,
      );

  group('isBlankEquipmentId (= _BLANK de MSGQ)', () {
    test('vacio / null / UNAUTHORISED cuentan como sin ID', () {
      expect(isBlankEquipmentId(null), isTrue);
      expect(isBlankEquipmentId(''), isTrue);
      expect(isBlankEquipmentId('  '), isTrue);
      expect(isBlankEquipmentId('UNAUTHORISED'), isTrue);
      expect(isBlankEquipmentId('unauthorised'), isTrue);
      expect(isBlankEquipmentId('<NA>'), isTrue);
    });

    test('un equipo real NO esta en blanco', () {
      expect(isBlankEquipmentId('HTK0826'), isFalse);
    });
  });

  group('isUnassignedUnauthorised', () {
    test('Unauthorised + sin ID + lane vigilado => true', () {
      expect(isUnassignedUnauthorised(disp('1'), lanes), isTrue);
    });

    test('con ID asignado => false (ya salio de la lista)', () {
      expect(
          isUnassignedUnauthorised(disp('1', equipmentId: 'HTK0826'), lanes),
          isFalse);
    });

    test('tipo distinto de Unauthorised => false', () {
      expect(
          isUnassignedUnauthorised(disp('1', type: 'Authorised'), lanes),
          isFalse);
    });

    test('lane fuera del conjunto vigilado => false', () {
      expect(
          isUnassignedUnauthorised(disp('1', lane: 'Workshop Bay'), lanes),
          isFalse);
    });

    test('el equipmentId literal UNAUTHORISED tambien cuenta como sin ID', () {
      expect(
          isUnassignedUnauthorised(disp('1', equipmentId: 'UNAUTHORISED'), lanes),
          isTrue);
    });

    test('id == UNAUTHORISED basta aunque el type no diga unauth', () {
      // Segunda via de marcado de AdaptIQ: el equipo, no el type.
      expect(
          isUnassignedUnauthorised(
              disp('1', type: 'Dispense', equipmentId: 'UNAUTHORISED'), lanes),
          isTrue);
    });

    test('el lane se identifica por la CONSOLA, no por el tanque virtual', () {
      // Caso real Merian (txn 254427): source = "LFO - Virtual Tank" (no es un
      // lane), pero adaptMac.description = "LFO Dispense Lane 3" SI lo es.
      final real = Dispense(
        id: '254427',
        type: 'Unauthorised',
        equipmentId: '', // sin equipo (status No Equip)
        tank: 'LFO - Virtual Tank',
        adaptMac: 'MER.3',
        adaptMacDescription: 'LFO Dispense Lane 3',
        volume: 2486,
        collectedAt: now,
      );
      expect(isUnassignedUnauthorised(real, lanes), isTrue);
      expect(dispensingPoint(real), 'LFO Dispense Lane 3');
      // Si SOLO tuvieramos el tanque virtual, NO deberia matchear.
      final onlyTank = Dispense(
          id: 'x',
          type: 'Unauthorised',
          equipmentId: '',
          tank: 'LFO - Virtual Tank');
      expect(isUnassignedUnauthorised(onlyTank, lanes), isFalse);
    });

    test('tambien se puede vigilar un lane por el CODIGO de consola', () {
      final byCode = {'MER.3'}; // normProduct('MER.3') = 'MER.3'
      final d = Dispense(
        id: '1',
        type: 'Unauthorised',
        equipmentId: '',
        adaptMac: 'MER.3',
        adaptMacDescription: 'LFO Dispense Lane 3',
      );
      expect(isUnassignedUnauthorised(d, byCode), isTrue);
    });
  });

  group('diffUnauthorised (transiciones incrementales)', () {
    test('primer chequeo: un sin-ID nuevo emite apertura y queda abierto', () {
      final diff = diffUnauthorised(
        previousOpen: const {},
        fetched: [disp('1')],
        normalizedLanes: lanes,
        now: now,
      );
      expect(diff.events, hasLength(1));
      expect(diff.events.single.active, isTrue);
      expect(diff.updatedOpen.keys, ['1']);
      expect(diff.updatedOpen['1']!.firstSeen, now);
    });

    test('reaparece con ID asignado => cierre y sale de abiertos', () {
      final previous = {
        '1': UnauthorisedTxn.fromDispense(disp('1'), firstSeen: now),
      };
      final later = now.add(const Duration(minutes: 10));
      final diff = diffUnauthorised(
        previousOpen: previous,
        fetched: [disp('1', equipmentId: 'HTK0826', updatedAt: later)],
        normalizedLanes: lanes,
        now: later,
      );
      expect(diff.events, hasLength(1));
      expect(diff.events.single.active, isFalse);
      expect(diff.updatedOpen, isEmpty);
    });

    test('re-traer un sin-ID sin cambios no emite nada y conserva firstSeen', () {
      final previous = {
        '1': UnauthorisedTxn.fromDispense(disp('1'), firstSeen: now),
      };
      final later = now.add(const Duration(minutes: 5));
      final diff = diffUnauthorised(
        previousOpen: previous,
        fetched: [disp('1', updatedAt: later)],
        normalizedLanes: lanes,
        now: later,
      );
      expect(diff.events, isEmpty);
      expect(diff.updatedOpen['1']!.firstSeen, now); // preservado
    });

    test('un despacho fuera de los lanes nunca abre', () {
      final diff = diffUnauthorised(
        previousOpen: const {},
        fetched: [disp('1', lane: 'Otra isla')],
        normalizedLanes: lanes,
        now: now,
      );
      expect(diff.events, isEmpty);
      expect(diff.updatedOpen, isEmpty);
    });
  });

  group('detectUnassignedUnauthorised (vista live por ventana)', () {
    test('filtra por sin-ID + lane + ventana de recordCollectedAt', () {
      final dispenses = [
        disp('hoy', collectedAt: now), // dentro de la ventana
        disp('viejo', collectedAt: now.subtract(const Duration(days: 10))),
        disp('conId', equipmentId: 'HTK0826', collectedAt: now), // asignado
        disp('otroLane', lane: 'Workshop', collectedAt: now), // fuera de lane
      ];
      final out = detectUnassignedUnauthorised(
        dispenses: dispenses,
        normalizedLanes: lanes,
        start: now.subtract(const Duration(days: 6)),
        end: now,
      );
      expect(out.map((t) => t.id), ['hoy']); // solo el de hoy, sin id, en lane
    });

    test('"Todos" (start null) incluye lo viejo y lo sin fecha', () {
      final dispenses = [
        disp('a', collectedAt: now.subtract(const Duration(days: 400))),
        disp('b', collectedAt: null),
      ];
      final out = detectUnassignedUnauthorised(
        dispenses: dispenses,
        normalizedLanes: lanes,
        start: null,
        end: now,
      );
      expect(out.map((t) => t.id).toSet(), {'a', 'b'});
    });

    test('los tres lanes por defecto se reconocen (no solo Lane 3)', () {
      final dispenses = [
        disp('l1', lane: 'LFO Delivery and LV Bay (Lane 1)'),
        disp('l2', lane: 'LFO Dispense Lane 2'),
        disp('l3', lane: 'LFO Dispense Lane 3'),
      ];
      final out = detectUnassignedUnauthorised(
        dispenses: dispenses,
        normalizedLanes: lanes,
        start: now.subtract(const Duration(days: 1)),
        end: now,
      );
      expect(out.map((t) => t.id).toSet(), {'l1', 'l2', 'l3'});
    });
  });

  group('openInWindow (periodo = filtro local sobre el set de abiertos)', () {
    UnauthorisedTxn txn(String id, {DateTime? collectedAt}) =>
        UnauthorisedTxn(id: id, collectedAt: collectedAt);

    test('recorta por collectedAt a la ventana [start, end)', () {
      final open = [
        txn('hoy', collectedAt: now),
        txn('viejo', collectedAt: now.subtract(const Duration(days: 10))),
      ];
      final out = openInWindow(open,
          start: now.subtract(const Duration(days: 6)), end: now);
      expect(out.map((t) => t.id), ['hoy']);
    });

    test('"Todos" (start null) incluye lo viejo y lo sin fecha', () {
      final open = [
        txn('a', collectedAt: now.subtract(const Duration(days: 400))),
        txn('b', collectedAt: null),
      ];
      final out = openInWindow(open, start: null, end: now);
      expect(out.map((t) => t.id).toSet(), {'a', 'b'});
    });

    test('un periodo acotado excluye lo sin fecha (no se puede ubicar)', () {
      final out = openInWindow([txn('b', collectedAt: null)],
          start: now.subtract(const Duration(days: 1)), end: now);
      expect(out, isEmpty);
    });

    test('ordena los mas recientes primero (igual que sortedOpen)', () {
      final open = [
        txn('viejo', collectedAt: now.subtract(const Duration(hours: 2))),
        txn('nuevo', collectedAt: now),
      ];
      final out = openInWindow(open, start: null, end: now);
      expect(out.map((t) => t.id), ['nuevo', 'viejo']);
    });
  });

  group('Dispense.fromNode (lane via adaptMac.description)', () {
    test('parsea adaptMac { code description } y el tanque virtual', () {
      final d = Dispense.fromNode({
        'id': '254427',
        'type': 'Unauthorised',
        'status': 'No Equip',
        'volume': 2486.0,
        'source': {'code': 'LFO', 'name': 'LFO - Virtual Tank'},
        'target': {'equipmentId': null},
        'adaptMac': {'code': 'MER.3', 'description': 'LFO Dispense Lane 3'},
        'recordCollectedAt': '2026-06-15T09:38:00Z',
      });
      expect(d.adaptMac, 'MER.3');
      expect(d.adaptMacDescription, 'LFO Dispense Lane 3');
      expect(d.tank, 'LFO - Virtual Tank');
      expect(dispensingPoint(d), 'LFO Dispense Lane 3');
      expect(isUnassignedUnauthorised(d, lanes), isTrue);
    });
  });

  group('UnauthPeriod.range', () {
    final nowLocal = DateTime(2026, 6, 15, 11, 30);
    test('all => start null', () {
      expect(UnauthPeriod.all.range(nowLocal).start, isNull);
    });
    test('daily => inicio de hoy', () {
      expect(UnauthPeriod.daily.range(nowLocal).start,
          DateTime(2026, 6, 15).toUtc());
    });
    test('weekly => hace 6 dias', () {
      expect(UnauthPeriod.weekly.range(nowLocal).start,
          DateTime(2026, 6, 9).toUtc());
    });
    test('monthly => primero del mes; yearly => primero del año', () {
      expect(UnauthPeriod.monthly.range(nowLocal).start,
          DateTime(2026, 6, 1).toUtc());
      expect(UnauthPeriod.yearly.range(nowLocal).start,
          DateTime(2026, 1, 1).toUtc());
    });
  });
}
