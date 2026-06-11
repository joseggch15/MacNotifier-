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

// --- Auditoria de entregas (port de DELIVERY_* en msgq/config.py) -----------
/// Desviacion relativa minima (%) medidor-vs-guia para marcar una entrega.
const kDefaultVarianceThresholdPct = 1.0;

/// Desviacion (%) a partir de la cual la alerta escala a CRITICA.
const kDeliveryCriticalPct = 5.0;

/// Entregas donde AMBOS volumenes quedan por debajo de esto se ignoran: un %
/// enorme sobre pocos litros no es relevante. OJO: a diferencia de MSGQ (que
/// filtra solo por el volumen MEDIDO), basta con que la guia O el medidor
/// superen el minimo — una entrega partida (19 L medidos vs 40.000 de guia) es
/// justamente el caso que queremos cazar.
const kDeliveryMinVolumeL = 100.0;

/// Ventana hacia atras de la PRIMERA sincronizacion de entregas (sin watermark).
const kDeliveryLookback = Duration(days: 3);

/// Cuanto historial de entregas conserva el snapshot local para la UI.
const kDeliveryKeepDays = 7;

/// Solapamiento al consultar desde el watermark (absorbe desfases de reloj).
const kDeliveryWatermarkOverlap = Duration(minutes: 2);

/// Edad maxima de una entrada en el mapa de condiciones notificadas: pasado
/// esto la entrega ya no se re-consulta y su estado local solo ocupa espacio.
const kDeliveryConditionsMaxAge = Duration(days: 30);

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
    this.monitorDeliveries = true,
    this.varianceThresholdPct = kDefaultVarianceThresholdPct,
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

  /// Monitorear tambien las ENTREGAS (deliveries): varianza medidor-vs-guia y
  /// entregas sin confirmar.
  final bool monitorDeliveries;

  /// Umbral (%) de desviacion medidor-vs-guia para alertar una entrega.
  final double varianceThresholdPct;

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
    bool? monitorDeliveries,
    double? varianceThresholdPct,
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
      monitorDeliveries: monitorDeliveries ?? this.monitorDeliveries,
      varianceThresholdPct: varianceThresholdPct ?? this.varianceThresholdPct,
    );
  }

  /// Cabecera de autenticacion documentada por AdaptIQ.
  Map<String, String> authHeaders() => {
        'Content-Type': 'application/json',
        if (token.trim().isNotEmpty) 'Authorization': 'Token token=${token.trim()}',
      };
}
