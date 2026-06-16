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

// --- Alarma de caida prolongada (offline sostenido) -------------------------
/// Minutos que una consola OFFLINE (no silenciada) debe permanecer caida antes
/// de ESCALAR de la notificacion informativa a una alarma "estilo despertador"
/// (sonido insistente + pantalla completa). Por defecto 30 min, igual que el
/// umbral stale de MSGQ: media hora caida ya no es un parpadeo de red.
const kDefaultOfflineAlarmMinutes = 30;

// --- Despachos UNAUTHORISED sin equipo asignado -----------------------------
/// Puntos de despacho (lanes) cuyos despachos `Unauthorised` SIN ID de equipo
/// se vigilan. Por defecto los tres carriles del LFO de Merian que el auditor
/// revisa en AdaptIQ (Movements -> Dispenses, filtro Types: Unauthorised).
const kDefaultUnauthorisedLanes = <String>[
  'LFO Delivery and LV Bay (Lane 1)',
  'LFO Dispense Lane 2',
  'LFO Dispense Lane 3',
];

/// Cuanto se conserva un despacho UNAUTHORISED "abierto" (sin ID) en el estado
/// local antes de podarlo si nunca llega a asignarsele un equipo.
///
/// La pestaña "Sin ID" se sirve de este conjunto incremental (no re-descarga la
/// ventana de la API en cada periodo), asi que la retencion define la
/// profundidad maxima visible: 1 año cubre el periodo "Anual" y "Todos". El
/// conjunto de abiertos es chico (son excepciones, no el trafico normal), asi
/// que conservar un año en local es barato.
const kUnauthorisedKeepDays = 365;

/// Ventana hacia atras del BACKFILL puntual de "Sin ID": la primera vez (o tras
/// cambiar de sitio) se hace UNA sola pasada paginada para sembrar los
/// despachos no autorizados sin ID que quedaron abiertos antes de instalar la
/// app; despues el poller incremental los mantiene. Acotada e interrumpible.
const kUnauthorisedBackfillWindow = Duration(days: kUnauthorisedKeepDays);

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

// --- Auditoria SFL / sobrellenados (port de SFL_* en msgq/config.py) ---------
/// Tolerancia relativa antes de marcar un exceso de SFL: solo se reporta si
/// volume > sfl * (1 + tolerancia). Filtra el ruido de medicion (~0.5-1% de
/// error de los medidores). = config.SFL_TOLERANCE_PCT de MSGQ.
const kSflTolerancePct = 0.02;

/// Exceso relativo (% sobre el SFL) a partir del cual la alerta es CRITICA.
const kSflCriticalExcessPct = 10.0;

/// Ventana hacia atras de la PRIMERA sincronizacion de despachos.
const kDispenseLookback = Duration(days: 1);

/// Cuanto historial de sobrellenados conserva el snapshot local para la UI.
const kOverfillKeepDays = 7;

/// Cada cuanto se refresca el mapa de limites SFL (equipos + consumptionTanks
/// es la consulta mas pesada: el maestro cambia poco, una vez al dia basta).
const kSflLimitsMaxAge = Duration(hours: 24);

/// Tope de productos "conocidos" que se acumulan para la UI de silenciado.
const kMaxKnownProducts = 60;

/// Normaliza una etiqueta de producto para cruces y silenciado (igual que
/// `_norm` en msgq/core/sfl_audit.py: texto, strip, upper).
String normProduct(String? product) => (product ?? '').trim().toUpperCase();

class AppSettings {
  const AppSettings({
    this.endpoint = kDefaultEndpoint,
    this.token = '',
    this.siteId = '',
    this.siteMatch = kDefaultSiteMatch,
    this.pollSeconds = kDefaultPollSeconds,
    this.backgroundMinutes = kDefaultBackgroundMinutes,
    this.staleMinutes = kDefaultStaleMinutes,
    this.offlineAlarmMinutes = kDefaultOfflineAlarmMinutes,
    this.notificationsEnabled = true,
    this.notifyRecovery = true,
    this.monitorDeliveries = true,
    this.varianceThresholdPct = kDefaultVarianceThresholdPct,
    this.monitorOverfill = true,
    this.monitorUnauthorised = true,
    this.unauthorisedLanes = kDefaultUnauthorisedLanes,
    this.mutedSflProducts = const [],
    this.mutedDeliveryProducts = const [],
    this.mutedConsoles = const [],
    this.languageCode = 'es',
    this.themeMode = 'dark',
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

  /// Minutos que una consola OFFLINE no silenciada debe permanecer caida antes
  /// de escalar a la alarma "estilo despertador".
  final int offlineAlarmMinutes;

  /// Interruptor global de notificaciones locales.
  final bool notificationsEnabled;

  /// Notificar tambien la RECUPERACION (consola reconectada / bypass retirado).
  final bool notifyRecovery;

  /// Monitorear tambien las ENTREGAS (deliveries): varianza medidor-vs-guia y
  /// entregas sin confirmar.
  final bool monitorDeliveries;

  /// Umbral (%) de desviacion medidor-vs-guia para alertar una entrega.
  final double varianceThresholdPct;

  /// Monitorear sobrellenados de SFL (despachos que exceden el Safe Fill Level
  /// del equipo para ese producto — la alarma "Equipment Overfill" de AdaptIQ).
  final bool monitorOverfill;

  /// Monitorear despachos `Unauthorised` SIN ID de equipo asignado en los
  /// [unauthorisedLanes]: tan pronto AdaptIQ les asigna un equipo, salen de la
  /// lista.
  final bool monitorUnauthorised;

  /// Puntos de despacho vigilados para el monitor de no autorizados sin ID.
  final List<String> unauthorisedLanes;

  /// Productos SILENCIADOS para las alertas de SFL (etiquetas normalizadas con
  /// [normProduct]). El interes principal es el diesel: el resto se puede callar.
  final List<String> mutedSflProducts;

  /// Productos SILENCIADOS para las alertas de entregas.
  final List<String> mutedDeliveryProducts;

  /// Consolas AdaptMAC silenciadas (por codigo): el usuario puede apagar las
  /// notificaciones de un MAC concreto (p. ej. los service trucks) sin dejar
  /// de verlo en la pestaña Consolas.
  final List<String> mutedConsoles;

  /// Idioma de la UI y de las notificaciones: 'es' (defecto) o 'en'.
  final String languageCode;

  /// Tema visual: 'dark' (defecto), 'light' o 'system'.
  final String themeMode;

  bool isSflProductMuted(String? product) =>
      mutedSflProducts.contains(normProduct(product));

  bool isDeliveryProductMuted(String? product) =>
      mutedDeliveryProducts.contains(normProduct(product));

  bool isConsoleMuted(String? code) =>
      code != null && mutedConsoles.contains(code.trim());

  /// Lanes vigilados, normalizados (trim + upper) para cruzar contra el punto
  /// de despacho de cada movimiento — misma normalizacion que los productos.
  Set<String> get normalizedUnauthorisedLanes =>
      {for (final lane in unauthorisedLanes) normProduct(lane)}
        ..removeWhere((l) => l.isEmpty);

  /// Sin token no se puede hablar con la API real.
  bool get isConfigured => token.trim().isNotEmpty;

  Duration get staleAfter => Duration(minutes: staleMinutes);

  Duration get offlineAlarmAfter => Duration(minutes: offlineAlarmMinutes);

  AppSettings copyWith({
    String? endpoint,
    String? token,
    String? siteId,
    String? siteMatch,
    int? pollSeconds,
    int? backgroundMinutes,
    int? staleMinutes,
    int? offlineAlarmMinutes,
    bool? notificationsEnabled,
    bool? notifyRecovery,
    bool? monitorDeliveries,
    double? varianceThresholdPct,
    bool? monitorOverfill,
    bool? monitorUnauthorised,
    List<String>? unauthorisedLanes,
    List<String>? mutedSflProducts,
    List<String>? mutedDeliveryProducts,
    List<String>? mutedConsoles,
    String? languageCode,
    String? themeMode,
  }) {
    return AppSettings(
      endpoint: endpoint ?? this.endpoint,
      token: token ?? this.token,
      siteId: siteId ?? this.siteId,
      siteMatch: siteMatch ?? this.siteMatch,
      pollSeconds: pollSeconds ?? this.pollSeconds,
      backgroundMinutes: backgroundMinutes ?? this.backgroundMinutes,
      staleMinutes: staleMinutes ?? this.staleMinutes,
      offlineAlarmMinutes: offlineAlarmMinutes ?? this.offlineAlarmMinutes,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notifyRecovery: notifyRecovery ?? this.notifyRecovery,
      monitorDeliveries: monitorDeliveries ?? this.monitorDeliveries,
      varianceThresholdPct: varianceThresholdPct ?? this.varianceThresholdPct,
      monitorOverfill: monitorOverfill ?? this.monitorOverfill,
      monitorUnauthorised: monitorUnauthorised ?? this.monitorUnauthorised,
      unauthorisedLanes: unauthorisedLanes ?? this.unauthorisedLanes,
      mutedSflProducts: mutedSflProducts ?? this.mutedSflProducts,
      mutedDeliveryProducts:
          mutedDeliveryProducts ?? this.mutedDeliveryProducts,
      mutedConsoles: mutedConsoles ?? this.mutedConsoles,
      languageCode: languageCode ?? this.languageCode,
      themeMode: themeMode ?? this.themeMode,
    );
  }

  /// Cabecera de autenticacion documentada por AdaptIQ.
  Map<String, String> authHeaders() => {
        'Content-Type': 'application/json',
        if (token.trim().isNotEmpty) 'Authorization': 'Token token=${token.trim()}',
      };
}
