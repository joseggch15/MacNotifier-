/// Utilidades puras compartidas por la UI y las notificaciones.
library;

/// Comparacion "natural" de codigos de consola: MER.2 < MER.10 < MER.16
/// (la comparacion lexicografica pondria MER.10 antes que MER.2).
int naturalCompare(String a, String b) {
  final re = RegExp(r'\d+|\D+');
  final xs = re.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final ys = re.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  final n = xs.length < ys.length ? xs.length : ys.length;
  for (var i = 0; i < n; i++) {
    final nx = int.tryParse(xs[i]);
    final ny = int.tryParse(ys[i]);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : xs[i].compareTo(ys[i]);
    if (c != 0) return c;
  }
  return xs.length.compareTo(ys.length);
}

/// "hace 5 min" / "hace 2 h" / "hace 3 d" (espanol corto para subtitulos).
String relativeEs(DateTime dt, {DateTime? now}) {
  var diff = (now ?? DateTime.now().toUtc()).difference(dt.toUtc());
  if (diff.isNegative) diff = Duration.zero;
  if (diff.inMinutes < 1) return 'hace segundos';
  if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'hace ${diff.inHours} h';
  return 'hace ${diff.inDays} d';
}

/// Identificador estable de 31 bits (FNV-1a) para ids de notificacion: la
/// misma consola+condicion siempre mapea al mismo id, asi la recuperacion
/// REEMPLAZA a la alerta en la bandeja en vez de apilarse.
int stableId(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}
