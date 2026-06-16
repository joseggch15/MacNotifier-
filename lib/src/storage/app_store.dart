/// Persistencia local (shared_preferences) del monitor.
///
/// Guarda tres familias de datos:
///
///   * `cfg.*`   — la configuracion editable por el usuario.
///   * `cache.*` — descubrimientos contra la API (site id resuelto, campos
///                 opcionales del nodo AdaptMac) para no re-preguntar en cada
///                 ciclo ni en cada arranque del isolate de background.
///   * `state.*` — el ultimo snapshot de consolas y sus condiciones activas:
///                 es la memoria compartida entre el poll de primer plano y el
///                 de Workmanager que hace la deduplicacion de notificaciones.
///
/// El isolate de background escribe sobre el MISMO archivo de preferencias;
/// el de primer plano llama `reload()` antes de cada ciclo para no pisar lo
/// que el worker haya registrado mientras la app estaba cerrada.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_settings.dart';
import '../core/delivery_check.dart';
import '../core/health_check.dart';
import '../core/sfl_check.dart';
import '../core/unauthorised_check.dart';
import '../models/adapt_mac.dart';
import '../models/delivery.dart';

class AppStore {
  AppStore(this._prefs);

  final SharedPreferences _prefs;

  // -- claves -----------------------------------------------------------------
  static const _kEndpoint = 'cfg.endpoint';
  static const _kToken = 'cfg.token';
  static const _kSiteId = 'cfg.siteId';
  static const _kSiteMatch = 'cfg.siteMatch';
  static const _kPollSeconds = 'cfg.pollSeconds';
  static const _kBgMinutes = 'cfg.backgroundMinutes';
  static const _kStaleMinutes = 'cfg.staleMinutes';
  static const _kOfflineAlarmMinutes = 'cfg.offlineAlarmMinutes';
  static const _kNotifEnabled = 'cfg.notificationsEnabled';
  static const _kNotifRecovery = 'cfg.notifyRecovery';
  static const _kMonitorDeliveries = 'cfg.monitorDeliveries';
  static const _kVariancePct = 'cfg.varianceThresholdPct';
  static const _kMonitorOverfill = 'cfg.monitorOverfill';
  static const _kMonitorUnauthorised = 'cfg.monitorUnauthorised';
  static const _kUnauthorisedLanes = 'cfg.unauthorisedLanes';
  static const _kMutedSfl = 'cfg.mutedSflProducts';
  static const _kMutedDeliveries = 'cfg.mutedDeliveryProducts';
  static const _kMutedConsoles = 'cfg.mutedConsoles';
  static const _kLanguage = 'cfg.languageCode';
  static const _kThemeMode = 'cfg.themeMode';

  static const _kCacheSiteId = 'cache.resolvedSiteId';
  static const _kCacheMacFields = 'cache.adaptMacFields';
  static const _kCacheEquipmentField = 'cache.equipmentField';
  static const _kCacheSflLimits = 'cache.sflLimits';
  static const _kCacheSflFetchedAt = 'cache.sflLimitsFetchedAt';
  static const _kCacheUnauthBackfillSite = 'cache.unauthBackfillSite';

  static const _kConditions = 'state.conditions';
  static const _kSnapshot = 'state.snapshot';
  static const _kLastError = 'state.lastError';
  static const _kOfflineSince = 'state.offlineSince';
  static const _kOfflineAlarmed = 'state.offlineAlarmed';
  static const _kUnauthorisedOpen = 'state.unauthorised.open';
  static const _kDeliveryWatermark = 'state.deliveries.watermark';
  static const _kDeliveryConditions = 'state.deliveries.conditions';
  static const _kDeliverySnapshot = 'state.deliveries.snapshot';
  static const _kDispenseWatermark = 'state.dispenses.watermark';
  static const _kOverfillNotified = 'state.overfill.notified';
  static const _kOverfillSnapshot = 'state.overfill.snapshot';
  static const _kKnownProducts = 'state.knownProducts';

  Future<void> reload() => _prefs.reload();

  // -- configuracion ------------------------------------------------------------

  AppSettings loadSettings() {
    return AppSettings(
      endpoint: _prefs.getString(_kEndpoint) ?? kDefaultEndpoint,
      token: _prefs.getString(_kToken) ?? '',
      siteId: _prefs.getString(_kSiteId) ?? '',
      siteMatch: _prefs.getString(_kSiteMatch) ?? kDefaultSiteMatch,
      pollSeconds: _prefs.getInt(_kPollSeconds) ?? kDefaultPollSeconds,
      backgroundMinutes: _prefs.getInt(_kBgMinutes) ?? kDefaultBackgroundMinutes,
      staleMinutes: _prefs.getInt(_kStaleMinutes) ?? kDefaultStaleMinutes,
      offlineAlarmMinutes:
          _prefs.getInt(_kOfflineAlarmMinutes) ?? kDefaultOfflineAlarmMinutes,
      notificationsEnabled: _prefs.getBool(_kNotifEnabled) ?? true,
      notifyRecovery: _prefs.getBool(_kNotifRecovery) ?? true,
      monitorDeliveries: _prefs.getBool(_kMonitorDeliveries) ?? true,
      varianceThresholdPct:
          _prefs.getDouble(_kVariancePct) ?? kDefaultVarianceThresholdPct,
      monitorOverfill: _prefs.getBool(_kMonitorOverfill) ?? true,
      monitorUnauthorised: _prefs.getBool(_kMonitorUnauthorised) ?? true,
      unauthorisedLanes: _prefs.getStringList(_kUnauthorisedLanes) ??
          kDefaultUnauthorisedLanes,
      mutedSflProducts: _prefs.getStringList(_kMutedSfl) ?? const [],
      mutedDeliveryProducts:
          _prefs.getStringList(_kMutedDeliveries) ?? const [],
      mutedConsoles: _prefs.getStringList(_kMutedConsoles) ?? const [],
      languageCode: _prefs.getString(_kLanguage) ?? 'es',
      themeMode: _prefs.getString(_kThemeMode) ?? 'dark',
    );
  }

  Future<void> saveSettings(AppSettings s) async {
    await _prefs.setString(_kEndpoint, s.endpoint);
    await _prefs.setString(_kToken, s.token);
    await _prefs.setString(_kSiteId, s.siteId);
    await _prefs.setString(_kSiteMatch, s.siteMatch);
    await _prefs.setInt(_kPollSeconds, s.pollSeconds);
    await _prefs.setInt(_kBgMinutes, s.backgroundMinutes);
    await _prefs.setInt(_kStaleMinutes, s.staleMinutes);
    await _prefs.setInt(_kOfflineAlarmMinutes, s.offlineAlarmMinutes);
    await _prefs.setBool(_kNotifEnabled, s.notificationsEnabled);
    await _prefs.setBool(_kNotifRecovery, s.notifyRecovery);
    await _prefs.setBool(_kMonitorDeliveries, s.monitorDeliveries);
    await _prefs.setDouble(_kVariancePct, s.varianceThresholdPct);
    await _prefs.setBool(_kMonitorOverfill, s.monitorOverfill);
    await _prefs.setBool(_kMonitorUnauthorised, s.monitorUnauthorised);
    await _prefs.setStringList(_kUnauthorisedLanes, s.unauthorisedLanes);
    await _prefs.setStringList(_kMutedSfl, s.mutedSflProducts);
    await _prefs.setStringList(_kMutedDeliveries, s.mutedDeliveryProducts);
    await _prefs.setStringList(_kMutedConsoles, s.mutedConsoles);
    await _prefs.setString(_kLanguage, s.languageCode);
    await _prefs.setString(_kThemeMode, s.themeMode);
  }

  /// Borra los descubrimientos contra la API. Llamar cuando cambia el
  /// endpoint/sitio: el site id y los campos del esquema ya no aplican.
  Future<void> clearApiCaches() async {
    await _prefs.remove(_kCacheSiteId);
    await _prefs.remove(_kCacheMacFields);
    await _prefs.remove(_kCacheEquipmentField);
    await _prefs.remove(_kCacheSflLimits);
    await _prefs.remove(_kCacheSflFetchedAt);
    // Cambio de sitio: el historial "Sin ID" sembrado ya no aplica; al volver a
    // la pestaña se re-siembra contra el nuevo sitio.
    await _prefs.remove(_kCacheUnauthBackfillSite);
  }

  // -- caches de API --------------------------------------------------------------

  String? get cachedSiteId => _prefs.getString(_kCacheSiteId);

  Future<void> saveCachedSiteId(String? siteId) async {
    if (siteId == null || siteId.isEmpty) return;
    await _prefs.setString(_kCacheSiteId, siteId);
  }

  Set<String>? get cachedAdaptMacFields {
    final raw = _prefs.getStringList(_kCacheMacFields);
    return raw?.toSet();
  }

  Future<void> saveCachedAdaptMacFields(Set<String>? fields) async {
    if (fields == null) return;
    await _prefs.setStringList(_kCacheMacFields, fields.toList()..sort());
  }

  // -- estado de condiciones (dedup de notificaciones) -----------------------------

  /// `null` = primer chequeo de la vida de la app (sin linea base).
  Map<String, Set<ConsoleCondition>>? loadConditions() {
    final raw = _prefs.getString(_kConditions);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return decoded.map((code, names) => MapEntry(code, <ConsoleCondition>{
            if (names is List)
              for (final name in names)
                ...ConsoleCondition.values.where((c) => c.name == name),
          }));
    } on FormatException {
      return null;
    }
  }

  Future<void> saveConditions(Map<String, Set<ConsoleCondition>> conditions) async {
    final encoded = jsonEncode(conditions.map(
        (code, set) => MapEntry(code, [for (final c in set) c.name])));
    await _prefs.setString(_kConditions, encoded);
  }

  // -- snapshot de consolas (UI instantanea al abrir) -------------------------------

  HealthCheckResult? loadSnapshot() {
    final raw = _prefs.getString(_kSnapshot);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final fetchedAt = DateTime.tryParse(decoded['fetchedAt']?.toString() ?? '');
      final consoles = decoded['consoles'];
      if (fetchedAt == null || consoles is! List) return null;
      return HealthCheckResult(
        consoles: [
          for (final c in consoles)
            if (c is Map<String, dynamic>) AdaptMac.fromJson(c),
        ],
        events: const [],
        fetchedAt: fetchedAt.toUtc(),
        deliveries: loadDeliverySnapshot(),
        overfills: loadOverfillSnapshot(),
        unauthorised: sortedOpen(loadUnauthorisedOpen().values),
        offlineSince: loadOfflineSince(),
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> saveSnapshot(HealthCheckResult result) async {
    await _prefs.setString(
      _kSnapshot,
      jsonEncode({
        'fetchedAt': result.fetchedAt.toIso8601String(),
        'consoles': [for (final c in result.consoles) c.toJson()],
      }),
    );
  }

  // -- alarma de caida prolongada (offline sostenido) -----------------------------

  /// code -> instante de la primera observacion offline (UTC).
  Map<String, DateTime> loadOfflineSince() {
    final raw = _prefs.getString(_kOfflineSince);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, DateTime>{};
      for (final e in decoded.entries) {
        final dt = DateTime.tryParse(e.value?.toString() ?? '');
        if (dt != null) out[e.key] = dt.toUtc();
      }
      return out;
    } on FormatException {
      return {};
    }
  }

  Future<void> saveOfflineSince(Map<String, DateTime> since) async {
    await _prefs.setString(
      _kOfflineSince,
      jsonEncode({
        for (final e in since.entries) e.key: e.value.toUtc().toIso8601String(),
      }),
    );
  }

  /// Consolas que ya cruzaron el umbral de alarma (dedup por episodio).
  Set<String> loadOfflineAlarmed() {
    return (_prefs.getStringList(_kOfflineAlarmed) ?? const []).toSet();
  }

  Future<void> saveOfflineAlarmed(Set<String> codes) async {
    await _prefs.setStringList(_kOfflineAlarmed, codes.toList()..sort());
  }

  // -- despachos UNAUTHORISED sin ID (abiertos) ----------------------------------

  /// Mapa id -> txn de los despachos no autorizados sin ID aun ABIERTOS.
  Map<String, UnauthorisedTxn> loadUnauthorisedOpen() {
    final raw = _prefs.getString(_kUnauthorisedOpen);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, UnauthorisedTxn>{};
      for (final e in decoded.entries) {
        final value = e.value;
        if (value is Map<String, dynamic>) {
          out[e.key] = UnauthorisedTxn.fromJson(value);
        }
      }
      return out;
    } on FormatException {
      return {};
    }
  }

  /// Persiste los abiertos, podando los que llevan demasiado tiempo sin
  /// asignarse (por firstSeen / collectedAt) para acotar el almacenamiento.
  Future<void> saveUnauthorisedOpen(
    Map<String, UnauthorisedTxn> open, {
    required DateTime now,
  }) async {
    final cutoff = now.subtract(const Duration(days: kUnauthorisedKeepDays));
    final encoded = <String, dynamic>{};
    for (final e in open.entries) {
      final ref = e.value.firstSeen ?? e.value.collectedAt;
      if (ref != null && ref.toUtc().isBefore(cutoff)) continue; // poda
      encoded[e.key] = e.value.toJson();
    }
    await _prefs.setString(_kUnauthorisedOpen, jsonEncode(encoded));
  }

  /// Funde en el set de ABIERTOS los "sin ID" hallados por el backfill puntual:
  /// preserva tal cual los que el poller ya conocia y sella los nuevos con
  /// [now] como `firstSeen` (asi la poda por retencion no los descarta de
  /// inmediato). Relee del disco antes de fundir para no pisar lo que el poller
  /// haya escrito mientras corria el backfill.
  Future<void> mergeUnauthorisedOpen(
    Iterable<UnauthorisedTxn> found, {
    required DateTime now,
  }) async {
    await _prefs.reload();
    final open = loadUnauthorisedOpen();
    for (final t in found) {
      open[t.id] ??= t.copyWith(firstSeen: t.firstSeen ?? now);
    }
    await saveUnauthorisedOpen(open, now: now);
  }

  /// Sitio (id) cuyo historial "Sin ID" ya se sembro con el backfill puntual.
  /// `null` = aun no se ha hecho (o se cambio de sitio: [clearApiCaches] lo
  /// borra). Evita repetir la pasada larga en cada apertura de la pestaña.
  String? get unauthBackfilledSite =>
      _prefs.getString(_kCacheUnauthBackfillSite);

  Future<void> saveUnauthBackfilledSite(String? siteId) async {
    if (siteId == null || siteId.isEmpty) return;
    await _prefs.setString(_kCacheUnauthBackfillSite, siteId);
  }

  // -- estado de entregas (auditoria de deliveries) -----------------------------------

  /// Marca de agua incremental: el mayor `recordUpdatedAt` ya sincronizado.
  /// `null` = primera sincronizacion (se usa la ventana kDeliveryLookback).
  DateTime? get deliveryWatermark {
    final raw = _prefs.getString(_kDeliveryWatermark);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> saveDeliveryWatermark(DateTime watermark) async {
    await _prefs.setString(
        _kDeliveryWatermark, watermark.toUtc().toIso8601String());
  }

  /// Condiciones ya notificadas por entrega: {id: {"c": [..], "t": iso}}.
  /// El timestamp permite podar entradas viejas (la entrega ya no se actualiza).
  Map<String, Set<DeliveryCondition>> loadDeliveryConditions() {
    final raw = _prefs.getString(_kDeliveryConditions);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, Set<DeliveryCondition>>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final names = value['c'];
        out[entry.key] = <DeliveryCondition>{
          if (names is List)
            for (final name in names)
              ...DeliveryCondition.values.where((c) => c.name == name),
        };
      }
      return out;
    } on FormatException {
      return {};
    }
  }

  Future<void> saveDeliveryConditions(
    Map<String, Set<DeliveryCondition>> conditions, {
    required DateTime now,
  }) async {
    // Conserva el timestamp original de cada entrada para poder podarla
    // cuando supere kDeliveryConditionsMaxAge.
    final previousRaw = _prefs.getString(_kDeliveryConditions);
    var previousTimes = const <String, dynamic>{};
    if (previousRaw != null) {
      try {
        final decoded = jsonDecode(previousRaw);
        if (decoded is Map<String, dynamic>) previousTimes = decoded;
      } on FormatException {
        // snapshot corrupto: se regenera completo
      }
    }
    final encoded = <String, dynamic>{};
    for (final entry in conditions.entries) {
      if (entry.value.isEmpty) continue;
      final prev = previousTimes[entry.key];
      final t = (prev is Map ? prev['t']?.toString() : null) ??
          now.toIso8601String();
      final age = DateTime.tryParse(t);
      if (age != null && now.difference(age.toUtc()) > kDeliveryConditionsMaxAge) {
        continue; // poda: la entrega ya salio de la ventana de actualizacion
      }
      encoded[entry.key] = {
        'c': [for (final c in entry.value) c.name],
        't': t,
      };
    }
    await _prefs.setString(_kDeliveryConditions, jsonEncode(encoded));
  }

  /// Entregas recientes para la UI (ventana local, reemplazadas por id).
  List<Delivery> loadDeliverySnapshot() {
    final raw = _prefs.getString(_kDeliverySnapshot);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final d in decoded)
          if (d is Map<String, dynamic>) Delivery.fromJson(d),
      ];
    } on FormatException {
      return [];
    }
  }

  Future<void> saveDeliverySnapshot(List<Delivery> deliveries) async {
    await _prefs.setString(
      _kDeliverySnapshot,
      jsonEncode([for (final d in deliveries) d.toJson()]),
    );
  }

  // -- auditoria SFL (sobrellenados) ---------------------------------------------------

  /// Conexion de equipos descubierta ('' = el tenant no la expone).
  String? get cachedEquipmentField => _prefs.getString(_kCacheEquipmentField);

  /// Mapa de limites {sflKey: sfl} cacheado, con su fecha de refresco.
  Map<String, double>? loadSflLimits() {
    final raw = _prefs.getString(_kCacheSflLimits);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return {
        for (final e in decoded.entries)
          if (e.value is num) e.key: (e.value as num).toDouble(),
      };
    } on FormatException {
      return null;
    }
  }

  DateTime? get sflLimitsFetchedAt {
    final raw = _prefs.getString(_kCacheSflFetchedAt);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  /// Persiste el refresco de limites. `limits == null` significa "el tenant no
  /// expone equipos": se guarda el marcador para no re-intentar cada ciclo.
  Future<void> saveSflLimits(
    Map<String, double>? limits, {
    required String equipmentField,
    required DateTime now,
  }) async {
    await _prefs.setString(_kCacheEquipmentField, equipmentField);
    await _prefs.setString(_kCacheSflFetchedAt, now.toIso8601String());
    if (limits != null) {
      await _prefs.setString(_kCacheSflLimits, jsonEncode(limits));
    }
  }

  /// Marca de agua incremental de despachos.
  DateTime? get dispenseWatermark {
    final raw = _prefs.getString(_kDispenseWatermark);
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> saveDispenseWatermark(DateTime watermark) async {
    await _prefs.setString(
        _kDispenseWatermark, watermark.toUtc().toIso8601String());
  }

  /// Ids de despachos cuyo sobrellenado YA se proceso (dedup one-shot).
  Set<String> loadNotifiedOverfillIds() {
    final raw = _prefs.getString(_kOverfillNotified);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      return decoded.keys.toSet();
    } on FormatException {
      return {};
    }
  }

  Future<void> saveNotifiedOverfillIds(Set<String> ids,
      {required DateTime now}) async {
    // Mapa id -> timestamp de primera vista, para podar entradas viejas (el
    // despacho ya no vuelve a aparecer en la consulta incremental).
    final previousRaw = _prefs.getString(_kOverfillNotified);
    var previous = const <String, dynamic>{};
    if (previousRaw != null) {
      try {
        final decoded = jsonDecode(previousRaw);
        if (decoded is Map<String, dynamic>) previous = decoded;
      } on FormatException {
        // estado corrupto: se regenera
      }
    }
    final encoded = <String, String>{};
    for (final id in ids) {
      final t = previous[id]?.toString() ?? now.toIso8601String();
      final age = DateTime.tryParse(t);
      if (age != null &&
          now.difference(age.toUtc()) > kDeliveryConditionsMaxAge) {
        continue;
      }
      encoded[id] = t;
    }
    await _prefs.setString(_kOverfillNotified, jsonEncode(encoded));
  }

  /// Sobrellenados recientes para la UI (ventana local kOverfillKeepDays).
  List<OverfillAlert> loadOverfillSnapshot() {
    final raw = _prefs.getString(_kOverfillSnapshot);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final o in decoded)
          if (o is Map<String, dynamic>) OverfillAlert.fromJson(o),
      ];
    } on FormatException {
      return [];
    }
  }

  Future<void> saveOverfillSnapshot(List<OverfillAlert> overfills) async {
    await _prefs.setString(
      _kOverfillSnapshot,
      jsonEncode([for (final o in overfills) o.toJson()]),
    );
  }

  // -- productos conocidos (para la UI de silenciado por producto) ---------------------

  List<String> get knownProducts =>
      _prefs.getStringList(_kKnownProducts) ?? const [];

  /// Acumula etiquetas de producto vistas en los datos (normalizadas), para
  /// que la pantalla de configuracion pueda listarlas como silenciables.
  Future<void> addKnownProducts(Iterable<String?> products) async {
    final merged = {
      ...knownProducts,
      for (final p in products)
        if (normProduct(p).isNotEmpty) normProduct(p),
    }.toList()
      ..sort();
    await _prefs.setStringList(
        _kKnownProducts, merged.take(kMaxKnownProducts).toList());
  }

  // -- ultimo error de sincronizacion ------------------------------------------------

  String? get lastError => _prefs.getString(_kLastError);

  Future<void> saveLastError(String? error) async {
    if (error == null) {
      await _prefs.remove(_kLastError);
    } else {
      await _prefs.setString(_kLastError, error);
    }
  }
}
