/// Auditoria de integridad de datos maestros (dirty data / fuzzy matching) —
/// port de `msgq/core/data_quality.py`.
///
/// El problema clasico "Ford vs ford vs FORD vs 'ford ' vs F0RD": variantes del
/// MISMO valor que conviven en el maestro y rompen las agrupaciones de KPIs —
/// cada escritura cuenta como una categoria distinta, inflando conteos y
/// repartiendo mal los totales.
///
/// Dos detectores, sin dependencias externas:
///
///   * VARIANTES POR NORMALIZACION: agrupa por una clave normalizada
///     (mayusculas, sin acentos, sin puntuacion ni espacios y —en campos
///     alfabeticos— con homoglifos 0/O 1/I 5/S 8/B plegados). Un grupo con dos o
///     mas escrituras crudas es dirty data: se sugiere la mas frecuente como
///     canonica y se listan las variantes que la ensucian.
///   * DUPLICADOS LEXICOS (fuzzy): compara los valores por similitud de cadena.
///     Pares parecidos pero no identicos delatan typos/OCR que la normalizacion
///     no fusiono ('Caterpillar' vs 'Caterpilar').
///
/// Corre sobre el maestro COMPLETO: la calidad del dato es una propiedad del
/// registro, no del filtro de la vista.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/equipment.dart';

/// Un campo del maestro a auditar.
///
/// [foldHomoglyphs] solo se activa en campos ALFABETICOS (marca, categoria): en
/// los alfanumericos (modelo, centro de costo) plegar 0->O corromperia codigos
/// legitimos como '785D' o 'D10T'.
class MasterField {
  const MasterField(this.column, this.label, {this.foldHomoglyphs = false});

  final String column;
  final String label;
  final bool foldHomoglyphs;

  /// Extrae el valor de este campo de un equipo.
  String? valueOf(Equipment e) => switch (column) {
        'make' => e.make,
        'model' => e.model,
        'category' => e.category,
        'group' => e.group,
        'department' => e.department,
        'cost_centre' => e.costCentre,
        _ => null,
      };
}

/// Campos maestros auditados por defecto.
const List<MasterField> masterFields = [
  MasterField('make', 'Marca', foldHomoglyphs: true),
  MasterField('model', 'Modelo'),
  MasterField('category', 'Categoria', foldHomoglyphs: true),
  MasterField('group', 'Grupo', foldHomoglyphs: true),
  MasterField('department', 'Departamento', foldHomoglyphs: true),
  MasterField('cost_centre', 'Centro de costo'),
];

const int _maxIdsListed = 100;
const double _fuzzyThreshold = 0.85;
const int _fuzzyMinLen = 3;
const int _fuzzyMaxValues = 2500;

const Map<String, String> _homoglyphs = {'0': 'O', '1': 'I', '5': 'S', '8': 'B'};

/// Limpieza minima legible: colapsa espacios (incluido el NBSP) y recorta. No
/// cambia mayusculas ni acentos — es lo que se sugiere como canonico.
String normalizeDisplay(String? value) {
  if (value == null) return '';
  return value.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _stripAccents(String s) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
  const to = 'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC';
  final buffer = StringBuffer();
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buffer.write(i >= 0 ? to[i] : ch);
  }
  return buffer.toString();
}

/// Clave de agrupacion: mayusculas, sin acentos, sin puntuacion ni espacios y,
/// si se pide, con homoglifos plegados. Dos valores con la MISMA clave son la
/// misma cosa escrita distinto ('FORD'/'Ford'/'F0RD', o 'BT-50'/'BT 50'/'BT50').
/// Quitar la puntuacion deja esos casos al detector EXACTO y reserva el fuzzy
/// para typos reales.
String normalizeKey(String? value, {bool foldHomoglyphs = false}) {
  final display = normalizeDisplay(value);
  if (display.isEmpty) return '';
  var key = _stripAccents(display).toUpperCase();
  if (foldHomoglyphs) {
    key = key.split('').map((c) => _homoglyphs[c] ?? c).join();
  }
  return key.replaceAll(RegExp(r'[^A-Z0-9]'), '');
}

/// Forma para comparar por similitud (insensible a caja y acentos).
String _comparisonForm(String? value) =>
    _stripAccents(normalizeDisplay(value)).toUpperCase();

bool _isBlank(String? value) {
  final t = value?.trim();
  if (t == null || t.isEmpty) return true;
  return const {'<na>', 'nan', 'none', 'null'}.contains(t.toLowerCase());
}

// ===========================================================================
// Modelos de resultado
// ===========================================================================

/// Una escritura concreta de una variante, con los equipos que la usan.
class VariantWriting {
  const VariantWriting({
    required this.field,
    required this.canonical,
    required this.variant,
    required this.isCanonical,
    required this.equipmentCount,
    required this.equipmentIds,
  });

  final String field;
  final String canonical;
  final String variant;
  final bool isCanonical;
  final int equipmentCount;

  /// Ids de equipo que usan esta escritura (truncado con nota si son muchos).
  final String equipmentIds;
}

/// Un grupo sucio: dos o mas escrituras de la misma clave normalizada.
class VariantCluster {
  const VariantCluster({
    required this.field,
    required this.canonical,
    required this.variants,
    required this.equipmentCount,
    required this.writings,
  });

  final String field;

  /// Escritura sugerida como canonica (la mas frecuente).
  final String canonical;

  final int variants;
  final int equipmentCount;

  /// "«Ford» (12) · «ford» (3) · «F0RD» (1)".
  final String writings;
}

/// Un par de valores parecidos que la normalizacion no fusiono.
class FuzzyPair {
  const FuzzyPair({
    required this.field,
    required this.valueA,
    required this.equipmentA,
    required this.valueB,
    required this.equipmentB,
    required this.similarityPct,
  });

  final String field;
  final String valueA;
  final int equipmentA;
  final String valueB;
  final int equipmentB;
  final double similarityPct;
}

/// Fila del resumen por campo.
class DataQualitySummaryRow {
  const DataQualitySummaryRow({
    required this.field,
    required this.distinctValues,
    required this.realValues,
    required this.dirtyGroups,
    required this.equipmentAffected,
    required this.similarPairs,
  });

  final String field;

  /// Escrituras crudas distintas.
  final int distinctValues;

  /// Valores REALES (claves normalizadas distintas). La brecha contra
  /// [distinctValues] es la magnitud del dirty data.
  final int realValues;

  final int dirtyGroups;
  final int equipmentAffected;
  final int similarPairs;

  bool get hasProblems => dirtyGroups > 0 || similarPairs > 0;
}

class DataQualityKpis {
  const DataQualityKpis({
    required this.fieldsWithProblems,
    required this.dirtyGroups,
    required this.equipmentAffected,
    required this.similarPairs,
  });

  final int fieldsWithProblems;
  final int dirtyGroups;
  final int equipmentAffected;
  final int similarPairs;
}

// ===========================================================================
// Auditoria
// ===========================================================================

class DataQualityAudit {
  const DataQualityAudit._({
    required this.summary,
    required this.variantDetail,
    required this.clusters,
    required this.fuzzy,
    required this.kpis,
  });

  final List<DataQualitySummaryRow> summary;
  final List<VariantWriting> variantDetail;
  final List<VariantCluster> clusters;
  final List<FuzzyPair> fuzzy;
  final DataQualityKpis kpis;

  /// Audita todos los campos del maestro en una sola pasada.
  static DataQualityAudit run({
    required List<Equipment> equipment,
    List<MasterField> fields = masterFields,
  }) {
    final summary = <DataQualitySummaryRow>[];
    final variantDetail = <VariantWriting>[];
    final clusters = <VariantCluster>[];
    final fuzzy = <FuzzyPair>[];

    for (final field in fields) {
      final frame = _fieldFrame(equipment, field);
      if (frame.isEmpty) continue;
      final fieldClusters = _clustersOf(frame, field.label);
      final fieldDetail = _detailOf(frame, field.label);
      final fieldFuzzy = _fuzzyOf(frame, field.label);
      clusters.addAll(fieldClusters);
      variantDetail.addAll(fieldDetail);
      fuzzy.addAll(fieldFuzzy);
      summary.add(DataQualitySummaryRow(
        field: field.label,
        distinctValues: frame.map((r) => r.raw).toSet().length,
        realValues: frame.map((r) => r.key).toSet().length,
        dirtyGroups: fieldClusters.length,
        equipmentAffected:
            fieldClusters.fold<int>(0, (acc, c) => acc + c.equipmentCount),
        similarPairs: fieldFuzzy.length,
      ));
    }
    summary.sort((a, b) {
      final byDirty = b.dirtyGroups.compareTo(a.dirtyGroups);
      return byDirty != 0 ? byDirty : b.similarPairs.compareTo(a.similarPairs);
    });
    clusters.sort((a, b) {
      final byVariants = b.variants.compareTo(a.variants);
      return byVariants != 0
          ? byVariants
          : b.equipmentCount.compareTo(a.equipmentCount);
    });
    fuzzy.sort((a, b) => b.similarityPct.compareTo(a.similarityPct));

    final dirty = summary.where((s) => s.hasProblems);
    return DataQualityAudit._(
      summary: List.unmodifiable(summary),
      variantDetail: List.unmodifiable(variantDetail),
      clusters: List.unmodifiable(clusters),
      fuzzy: List.unmodifiable(fuzzy),
      kpis: DataQualityKpis(
        fieldsWithProblems: dirty.length,
        dirtyGroups: summary.fold<int>(0, (acc, s) => acc + s.dirtyGroups),
        equipmentAffected:
            summary.fold<int>(0, (acc, s) => acc + s.equipmentAffected),
        similarPairs: summary.fold<int>(0, (acc, s) => acc + s.similarPairs),
      ),
    );
  }
}

/// Fila auxiliar del frame de un campo.
class _FieldRow {
  const _FieldRow(this.id, this.raw, this.key);

  final String id;
  final String raw;
  final String key;
}

List<_FieldRow> _fieldFrame(List<Equipment> equipment, MasterField field) {
  final out = <_FieldRow>[];
  for (var i = 0; i < equipment.length; i++) {
    final e = equipment[i];
    final raw = field.valueOf(e);
    if (_isBlank(raw)) continue;
    final key = normalizeKey(raw, foldHomoglyphs: field.foldHomoglyphs);
    if (key.isEmpty) continue;
    out.add(_FieldRow(e.equipmentId ?? '#$i', raw!, key));
  }
  return out;
}

/// Agrupa por clave y devuelve solo los grupos SUCIOS (dos o mas escrituras),
/// con las escrituras ordenadas por frecuencia descendente.
List<({String canonical, List<MapEntry<String, int>> writings, List<_FieldRow> rows})>
    _dirtyGroups(List<_FieldRow> frame) {
  final byKey = <String, List<_FieldRow>>{};
  for (final r in frame) {
    byKey.putIfAbsent(r.key, () => <_FieldRow>[]).add(r);
  }
  final out = <({
    String canonical,
    List<MapEntry<String, int>> writings,
    List<_FieldRow> rows
  })>[];
  for (final rows in byKey.values) {
    final counts = <String, int>{};
    for (final r in rows) {
      counts[r.raw] = (counts[r.raw] ?? 0) + 1;
    }
    if (counts.length < 2) continue; // limpio: una sola escritura
    final writings = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    out.add((canonical: writings.first.key, writings: writings, rows: rows));
  }
  return out;
}

List<VariantCluster> _clustersOf(List<_FieldRow> frame, String label) {
  return _dirtyGroups(frame)
      .map((g) => VariantCluster(
            field: label,
            canonical: normalizeDisplay(g.canonical),
            variants: g.writings.length,
            equipmentCount: g.rows.length,
            writings:
                g.writings.map((w) => '«${w.key}» (${w.value})').join(' · '),
          ))
      .toList();
}

List<VariantWriting> _detailOf(List<_FieldRow> frame, String label) {
  final out = <VariantWriting>[];
  for (final g in _dirtyGroups(frame)) {
    for (final w in g.writings) {
      final ids = g.rows.where((r) => r.raw == w.key).map((r) => r.id);
      out.add(VariantWriting(
        field: label,
        canonical: normalizeDisplay(g.canonical),
        variant: w.key,
        isCanonical: w.key == g.canonical,
        equipmentCount: w.value,
        equipmentIds: _joinIds(ids),
      ));
    }
  }
  // La canonica primero dentro de cada grupo, luego por numero de equipos.
  out.sort((a, b) {
    final byField = a.field.compareTo(b.field);
    if (byField != 0) return byField;
    final byCanon = a.canonical.compareTo(b.canonical);
    if (byCanon != 0) return byCanon;
    if (a.isCanonical != b.isCanonical) return a.isCanonical ? -1 : 1;
    return b.equipmentCount.compareTo(a.equipmentCount);
  });
  return out;
}

String _joinIds(Iterable<String> ids) {
  final unique = ids.where((i) => i.isNotEmpty).toSet().toList()..sort();
  if (unique.length <= _maxIdsListed) return unique.join(', ');
  return '${unique.take(_maxIdsListed).join(', ')}  … (+${unique.length - _maxIdsListed})';
}

// ===========================================================================
// Fuzzy matching
// ===========================================================================

List<FuzzyPair> _fuzzyOf(List<_FieldRow> frame, String label) {
  // Representante por clave: escritura mas frecuente + numero de equipos.
  final byKey = <String, List<_FieldRow>>{};
  for (final r in frame) {
    byKey.putIfAbsent(r.key, () => <_FieldRow>[]).add(r);
  }
  final reps = <({String display, int count, String cmp})>[];
  for (final rows in byKey.values) {
    final counts = <String, int>{};
    for (final r in rows) {
      counts[r.raw] = (counts[r.raw] ?? 0) + 1;
    }
    final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final display = normalizeDisplay(top.key);
    if (display.length >= _fuzzyMinLen) {
      reps.add((display: display, count: rows.length, cmp: _comparisonForm(display)));
    }
  }
  if (reps.length < 2 || reps.length > _fuzzyMaxValues) return const [];

  // Cota por longitud: si min/max < ratioFloor, el ratio no puede llegar al
  // umbral. Ahorra el calculo completo O(n·m) sobre la mayoria de los pares.
  final ratioFloor = _fuzzyThreshold / (2.0 - _fuzzyThreshold);
  final out = <FuzzyPair>[];
  for (var i = 0; i < reps.length; i++) {
    final a = reps[i];
    for (var j = i + 1; j < reps.length; j++) {
      final b = reps[j];
      if (a.cmp == b.cmp) continue;
      final la = a.cmp.length;
      final lb = b.cmp.length;
      final minLen = la < lb ? la : lb;
      final maxLen = la > lb ? la : lb;
      if (minLen < ratioFloor * maxLen) continue;
      final sim = _sequenceRatio(a.cmp, b.cmp);
      if (sim >= _fuzzyThreshold) {
        out.add(FuzzyPair(
          field: label,
          valueA: a.display,
          equipmentA: a.count,
          valueB: b.display,
          equipmentB: b.count,
          similarityPct: (sim * 1000).round() / 10,
        ));
      }
    }
  }
  return out;
}

/// Ratio de similitud al estilo de `difflib.SequenceMatcher.ratio`:
/// 2 * coincidencias / (len(a) + len(b)).
///
/// Se reimplementa el algoritmo de bloques coincidentes de difflib (no una
/// simple distancia de edicion) para que el umbral 0.85 signifique lo mismo que
/// en el escritorio y ambos marquen los mismos pares.
double _sequenceRatio(String a, String b) {
  final total = a.length + b.length;
  if (total == 0) return 1;
  return 2 * _matchingBlocks(a, b) / total;
}

/// Numero total de caracteres en los bloques coincidentes, con el mismo enfoque
/// recursivo de difflib: se busca el bloque comun mas largo y se recurre a los
/// lados. `b2j` (indice de posiciones por caracter de `b`) reproduce el atajo
/// que difflib usa para hallar ese bloque.
int _matchingBlocks(String a, String b) {
  final b2j = <String, List<int>>{};
  for (var j = 0; j < b.length; j++) {
    b2j.putIfAbsent(b[j], () => <int>[]).add(j);
  }

  int findLongest(int alo, int ahi, int blo, int bhi) {
    var bestI = alo;
    var bestJ = blo;
    var bestSize = 0;
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final newJ2len = <int, int>{};
      for (final j in b2j[a[i]] ?? const <int>[]) {
        if (j < blo) continue;
        if (j >= bhi) break;
        final k = (j2len[j - 1] ?? 0) + 1;
        newJ2len[j] = k;
        if (k > bestSize) {
          bestI = i - k + 1;
          bestJ = j - k + 1;
          bestSize = k;
        }
      }
      j2len = newJ2len;
    }
    if (bestSize == 0) return 0;
    return bestSize +
        findLongest(alo, bestI, blo, bestJ) +
        findLongest(bestI + bestSize, ahi, bestJ + bestSize, bhi);
  }

  return findLongest(0, a.length, 0, b.length);
}
