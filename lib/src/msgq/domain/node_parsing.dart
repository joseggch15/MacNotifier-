/// Helpers de aplanado de nodos GraphQL — port de los privados de
/// `msgq/core/transform.py` (`_dig`, `_label`, `_join_rfids`) y de la coercion
/// de tipos que alli hace pandas (`pd.to_numeric` / `pd.to_datetime`).
///
/// La API entrega los datos anidados (`edges` -> `node`, con sub-objetos como
/// `site { code description }`) y en camelCase; los modelos de `domain/` los
/// aplanan al esquema canonico interno (snake_case) tolerando campos ausentes.
///
/// Dart puro: sin dependencias de Flutter.
library;

/// Navega un mapa anidado de forma segura. `null` si algo del camino falta.
Object? dig(Map<String, dynamic>? node, List<String> path) {
  Object? cur = node;
  for (final key in path) {
    if (cur is! Map) return null;
    cur = cur[key];
  }
  return cur;
}

/// Etiqueta legible de un sub-objeto: `name` > `description` > `code`.
///
/// Es la MISMA precedencia que usa MSGQ, y por eso las claves de cruce (p. ej.
/// producto del despacho vs producto del limite SFL) coinciden entre ambos.
String? label(Object? obj) {
  if (obj is! Map) return null;
  for (final key in const ['name', 'description', 'code']) {
    final v = obj[key];
    if (v != null && v.toString().trim().isNotEmpty) return v.toString();
  }
  return null;
}

/// Une la lista `rfidTags` del maestro en un solo texto (", "), como
/// `transform._join_rfids`. `null` si no hay tags.
String? joinRfids(Object? rfids) {
  if (rfids is List) {
    final tags = rfids
        .where((r) => r != null && r.toString().trim().isNotEmpty)
        .map((r) => r.toString().trim());
    return tags.isEmpty ? null : tags.join(', ');
  }
  final text = rfids?.toString().trim();
  return (text == null || text.isEmpty) ? null : text;
}

/// Numero tolerante: acepta `num`, texto numerico o `null`. Devuelve `null`
/// ante cualquier valor no convertible (equivalente a `errors="coerce"`).
double? asDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().trim());
}

/// Entero tolerante (mismo criterio que [asDouble]).
int? asInt(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim()) ??
      double.tryParse(value.toString().trim())?.toInt();
}

/// Texto no vacio, o `null`. Normaliza el `""` / `"<NA>"` / `"nan"` que dejaba
/// pandas al serializar para que no se cuelen como categorias fantasma.
String? asText(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  const nullish = {'<na>', 'nan', 'null', 'none'};
  return nullish.contains(text.toLowerCase()) ? null : text;
}

/// Booleano tri-estado: `null` cuando el tenant no informa el campo, para poder
/// distinguir "no lo se" de "es falso" (la diferencia importa: una consola sin
/// flag `online` no es una consola caida).
bool? asBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value.toString().trim().toLowerCase();
  if (text.isEmpty) return null;
  if (const {'true', '1', 'yes', 'si', 't'}.contains(text)) return true;
  if (const {'false', '0', 'no', 'f'}.contains(text)) return false;
  return null;
}

/// Fecha ISO-8601 -> `DateTime` en UTC. `null` ante texto invalido.
///
/// Se normaliza SIEMPRE a UTC (la API devuelve offsets como `+11:00` y el
/// simulador fechas sin zona): comparar un instante con offset contra uno naive
/// es la fuente clasica de eventos "perdidos" al filtrar por rango.
DateTime? asDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text)?.toUtc();
}

/// Serializa una fecha al formato con el que viaja y se persiste (ISO-8601 UTC).
String? isoOrNull(DateTime? value) => value?.toUtc().toIso8601String();

/// Redondeo a [digits] decimales, como el `.round(1)` de los reportes de MSGQ.
/// Devuelve `double` (no `num`) para que los agregados sean tipo-estables.
double roundTo(double value, [int digits = 1]) {
  if (!value.isFinite) return value;
  final factor = <int, double>{0: 1, 1: 10, 2: 100, 3: 1000}[digits] ?? 10.0;
  return (value * factor).round() / factor;
}

/// Normaliza una clave categorica: vacia / ausente -> `(sin dato)`.
/// Port de `tank_analytics._key`.
String categoryKey(String? value, {String fallback = '(sin dato)'}) =>
    asText(value) ?? fallback;
