import 'package:adapt_mac_notifier/src/msgq/analytics/data_quality.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/equipment.dart';
import 'package:flutter_test/flutter_test.dart';

Equipment eq(String id, {String? make, String? model, String? category}) =>
    Equipment(
      equipmentId: id,
      make: make,
      model: model,
      category: category,
    );

void main() {
  group('normalizacion', () {
    test('la clave colapsa caja, acentos, espacios y puntuacion', () {
      expect(normalizeKey('Ford'), normalizeKey('ford'));
      expect(normalizeKey('  FORD '), normalizeKey('Ford'));
      expect(normalizeKey('BT-50'), normalizeKey('BT 50'));
      expect(normalizeKey('BT-50'), normalizeKey('BT50'));
      expect(normalizeKey('Camión'), normalizeKey('Camion'));
    });

    test('los homoglifos se pliegan solo cuando se pide', () {
      // Campo alfabetico (marca): F0RD == FORD.
      expect(normalizeKey('F0RD', foldHomoglyphs: true),
          normalizeKey('FORD', foldHomoglyphs: true));
      // Campo alfanumerico (modelo): 785D NO debe colapsar con 78SD.
      expect(normalizeKey('785D'), isNot(normalizeKey('78SD')));
    });

    test('display conserva caja y acentos, solo limpia espacios', () {
      expect(normalizeDisplay('  Ford   Ranger '), 'Ford Ranger');
      expect(normalizeDisplay('Camión'), 'Camión');
    });
  });

  group('variantes por normalizacion', () {
    test('agrupa las escrituras del mismo valor y sugiere la mas frecuente', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Ford'),
        eq('B', make: 'Ford'),
        eq('C', make: 'ford'),
        eq('D', make: 'F0RD'),
      ]);
      final cluster =
          audit.clusters.firstWhere((c) => c.field == 'Marca');
      expect(cluster.canonical, 'Ford'); // 2 escrituras, la mas frecuente
      expect(cluster.variants, 3); // Ford, ford, F0RD
      expect(cluster.equipmentCount, 4);
    });

    test('un campo sin variantes no genera grupo sucio', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Ford'),
        eq('B', make: 'Ford'),
      ]);
      expect(audit.clusters.where((c) => c.field == 'Marca'), isEmpty);
    });

    test('el detalle marca cual escritura es la canonica', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Caterpillar'),
        eq('B', make: 'Caterpillar'),
        eq('C', make: 'CATERPILLAR'),
      ]);
      final writings =
          audit.variantDetail.where((v) => v.field == 'Marca').toList();
      final canonical = writings.singleWhere((w) => w.isCanonical);
      expect(canonical.variant, 'Caterpillar');
      expect(canonical.equipmentCount, 2);
      expect(canonical.equipmentIds, 'A, B');
    });

    test('la brecha distintos-vs-reales mide el dirty data', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Ford'),
        eq('B', make: 'ford'),
        eq('C', make: 'Toyota'),
      ]);
      final row = audit.summary.firstWhere((s) => s.field == 'Marca');
      expect(row.distinctValues, 3); // Ford, ford, Toyota
      expect(row.realValues, 2); // FORD, TOYOTA
    });
  });

  group('fuzzy matching', () {
    test('marca un typo que la normalizacion no fusiona', () {
      // 'Caterpillar' vs 'Caterpilar': difieren en una letra, misma clave NO.
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Caterpillar'),
        eq('B', make: 'Caterpilar'),
      ]);
      final pair = audit.fuzzy.firstWhere((f) => f.field == 'Marca');
      expect({pair.valueA, pair.valueB}, {'Caterpillar', 'Caterpilar'});
      expect(pair.similarityPct, greaterThanOrEqualTo(85));
    });

    test('valores muy distintos no se marcan', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Ford'),
        eq('B', make: 'Komatsu'),
      ]);
      expect(audit.fuzzy.where((f) => f.field == 'Marca'), isEmpty);
    });

    test('el ratio reproduce el de difflib (John Deere / Jhon Deere)', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'John Deere'),
        eq('B', make: 'Jhon Deere'),
      ]);
      // La forma de comparacion CONSERVA el espacio (a diferencia de la clave de
      // agrupacion): difflib.SequenceMatcher('JOHN DEERE','JHON DEERE').ratio()
      // == 0.90 (bloques ' DEERE'=6 + J,O,N=3 -> 2*9/20).
      final pair = audit.fuzzy.single;
      expect(pair.similarityPct, closeTo(90.0, 0.1));
    });

    test('cadenas cortas se ignoran (la similitud es volatil)', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'AB'),
        eq('B', make: 'AC'),
      ]);
      expect(audit.fuzzy, isEmpty);
    });
  });

  group('auditoria completa', () {
    test('los KPIs consolidan grupos sucios y pares similares', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Ford', category: 'Camioneta'),
        eq('B', make: 'ford', category: 'Camioneta'),
        eq('C', make: 'Caterpillar'),
        eq('D', make: 'Caterpilar'),
      ]);
      expect(audit.kpis.dirtyGroups, greaterThanOrEqualTo(1));
      expect(audit.kpis.similarPairs, greaterThanOrEqualTo(1));
      expect(audit.kpis.fieldsWithProblems, greaterThanOrEqualTo(1));
    });

    test('un maestro limpio no reporta nada', () {
      final audit = DataQualityAudit.run(equipment: [
        eq('A', make: 'Ford', model: 'Ranger', category: 'Camioneta'),
        eq('B', make: 'Toyota', model: 'Hilux', category: 'Excavadora'),
      ]);
      expect(audit.kpis.dirtyGroups, 0);
      expect(audit.kpis.similarPairs, 0);
      expect(audit.clusters, isEmpty);
    });

    test('sin maestro los resultados son vacios, no nulos', () {
      final audit = DataQualityAudit.run(equipment: const []);
      expect(audit.summary, isEmpty);
      expect(audit.kpis.dirtyGroups, 0);
    });
  });
}
