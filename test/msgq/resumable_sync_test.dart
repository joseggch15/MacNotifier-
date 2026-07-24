import 'dart:convert';
import 'dart:io';

import 'package:adapt_mac_notifier/src/api/adaptiq_client.dart';
import 'package:adapt_mac_notifier/src/config/app_settings.dart';
import 'package:adapt_mac_notifier/src/msgq/data/msgq_client.dart';
import 'package:adapt_mac_notifier/src/msgq/data/replica_database.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Respuesta GraphQL de una pagina de despachos.
String _dispensePage({
  required List<String> ids,
  required bool hasNext,
  String? endCursor,
}) =>
    jsonEncode({
      'data': {
        'site': {
          'dispenses': {
            'pageInfo': {'hasNextPage': hasNext, 'endCursor': endCursor},
            'edges': [
              for (final id in ids)
                {
                  'node': {
                    'id': id,
                    'volume': 100,
                    'recordUpdatedAt': '2026-06-01T10:00:00Z',
                    'target': {'equipmentId': 'EX01'},
                    'product': {'description': 'Diesel'},
                  }
                },
            ],
          }
        }
      }
    });

/// Cliente que sirve dos paginas de despachos y registra los cursores pedidos.
MsgqClient _client(http.Client http) => MsgqClient(
      AdaptIQClient(
        const AppSettings(endpoint: 'https://x/graphql', token: 't'),
        siteId: 'S1', // evita la query de sitios
        httpClient: http,
      ),
    );

void main() {
  group('fetchMovementsPaged', () {
    test('emite cada pagina y reanuda desde el cursor', () async {
      final cursorsRequested = <String?>[];
      final client = _client(MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        // El paginador descubre campos opcionales por introspeccion antes de
        // pedir la primera pagina; se responde con un tipo sin campos extra.
        if ((body['query'] as String).contains('__type')) {
          return http.Response(
              jsonEncode({
                'data': {
                  '__type': {'fields': []}
                }
              }),
              200);
        }
        final vars = body['variables'] as Map;
        cursorsRequested.add(vars['after'] as String?);
        // Sin cursor -> pagina 1 (hay mas); con 'c1' -> pagina 2 (ultima).
        if (vars['after'] == null) {
          return http.Response(
              _dispensePage(ids: ['d1', 'd2'], hasNext: true, endCursor: 'c1'),
              200);
        }
        return http.Response(
            _dispensePage(ids: ['d3'], hasNext: false, endCursor: 'c2'), 200);
      }));

      final pages = <List<Movement>>[];
      final cursors = <String?>[];
      final hasNexts = <bool>[];
      await client.fetchMovementsPaged(
        kind: MovementKind.dispense,
        onPage: (page, endCursor, hasNext) async {
          pages.add(page);
          cursors.add(endCursor);
          hasNexts.add(hasNext);
        },
      );

      // Dos paginas, la primera con 2 y la segunda con 1.
      expect(pages.map((p) => p.length), [2, 1]);
      expect(cursors, ['c1', 'c2']);
      expect(hasNexts, [true, false]);
      // La segunda peticion llevo el cursor de la primera.
      expect(cursorsRequested, [null, 'c1']);
    });

    test('arrancar con startCursor pide directamente esa pagina', () async {
      String? seen;
      final client = _client(MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        if ((body['query'] as String).contains('__type')) {
          return http.Response(
              jsonEncode({
                'data': {
                  '__type': {'fields': []}
                }
              }),
              200);
        }
        seen = (body['variables'] as Map)['after'] as String?;
        return http.Response(
            _dispensePage(ids: ['d3'], hasNext: false, endCursor: 'c2'), 200);
      }));

      await client.fetchMovementsPaged(
        kind: MovementKind.dispense,
        startCursor: 'c1',
        onPage: (_, __, ___) async {},
      );
      expect(seen, 'c1'); // reanudo desde donde quedo, no desde el principio
    });
  });

  group('replica: cursores de reanudacion', () {
    late ReplicaDatabase db;
    late File file;

    setUp(() async {
      file = File(
          '${Directory.systemTemp.path}/msgq_resume_${DateTime.now().microsecondsSinceEpoch}.sqlite3');
      db = await ReplicaDatabase.open(path: file.path);
    });

    tearDown(() async {
      await db.close();
      if (file.existsSync()) file.deleteSync();
    });

    test('guarda y lee el estado de una conexion', () async {
      expect((await db.resumeState('mv:DISPENSE')).done, isFalse);
      await db.saveResume('mv:DISPENSE', cursor: 'c1', done: false);
      final s = await db.resumeState('mv:DISPENSE');
      expect(s.cursor, 'c1');
      expect(s.done, isFalse);
      await db.saveResume('mv:DISPENSE', cursor: 'c2', done: true);
      expect((await db.resumeState('mv:DISPENSE')).done, isTrue);
    });

    test('allResumed exige que TODAS terminen', () async {
      await db.saveResume('a', cursor: null, done: true);
      await db.saveResume('b', cursor: 'x', done: false);
      expect(await db.allResumed(['a', 'b']), isFalse);
      await db.saveResume('b', cursor: null, done: true);
      expect(await db.allResumed(['a', 'b']), isTrue);
    });

    test('clearResume borra los cursores tras completar', () async {
      await db.saveResume('a', cursor: 'x', done: true);
      await db.clearResume(['a']);
      expect((await db.resumeState('a')).cursor, isNull);
    });

    test('las banderas persisten el ancla del backfill', () async {
      expect(await db.getFlag('mv_from'), isNull);
      await db.setFlag('mv_from', '2025-06-01T00:00:00Z');
      expect(await db.getFlag('mv_from'), '2025-06-01T00:00:00Z');
      await db.clearFlag('mv_from');
      expect(await db.getFlag('mv_from'), isNull);
    });

    test('maxTimestamp devuelve el instante mas alto realmente replicado',
        () async {
      await db.upsertMovements([
        Movement(
            id: 'a',
            kind: MovementKind.dispense,
            updatedAt: DateTime.utc(2026, 6, 1)),
        Movement(
            id: 'b',
            kind: MovementKind.dispense,
            updatedAt: DateTime.utc(2026, 7, 15)),
        Movement(
            id: 'c',
            kind: MovementKind.dispense,
            updatedAt: DateTime.utc(2026, 5, 1)),
      ]);
      final max = await db.maxTimestamp(ReplicaTable.movements, 'updated_at');
      expect(max, DateTime.utc(2026, 7, 15));
    });

    test('una replica v5 recien creada tiene las tablas de reanudacion', () async {
      // Si las tablas no existieran, estas llamadas lanzarian.
      expect(await db.allResumed(const []), isTrue);
      expect(await db.getFlag('cualquiera'), isNull);
    });
  });
}
