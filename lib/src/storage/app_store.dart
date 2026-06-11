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
import '../core/health_check.dart';
import '../models/adapt_mac.dart';

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
  static const _kNotifEnabled = 'cfg.notificationsEnabled';
  static const _kNotifRecovery = 'cfg.notifyRecovery';

  static const _kCacheSiteId = 'cache.resolvedSiteId';
  static const _kCacheMacFields = 'cache.adaptMacFields';

  static const _kConditions = 'state.conditions';
  static const _kSnapshot = 'state.snapshot';
  static const _kLastError = 'state.lastError';

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
      notificationsEnabled: _prefs.getBool(_kNotifEnabled) ?? true,
      notifyRecovery: _prefs.getBool(_kNotifRecovery) ?? true,
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
    await _prefs.setBool(_kNotifEnabled, s.notificationsEnabled);
    await _prefs.setBool(_kNotifRecovery, s.notifyRecovery);
  }

  /// Borra los descubrimientos contra la API. Llamar cuando cambia el
  /// endpoint/sitio: el site id y los campos del esquema ya no aplican.
  Future<void> clearApiCaches() async {
    await _prefs.remove(_kCacheSiteId);
    await _prefs.remove(_kCacheMacFields);
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
