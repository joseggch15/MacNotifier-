import 'package:adapt_mac_notifier/src/models/adapt_mac.dart';
import 'package:adapt_mac_notifier/src/msgq/analytics/mac_health.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/mac_event.dart';
import 'package:flutter_test/flutter_test.dart';

AdaptMac mac(
  String code, {
  bool? online,
  bool? bypass,
  DateTime? lastOk,
  DateTime? lastFailed,
  String? description,
}) =>
    AdaptMac(
      code: code,
      description: description,
      online: online,
      keyBypass: bypass,
      lastSuccessfulComms: lastOk,
      lastFailedComms: lastFailed,
    );

MacEvent event(
  String code,
  MacEventKind kind,
  DateTime ts, {
  String? description,
}) =>
    MacEvent(
      eventKey: '$code|${kind.wire}|$ts',
      code: code,
      description: description,
      kind: kind,
      ts: ts,
    );

void main() {
  group('diff de snapshots', () {
    final t0 = DateTime.utc(2026, 7, 1, 8);
    final t1 = DateTime.utc(2026, 7, 1, 9);

    test('una caida usa lastSuccessfulComms, no la hora de observacion', () {
      // El dispositivo congela lastSuccessfulComms al caer: ese es el momento
      // real del corte, no el momento en que la app se entero.
      final events = diffMacSnapshots(
        previous: [mac('MER.13', online: true)],
        current: [mac('MER.13', online: false, lastOk: t0)],
        observedAt: t1,
      );
      final drop = events.singleWhere((e) => e.kind == MacEventKind.offline);
      expect(drop.ts, t0);
      expect(drop.code, 'MER.13');
    });

    test('sin lastSuccessfulComms cae a la hora de observacion', () {
      final events = diffMacSnapshots(
        previous: [mac('MER.13', online: true)],
        current: [mac('MER.13', online: false)],
        observedAt: t1,
      );
      expect(events.single.ts, t1);
    });

    test('una recuperacion emite ONLINE', () {
      final events = diffMacSnapshots(
        previous: [mac('MER.13', online: false)],
        current: [mac('MER.13', online: true, lastOk: t1)],
        observedAt: t1,
      );
      expect(events.single.kind, MacEventKind.online);
      expect(events.single.ts, t1);
    });

    test('sin cambios no se emite nada', () {
      final events = diffMacSnapshots(
        previous: [mac('MER.13', online: true, bypass: false)],
        current: [mac('MER.13', online: true, bypass: false)],
        observedAt: t1,
      );
      expect(events, isEmpty);
    });

    test('lastFailedComms que avanza emite un fallo con SU timestamp', () {
      final events = diffMacSnapshots(
        previous: [mac('MER.13', online: true, lastFailed: t0)],
        current: [mac('MER.13', online: true, lastFailed: t1)],
        observedAt: DateTime.utc(2026, 7, 1, 10),
      );
      final fail = events.singleWhere((e) => e.kind == MacEventKind.failedComms);
      expect(fail.ts, t1);
    });

    test('el bypass usa la hora de observacion (no hay marca del equipo)', () {
      final events = diffMacSnapshots(
        previous: [mac('MER.13', online: true, bypass: false)],
        current: [mac('MER.13', online: true, bypass: true)],
        observedAt: t1,
      );
      expect(events.single.kind, MacEventKind.bypassOn);
      expect(events.single.ts, t1);
    });

    test('una consola NUEVA no emite transiciones falsas', () {
      final events = diffMacSnapshots(
        previous: const [],
        current: [mac('MER.99', online: true, bypass: false)],
        observedAt: t1,
      );
      expect(events, isEmpty);
    });

    test('pero una consola nueva YA CAIDA siembra su corte', () {
      // Sin esta siembra, la consola mas problematica del sitio no tendria
      // episodio nunca: estaba caida desde antes de empezar a observar.
      final events = diffMacSnapshots(
        previous: const [],
        current: [mac('MER.99', online: false, lastOk: t0, lastFailed: t0)],
        observedAt: t1,
      );
      expect(events.map((e) => e.kind),
          containsAll([MacEventKind.offline, MacEventKind.failedComms]));
      final drop = events.firstWhere((e) => e.kind == MacEventKind.offline);
      expect(drop.ts, t0);
    });

    test('la clave del evento hace idempotente el upsert', () {
      List<MacEvent> run() => diffMacSnapshots(
            previous: [mac('MER.13', online: true)],
            current: [mac('MER.13', online: false, lastOk: t0)],
            observedAt: t1,
          );
      expect(run().single.eventKey, run().single.eventKey);
    });
  });

  group('episodios de corte', () {
    test('empareja caida con la siguiente recuperacion y mide la duracion', () {
      final outages = outagesOf([
        event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 1, 8)),
        event('MER.13', MacEventKind.online, DateTime.utc(2026, 7, 1, 10, 30)),
      ]);
      final o = outages.single;
      expect(o.durationMinutes, 150);
      expect(o.ongoing, isFalse);
      expect(o.recoveredAt, DateTime.utc(2026, 7, 1, 10, 30));
    });

    test('un corte sin recuperacion queda en curso y cuenta hasta ahora', () {
      final outages = outagesOf(
        [event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 1, 8))],
        now: DateTime.utc(2026, 7, 1, 12),
      );
      expect(outages.single.ongoing, isTrue);
      expect(outages.single.durationMinutes, 240);
    });

    test('dos caidas seguidas cierran la primera sin duracion', () {
      final outages = outagesOf(
        [
          event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 1, 8)),
          event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 2, 8)),
        ],
        now: DateTime.utc(2026, 7, 2, 9),
      );
      expect(outages, hasLength(2));
      final older = outages.last;
      expect(older.durationMinutes, isNull); // nunca se observo que volviera
      expect(outages.first.ongoing, isTrue);
    });

    test('sintetiza el corte de una consola caida sin evento previo', () {
      final outages = outagesOf(
        const [],
        consoles: [
          mac('MER.20', online: false, lastOk: DateTime.utc(2026, 7, 1, 6)),
        ],
        now: DateTime.utc(2026, 7, 1, 12),
      );
      expect(outages.single.code, 'MER.20');
      expect(outages.single.ongoing, isTrue);
      expect(outages.single.durationMinutes, 360);
    });

    test('no duplica el corte si la consola YA tiene uno abierto', () {
      final outages = outagesOf(
        [event('MER.20', MacEventKind.offline, DateTime.utc(2026, 7, 1, 8))],
        consoles: [
          mac('MER.20', online: false, lastOk: DateTime.utc(2026, 7, 1, 6)),
        ],
        now: DateTime.utc(2026, 7, 1, 12),
      );
      expect(outages, hasLength(1));
      expect(outages.single.droppedAt, DateTime.utc(2026, 7, 1, 8));
    });
  });

  group('resumenes', () {
    final history = [
      event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 1, 8),
          description: 'Isla Norte'),
      event('MER.13', MacEventKind.online, DateTime.utc(2026, 7, 1, 9)),
      event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 1, 14)),
      event('MER.13', MacEventKind.online, DateTime.utc(2026, 7, 1, 15)),
      event('MER.14', MacEventKind.failedComms, DateTime.utc(2026, 7, 2, 10)),
      event('MER.14', MacEventKind.bypassOn, DateTime.utc(2026, 7, 2, 11)),
    ];

    test('por consola ordena por caidas', () {
      final rows = byConsoleOf(history, consoles: [mac('MER.13', online: true)]);
      expect(rows.first.code, 'MER.13');
      expect(rows.first.drops, 2);
      expect(rows.first.description, 'Isla Norte');
      expect(rows.first.onlineNow, isTrue);
      final other = rows.firstWhere((r) => r.code == 'MER.14');
      expect(other.commsFailures, 1);
      expect(other.bypassEvents, 1);
      // No esta en el maestro pasado: no se inventa un estado.
      expect(other.onlineNow, isNull);
    });

    test('por dia trae la falla dominante y NO cuenta recuperaciones', () {
      final rows = byDayOf(history);
      final day1 = rows.firstWhere((d) => d.day == DateTime.utc(2026, 7, 1));
      expect(day1.drops, 2);
      expect(day1.total, 2); // las dos recuperaciones no son falla
      expect(day1.mainFault, MacEventKind.offline);
      expect(day1.consolesAffected, 1);
    });

    test('el desglose de fallas excluye recuperacion y fin de bypass', () {
      final kinds = faultBreakdownOf(history).map((f) => f.kind);
      expect(kinds, isNot(contains(MacEventKind.online)));
      expect(kinds, isNot(contains(MacEventKind.bypassOff)));
      expect(kinds, containsAll([
        MacEventKind.offline,
        MacEventKind.failedComms,
        MacEventKind.bypassOn,
      ]));
    });

    test('la serie rellena con ceros los dias sin eventos del rango', () {
      // El historial es forward-only: sin relleno el eje arrancaria el 1 de
      // julio y no en la fecha que el usuario eligio.
      final series = faultsOverTime(
        history,
        from: DateTime.utc(2026, 6, 28),
        to: DateTime.utc(2026, 7, 2),
      );
      expect(series, hasLength(5));
      expect(series.first.period, DateTime.utc(2026, 6, 28));
      expect(series.first.total, 0);
      expect(series[3].drops, 2); // 1 de julio
    });

    test('sin rango el eje lo guian los datos observados', () {
      final series = faultsOverTime(history);
      expect(series, hasLength(2));
    });
  });

  group('flapping', () {
    test('marca la consola con demasiadas caidas en la ventana', () {
      final now = DateTime.utc(2026, 7, 2, 12);
      final rows = flappingOf(
        [
          for (var i = 0; i < 3; i++)
            event('MER.13', MacEventKind.offline,
                now.subtract(Duration(hours: i * 2 + 1))),
        ],
        now: now,
      );
      expect(rows.single.code, 'MER.13');
      expect(rows.single.drops, 3);
    });

    test('las caidas fuera de la ventana no cuentan', () {
      final now = DateTime.utc(2026, 7, 2, 12);
      final rows = flappingOf(
        [
          for (var i = 0; i < 3; i++)
            event('MER.13', MacEventKind.offline,
                now.subtract(Duration(days: i + 2))),
        ],
        now: now,
      );
      expect(rows, isEmpty);
    });
  });

  group('auditoria completa', () {
    test('los KPIs usan la MEDIANA de duracion, no la media', () {
      // Tres cortes de 10 min y uno de 3 dias: la media diria "18 h de corte
      // tipico" sobre una red que casi siempre vuelve en diez minutos.
      final base = DateTime.utc(2026, 7, 1, 8);
      final history = <MacEvent>[
        for (var i = 0; i < 3; i++) ...[
          event('MER.1$i', MacEventKind.offline, base),
          event('MER.1$i', MacEventKind.online,
              base.add(const Duration(minutes: 10))),
        ],
        event('MER.20', MacEventKind.offline, base),
        event('MER.20', MacEventKind.online, base.add(const Duration(days: 3))),
      ];
      final audit = MacHealthAudit.run(
        history: history,
        consoles: [mac('MER.10', online: true), mac('MER.20', online: false)],
        now: DateTime.utc(2026, 7, 5),
      );
      expect(audit.kpis.medianOutageMinutes, 10);
      expect(audit.kpis.drops, 4);
      expect(audit.kpis.consoles, 2);
      expect(audit.kpis.onlineNow, 1);
    });

    test('el rango recorta los eventos', () {
      final audit = MacHealthAudit.run(
        history: [
          event('MER.13', MacEventKind.offline, DateTime.utc(2026, 5, 1)),
          event('MER.13', MacEventKind.offline, DateTime.utc(2026, 7, 1)),
        ],
        from: DateTime.utc(2026, 6, 1),
        now: DateTime.utc(2026, 7, 2),
      );
      expect(audit.events, hasLength(1));
      expect(audit.kpis.drops, 1);
    });

    test('sin historial ni consolas los KPIs son ceros, no nulos', () {
      final audit = MacHealthAudit.run(history: const []);
      expect(audit.kpis.drops, 0);
      expect(audit.kpis.medianOutageMinutes, 0);
      expect(audit.kpis.worstConsole, isNull);
      expect(audit.outages, isEmpty);
    });
  });
}
