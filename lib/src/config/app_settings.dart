/// Configuracion de conexion y del motor de monitoreo.
///
/// Espejo movil de `msgq/config.py` (Settings): mismos defaults del tenant
/// Newmont Merian, misma cabecera de autenticacion documentada en
/// «AdaptIQ Customer Facing GraphQL APIs (July 2023)» y el mismo umbral de
/// comunicacion stale (ADAPTMAC_STALE_MINUTES = 30).
library;

const kDefaultEndpoint = 'https://merian.veridapt.io/graphql'; // tenant Newmont Merian
const kDefaultSiteMatch = 'Merian';
const kDefaultPollSeconds = 20; // polling con la app ABIERTA (igual que MSGQ)
const kDefaultBackgroundMinutes = 15; // minimo que permite WorkManager/iOS
const kDefaultStaleMinutes = 30; // = config.ADAPTMAC_STALE_MINUTES de MSGQ
const kPageSize = 100; // la API limita a 100 registros por pagina

class AppSettings {
  const AppSettings({
    this.endpoint = kDefaultEndpoint,
    this.token = '',
    this.siteId = '',
    this.siteMatch = kDefaultSiteMatch,
    this.pollSeconds = kDefaultPollSeconds,
    this.backgroundMinutes = kDefaultBackgroundMinutes,
    this.staleMinutes = kDefaultStaleMinutes,
    this.notificationsEnabled = true,
    this.notifyRecovery = true,
  });

  /// Endpoint GraphQL del tenant.
  final String endpoint;

  /// Token de la API: viaja como `Authorization: Token token=<token>`.
  final String token;

  /// Site id fijo. Vacio = autodescubrir via la query `sites` usando [siteMatch].
  final String siteId;

  /// Subcadena para elegir el sitio cuando [siteId] esta vacio.
  final String siteMatch;

  /// Cadencia del polling con la app en primer plano (segundos).
  final int pollSeconds;

  /// Cadencia del chequeo en segundo plano (minutos; Android impone >= 15).
  final int backgroundMinutes;

  /// Minutos sin comunicacion exitosa tras los cuales una consola se reporta
  /// "stale" aunque el flag `online` siga en verdadero.
  final int staleMinutes;

  /// Interruptor global de notificaciones locales.
  final bool notificationsEnabled;

  /// Notificar tambien la RECUPERACION (consola reconectada / bypass retirado).
  final bool notifyRecovery;

  /// Sin token no se puede hablar con la API real.
  bool get isConfigured => token.trim().isNotEmpty;

  Duration get staleAfter => Duration(minutes: staleMinutes);

  AppSettings copyWith({
    String? endpoint,
    String? token,
    String? siteId,
    String? siteMatch,
    int? pollSeconds,
    int? backgroundMinutes,
    int? staleMinutes,
    bool? notificationsEnabled,
    bool? notifyRecovery,
  }) {
    return AppSettings(
      endpoint: endpoint ?? this.endpoint,
      token: token ?? this.token,
      siteId: siteId ?? this.siteId,
      siteMatch: siteMatch ?? this.siteMatch,
      pollSeconds: pollSeconds ?? this.pollSeconds,
      backgroundMinutes: backgroundMinutes ?? this.backgroundMinutes,
      staleMinutes: staleMinutes ?? this.staleMinutes,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notifyRecovery: notifyRecovery ?? this.notifyRecovery,
    );
  }

  /// Cabecera de autenticacion documentada por AdaptIQ.
  Map<String, String> authHeaders() => {
        'Content-Type': 'application/json',
        if (token.trim().isNotEmpty) 'Authorization': 'Token token=${token.trim()}',
      };
}
