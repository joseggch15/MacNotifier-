# adaptMacNotifier — Monitor móvil de AdaptIQ (consolas + entregas + SFL)

Cliente móvil **standalone (pull-based)** en Flutter que monitorea el FMS
AdaptIQ (sitio Newmont Merian) y emite **notificaciones locales** ante tres
familias de anomalías:

* **Consolas AdaptMAC** — pierde conexión, entra en modo bypass o deja de
  comunicar (companion de la pestaña *"AdaptMAC consoles"* de MSGQ).
* **Entregas (deliveries)** — quedan **sin confirmar** o con **varianza alta**
  entre el volumen medido y la guía del camión (companion de la auditoría
  *Volume deviation* de MSGQ).
* **Sobrellenados SFL** — despachos que exceden el Safe Fill Level del equipo
  (la alarma *"Equipment Overfill"* de AdaptIQ, reconstruida localmente porque
  la API customer-facing no expone las alarmas).

Además genera **reportes diarios/semanales/mensuales/anuales en CSV o PDF**
(estilo exports de AdaptIQ) compartibles por la hoja del sistema, y permite
**silenciar las notificaciones por producto** (p. ej. dejar solo el diesel).

No hay servidor intermedio: la app habla directamente con la API GraphQL.

## Comportamiento

| Contexto | Cadencia | Mecanismo |
|---|---|---|
| App abierta | cada **20 s** (configurable 10–60 s) | `Timer` + Riverpod `AsyncNotifier` |
| App cerrada (Android) | cada **15–60 min** | `workmanager` → WorkManager nativo (mín. 15 min, persiste reinicios) |
| App cerrada (iOS) | "no antes de" 15 min | `BGAppRefreshTask` — iOS decide el momento real según el uso de la app |

### Reglas de alerta — consolas (port de `msgq/core/alerts.py::detect_adaptmac_alerts`)

* 🔴 **Offline** — el flag `online` de la API pasa a falso.
* 🚨 **Key bypass** (crítico) — la consola despacha sin autorización.
* 🟠 **Stale** — online pero sin comunicación exitosa hace > 30 min
  (solo evaluable si el tenant expone `lastSuccessfulComms`).

### Reglas de alerta — entregas (port de `msgq/core/volume_deviation.py`)

* 🟡 **Sin confirmar** — `status` = unconfirmed (p. ej. una entrega partida en
  dos transacciones: la segunda queda Unconfirmed y nadie se entera sin abrir
  AdaptIQ). Al confirmarse, la app avisa la resolución.
* 🟠/🔴 **Varianza alta** — |medido − guía| / guía ≥ umbral (1 % por defecto;
  ≥ 5 % escala a crítica). Dos ajustes deliberados sobre MSGQ: el % se calcula
  sobre la **guía** (mismo denominador que la columna Variance de AdaptIQ; con
  el medido como denominador una entrega partida degenera a >200 000 %) y el
  mínimo de 100 L lo satisface **cualquiera** de los dos volúmenes (19,2 L
  medidos vs 40 000 de guía debe alertar).

Las entregas se sincronizan **incrementalmente** (`filter: {updatedFrom}` con
watermark persistido, como el poller de MSGQ): cada ciclo solo trae lo nuevo o
editado. Primera sincronización: ventana de 3 días hacia atrás; la pestaña
"Entregas" muestra la ventana local de 7 días con las problemáticas primero.

### Reglas de alerta — sobrellenados SFL (port de `msgq/core/sfl_audit.py`)

* 🛢️ **Overfill** — `volume > sfl × 1.02` (tolerancia del 2 % filtra ruido de
  medición), cruzando por `(equipmentId, PRODUCTO)` contra el mapa de límites
  de `EquipmentItem.consumptionTanks`. Crítico si el exceso supera el 10 % del
  SFL. Mismo texto que AdaptIQ: *"HTK0826 sobrellenado +93.2 L"*.
* El mapa de límites SFL se refresca del maestro de equipos **una vez al día**
  (la conexión de equipos se descubre por introspección del tipo `Site`, igual
  que MSGQ); los despachos van incrementales con su propio watermark. Un
  sobrellenado es un evento puntual: se notifica una sola vez por despacho.

### Silenciado por producto

En Configuración se pueden **silenciar productos** por dominio (chips que se
pueblan solos con los productos vistos en los datos): un producto silenciado
no notifica anomalías de entrega ni sobrellenados SFL, pero **sigue visible**
en las pestañas (con marca de silenciado en SFL). El estado de deduplicación
se mantiene completo, así que silenciar/des-silenciar no re-dispara alertas
viejas.

### Reportes (CSV / PDF)

Desde el icono 📄 de la barra: periodo (hoy / últimos 7 días / mes actual /
año actual) × contenido (entregas, despachos, sobrellenados SFL) × formato.
El reporte consulta la API en vivo (no la ventana local), filtra por
`recordCollectedAt` dentro del periodo y entrega los archivos a la hoja de
compartir (correo, WhatsApp, Drive…). CSV: un archivo por dataset; PDF: un
documento con resumen + tablas (cap de 600 filas por tabla — el detalle
completo es dominio del CSV). El anual con despachos puede tardar varios
minutos (paginado de a 100 con throttle).

### Deduplicación

Solo las **transiciones** notifican: el estado de condiciones por consola se
persiste en `shared_preferences` y cada ciclo (de primer plano o de background,
comparten el mismo snapshot) se compara contra él. Una consola que sigue caída
no re-notifica; al reconectarse emite una notificación de recuperación que
**reemplaza** a la alerta en la bandeja (id estable por consola+condición).
Más de 4 alzas en un ciclo se agrupan en una sola notificación resumen (una
caída de red del sitio no genera 22 banners).

## Stack

* **Flutter 3.29 / Dart 3.7** — `flutter_riverpod` 2.x (estado),
  `http` (GraphQL por POST puro: funciona igual en el isolate de background),
  `workmanager` 0.7.x (tareas periódicas; 0.8+ exige Flutter ≥ 3.32),
  `flutter_local_notifications` 18.x, `shared_preferences`, `intl`.

## Estructura

```
lib/
  main.dart                       # bootstrap: prefs + notifs + workmanager + ProviderScope
  src/
    config/app_settings.dart      # defaults del tenant (espejo de msgq/config.py)
    api/queries.dart              # documentos GraphQL (port de msgq/api/queries.py)
    api/adaptiq_client.dart       # cliente HTTP: auth, paginación, retries, throttle
    models/adapt_mac.dart         # modelo consola (port de flatten_adaptmac)
    models/delivery.dart          # modelo entrega (volumen medido vs guía)
    core/health_check.dart        # condiciones de consola + diff (Dart puro, testeable)
    core/delivery_check.dart      # auditoría de entregas + diff incremental
    core/util.dart                # naturalCompare, relativeEs, stableId
    storage/app_store.dart        # shared_preferences: cfg.* / cache.* / state.*
    notifications/notification_service.dart
    background/health_runner.dart # runHealthCheck() compartido fg/bg
    background/background_scheduler.dart # callbackDispatcher + registro de tareas
    state/providers.dart          # Riverpod: settings + polling 20 s
    ui/home_screen.dart           # pestañas Consolas / Entregas: KPIs, filtro, listas
    ui/settings_screen.dart       # token/endpoint/sitio, cadencias, umbral varianza
```

## Detalles de la API (heredados de MSGQ)

* Endpoint: `https://merian.veridapt.io/graphql` · Auth:
  `Authorization: Token token=<token>` · Todo es *site-scoped* (`site(id:)`),
  el site id se autodescubre vía `sites` buscando "Merian".
* `adaptMacs` es una conexión paginada por cursor (100/página). La query base
  pide `code description erpReference keyBypass online`; los campos de
  comunicación (`lastSuccessfulComms`, etc.) **no existen en todos los
  tenants**, así que se descubren por **introspección** y solo se piden los
  presentes (pedir un campo inexistente rompe toda la query). El site id y los
  campos descubiertos se cachean en prefs para no gastar peticiones.

## Puesta en marcha

```bash
flutter pub get
flutter run            # dispositivo Android conectado
flutter test           # 32 tests de la lógica de salud/entregas/dedup/parsing
flutter build apk      # release (configurar firma propia antes de distribuir)
```

1. Abrir **Configuración** (engranaje) → pegar el **token** de la API
   (pedir a Veridapt un token de **solo lectura** para este monitor).
2. **Probar conexión** lista los sitios visibles y marca cuál coincide.
3. **Guardar**: arranca el polling y registra la tarea de background.

> El token se guarda en `shared_preferences` (sin cifrar, según el stack
> definido). Si se quiere endurecer, migrar a `flutter_secure_storage`.

## Notas por plataforma

**Android**
* Permisos: `INTERNET`, `POST_NOTIFICATIONS` (se pide en runtime, Android 13+).
* `coreLibraryDesugaring` habilitado (requisito de flutter_local_notifications).
* NDK 27 fijado en `android/app/build.gradle.kts` (lo piden los plugins).
* En equipos con ahorro de batería agresivo (Xiaomi/Huawei/Samsung), excluir la
  app de la optimización de batería para que WorkManager dispare puntual.

**iOS** (compilar desde macOS: `pod install` usa el `ios/Podfile` con iOS 13)
* `BGTaskSchedulerPermittedIdentifiers` = `io.veridapt.merian.adaptmac.healthCheck`
  (Info.plist), registrado también en `AppDelegate.swift` con frecuencia mínima
  de 15 min. iOS modula la cadencia real según el patrón de uso; puede tardar
  días en "aprender". El usuario debe tener **Background App Refresh** activo.
* Probar en Xcode: pausar el debugger y ejecutar
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"io.veridapt.merian.adaptmac.healthCheck"]`.

## Relación con MSGQ

| MSGQ (escritorio) | adaptMacNotifier (móvil) |
|---|---|
| `msgq/api/queries.py` → `ADAPTMACS_QUERY` / `DELIVERIES_QUERY` | `src/api/queries.dart` |
| `msgq/api/client.py` → `AdaptIQClient` | `src/api/adaptiq_client.dart` |
| `msgq/core/transform.py` → `flatten_adaptmac` / `flatten_movement` | `src/models/` |
| `msgq/core/alerts.py` → `detect_adaptmac_alerts` | `src/core/health_check.dart` |
| `msgq/core/volume_deviation.py` → `deviations` | `src/core/delivery_check.dart` |
| `msgq/config.py` → `Settings` / umbrales `DELIVERY_*` | `src/config/app_settings.dart` |
