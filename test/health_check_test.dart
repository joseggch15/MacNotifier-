import 'package:flutter_test/flutter_test.dart';

import 'package:adapt_mac_notifier/src/api/queries.dart';
import 'package:adapt_mac_notifier/src/core/health_check.dart';
import 'package:adapt_mac_notifier/src/core/util.dart';
import 'package:adapt_mac_notifier/src/models/adapt_mac.dart';

void main() {
  final now = DateTime.utc(2026, 6, 11, 12, 0, 0);
  const stale = Duration(minutes: 30);

  AdaptMac mac(
    String code, {
    bool? online,
    bool? keyBypass,
    DateTime? lastOk,
  }) =>
      AdaptMac(code: code, online: online, keyBypass: keyBypass, lastSuccessfulComms: lastOk);

  group('conditionsFor (port de detect_adaptmac_alerts)', () {
    test('consola sana no tiene condiciones', () {
      expect(
        conditionsFor(mac('MER.1', online: true), staleAfter: stale, now: now),
        isEmpty,
      );
    });

    test('offline marca aunque keyBypass sea falso', () {
      expect(
        conditionsFor(mac('MER.9', online: false), staleAfter: stale, now: now),
        {ConsoleCondition.offline},
      );
    });

    test('keyBypass y offline pueden coexistir', () {
      expect(
        conditionsFor(mac('MER.3', online: false, keyBypass: true),
            staleAfter: stale, now: now),
        {ConsoleCondition.keyBypass, ConsoleCondition.offline},
      );
    });

    test('stale: online pero sin comunicacion exitosa hace > umbral', () {
      final c = mac('MER.5',
          online: true, lastOk: now.subtract(const Duration(minutes: 45)));
      expect(conditionsFor(c, staleAfter: stale, now: now),
          {ConsoleCondition.stale});
    });

    test('comunicacion reciente NO es stale', () {
      final c = mac('MER.5',
          online: true, lastOk: now.subtract(const Duration(minutes: 5)));
      expect(conditionsFor(c, staleAfter: stale, now: now), isEmpty);
    });

    test('sin lastSuccessfulComms no se puede evaluar stale (tenant Merian)', () {
      expect(
        conditionsFor(mac('MER.7', online: true), staleAfter: stale, now: now),
        isEmpty,
      );
    });

    test('offline manda sobre stale (no se reportan ambas)', () {
      final c = mac('MER.2',
          online: false, lastOk: now.subtract(const Duration(hours: 2)));
      expect(conditionsFor(c, staleAfter: stale, now: now),
          {ConsoleCondition.offline});
    });
  });

  group('diffEvents (dedup por transiciones)', () {
    test('primer chequeo: las condiciones activas SI se reportan', () {
      final consoles = [mac('MER.9', online: false), mac('MER.8', online: true)];
      final current = evaluateAll(consoles, staleAfter: stale, now: now);
      final events = diffEvents(
          previous: null, consoles: consoles, current: current, now: now);
      expect(events, hasLength(1));
      expect(events.single.console.code, 'MER.9');
      expect(events.single.active, isTrue);
    });

    test('sin cambios entre ciclos -> sin eventos (sin duplicados)', () {
      final consoles = [mac('MER.9', online: false)];
      final current = evaluateAll(consoles, staleAfter: stale, now: now);
      final events = diffEvents(
          previous: current, consoles: consoles, current: current, now: now);
      expect(events, isEmpty);
    });

    test('recuperacion: offline -> online emite evento cleared', () {
      final consoles = [mac('MER.9', online: true)];
      final current = evaluateAll(consoles, staleAfter: stale, now: now);
      final events = diffEvents(
        previous: {
          'MER.9': {ConsoleCondition.offline},
        },
        consoles: consoles,
        current: current,
        now: now,
      );
      expect(events, hasLength(1));
      expect(events.single.active, isFalse);
      expect(events.single.condition, ConsoleCondition.offline);
    });

    test('consola retirada del maestro se descarta en silencio', () {
      final consoles = [mac('MER.1', online: true)];
      final current = evaluateAll(consoles, staleAfter: stale, now: now);
      final events = diffEvents(
        previous: {
          'MER.99': {ConsoleCondition.offline},
        },
        consoles: consoles,
        current: current,
        now: now,
      );
      expect(events, isEmpty);
    });

    test('alzas se ordenan antes que las recuperaciones', () {
      final consoles = [mac('MER.1', online: true), mac('MER.2', online: false)];
      final current = evaluateAll(consoles, staleAfter: stale, now: now);
      final events = diffEvents(
        previous: {
          'MER.1': {ConsoleCondition.offline},
          'MER.2': const <ConsoleCondition>{},
        },
        consoles: consoles,
        current: current,
        now: now,
      );
      expect(events, hasLength(2));
      expect(events.first.active, isTrue); // MER.2 cae
      expect(events.last.active, isFalse); // MER.1 se recupera
    });
  });

  group('AdaptMac', () {
    test('fromNode aplana el site y parsea fechas ISO (como MSGQ)', () {
      final c = AdaptMac.fromNode({
        'code': 'MER.4',
        'description': 'Fleet Workshop',
        'erpReference': 'X1',
        'keyBypass': false,
        'online': true,
        'site': {'code': 'MER', 'description': 'Newmont Merian'},
        'lastSuccessfulComms': '2026-06-11T11:55:00Z',
      });
      expect(c.site, 'Newmont Merian');
      expect(c.lastSuccessfulComms, DateTime.utc(2026, 6, 11, 11, 55));
    });

    test('roundtrip toJson/fromJson conserva el estado', () {
      final original = AdaptMac.fromNode({
        'code': 'MER.4',
        'online': false,
        'keyBypass': true,
        'lastSuccessfulComms': '2026-06-11T11:55:00Z',
      });
      final copy = AdaptMac.fromJson(original.toJson());
      expect(copy.code, original.code);
      expect(copy.online, original.online);
      expect(copy.keyBypass, original.keyBypass);
      expect(copy.lastSuccessfulComms, original.lastSuccessfulComms);
    });
  });

  group('buildAdaptMacsQuery', () {
    test('sin opcionales queda la query base probada en produccion', () {
      final q = buildAdaptMacsQuery(const {});
      expect(q, contains('adaptMacs(first:'));
      expect(q, contains('keyBypass'));
      expect(q, isNot(contains('lastSuccessfulComms')));
      expect(q, isNot(contains('site {')));
    });

    test('solo incluye los campos descubiertos', () {
      final q = buildAdaptMacsQuery({'lastSuccessfulComms', 'updatedAt'});
      expect(q, contains('lastSuccessfulComms'));
      expect(q, contains('updatedAt'));
      expect(q, isNot(contains('lastFailedComms')));
    });
  });

  group('util', () {
    test('naturalCompare ordena MER.2 < MER.10 < MER.16', () {
      final codes = ['MER.16', 'MER.2', 'MER.10']..sort(naturalCompare);
      expect(codes, ['MER.2', 'MER.10', 'MER.16']);
    });

    test('stableId es deterministico y positivo', () {
      expect(stableId('MER.9/offline'), stableId('MER.9/offline'));
      expect(stableId('MER.9/offline'), isNot(stableId('MER.9/stale')));
      expect(stableId('MER.9/offline'), greaterThan(0));
    });

    test('relativeEs', () {
      expect(relativeEs(now.subtract(const Duration(minutes: 5)), now: now),
          'hace 5 min');
      expect(relativeEs(now.subtract(const Duration(hours: 3)), now: now),
          'hace 3 h');
    });
  });
}
