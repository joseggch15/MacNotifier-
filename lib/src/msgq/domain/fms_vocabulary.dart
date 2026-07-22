/// Vocabulario del dominio AdaptIQ/AdaptFMS — port de `msgq/config.py`.
///
/// Centraliza los textos EXACTOS que devuelve el FMS (estados de equipo, tipos
/// de transaccion, fuentes de volumen) y los umbrales de las auditorias. Que
/// vivan aqui —y no dispersos en cada servicio— es lo que permite que el
/// dashboard de escritorio y esta app "hablen el mismo idioma": si el tenant
/// renombra un estado, se cambia en un solo sitio.
///
/// Dart puro: sin dependencias de Flutter, usable desde cualquier isolate.
library;

// ===========================================================================
// Estados operativos del equipo (texto exacto del FMS)
// ===========================================================================

const String statusInService = 'In Service';
const String statusOutOfService = 'Out of Service';
const String statusDecommissioned = 'Decommissioned';

/// Mapa id -> estado del enum del log de auditoria (INS/OUTS/DECOMM == 1/2/3,
/// confirmado en vivo contra el tenant de Merian).
const Map<String, String> equipmentStatusById = {
  '1': statusInService,
  '2': statusOutOfService,
  '3': statusDecommissioned,
};

// ===========================================================================
// Tipos de movimiento (familia de transaccion)
// ===========================================================================

/// Familia de la transaccion. La API las expone como TRES conexiones distintas
/// (`dispenses`, `deliveries`, `transfers`) que implementan la misma interface
/// `Movement`; el cliente etiqueta cada nodo con su [MovementKind].
enum MovementKind {
  dispense('DISPENSE'),
  delivery('DELIVERY'),
  transfer('TRANSFER');

  const MovementKind(this.wire);

  /// Valor canonico con el que viaja y se persiste (igual que `KIND_*` de MSGQ).
  final String wire;

  static MovementKind? fromWire(String? value) {
    if (value == null) return null;
    final up = value.trim().toUpperCase();
    for (final k in MovementKind.values) {
      if (k.wire == up) return k;
    }
    return null;
  }
}

// --- Tipos / modos de transaccion (campo `type`) ---------------------------
// Valores exactos de los enums Dispense/Delivery/TransferTransactionType del
// esquema. Ojo: 'Unauthorised' NO va en mayusculas.
const String typeAuto = 'AUTO';
const String typeManual = 'MANUAL';
const String typeKeyBypass = 'KEY_BYPASS';
const String typeSupOverride = 'SUP_OVERRIDE';
const String typeSpillage = 'SPILLAGE';
const String typeUnauthorised = 'Unauthorised';

/// Modos criticos para la trazabilidad (disparan alerta en MSGQ).
const Set<String> anomalousTypes = {
  typeKeyBypass,
  typeSupOverride,
  typeSpillage,
  typeUnauthorised,
};

// --- Fuente del volumen (primario / secundario) ----------------------------
const String volumeSourceDocket = 'DOCKET';
const String volumeSourceMeter = 'METER';

// ===========================================================================
// Log de auditoria de cambios
// ===========================================================================

const String changeRecordEquipment = 'EquipmentItem';
const String changeRecordRfid = 'EquipmentRfid';
const List<String> changeRecordTypes = [
  changeRecordEquipment,
  changeRecordRfid,
];

// Atributos clave dentro del diff de cambios (confirmados en vivo).
const String attrStatus = 'equipment_status_id'; // en EquipmentItem (1/2/3)
const String attrRfid = 'rfid'; // en EquipmentRfid
const String attrCostCentre = 'cost_centre_id';
const String attrGroup = 'equipment_group_id';
const String attrCategory = 'equipment_category_id';
const String attrDepartment = 'department_id';

/// Etiquetas legibles de los atributos del log (vista de Audit Log y resumen de
/// "atributos mas cambiados").
const Map<String, String> attrLabels = {
  'equipment_status_id': 'Estado',
  'cost_centre_id': 'Cost Centre',
  'equipment_group_id': 'Grupo',
  'equipment_category_id': 'Categoria',
  'department_id': 'Departamento',
  'smu_value': 'SMU Value',
  'smu_value_source': 'SMU Source',
  'service_interval': 'Intervalo servicio',
  'service_interval_type': 'Tipo intervalo',
  'dispense_limited': 'Dispense Limited',
  'dispense_limit_period': 'Periodo limite',
  'make': 'Marca',
  'model': 'Modelo',
  'code': 'Codigo',
  'field_id': 'Field ID',
  'description': 'Descripcion',
  'division': 'Division',
  'registration_number': 'Matricula',
  'erp_reference': 'ERP Ref',
  'approver': 'Aprobador',
  'contractor': 'Contratista',
  'field_description': 'Field Desc',
  'rfid': 'RFID',
  'fill_point_location': 'Fill point',
  'is_light_vehicle': 'Vehiculo ligero',
  'is_contractor_vehicle': 'Es contratista',
  'is_tanker': 'Es cisterna',
  'is_pod': 'Es pod',
  'is_sap_exportable': 'SAP exportable',
};

/// Nombre legible de un atributo del log; si no esta mapeado, se humaniza.
String attrLabel(String? attribute) {
  if (attribute == null || attribute.trim().isEmpty) return '';
  final known = attrLabels[attribute];
  if (known != null) return known;
  return attribute
      .split('_')
      .where((w) => w.isNotEmpty)
      .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// Nombre del estado a partir del id crudo del log. `null` = alta inicial (el
/// evento `create` no tiene valor previo).
String statusName(String? value) {
  if (value == null || value.trim().isEmpty) return '(alta)';
  final key = value.trim();
  return equipmentStatusById[key] ?? 'id=$key';
}

// ===========================================================================
// Circuitos de producto (Diesel / Gasolina / Lubricantes)
// ===========================================================================

/// Circuitos en orden de presentacion. El de taller (lubricantes/fluidos) se
/// mantiene SIEMPRE separado del combustible: sus tanques manejan ordenes de
/// magnitud muy distintos (miles de L vs cientos de miles), asi que mezclarlos
/// en una grafica aplasta visualmente al de menor escala.
enum Circuit {
  diesel('Diesel'),
  gasolina('Gasolina'),
  lubricantes('Lubricantes');

  const Circuit(this.label);

  final String label;

  static Circuit? fromLabel(String? value) {
    if (value == null) return null;
    for (final c in Circuit.values) {
      if (c.label == value) return c;
    }
    return null;
  }
}

/// Clasifica un texto de producto en circuito — port de
/// `tank_analytics.classify_circuit`.
///
/// 'Diesel' / 'Gasolina' (combustible, sitio LFO) o 'Lubricantes' (todo lo que
/// NO es combustible: aceites, refrigerante, fluidos). Devuelve `null` solo
/// para productos vacios o sin dato.
Circuit? classifyCircuit(String? product) {
  final v = product?.trim().toUpperCase();
  if (v == null || v.isEmpty) return null;
  if (v.contains('DIESEL')) return Circuit.diesel;
  const gasolineKeywords = ['UNLEAD', 'GASOL', 'PETROL', 'ULP'];
  if (gasolineKeywords.any(v.contains)) return Circuit.gasolina;
  // Cualquier otro producto real es del taller (lubricantes / fluidos).
  return Circuit.lubricantes;
}

// ===========================================================================
// Marcadores y umbrales
// ===========================================================================

/// Etiqueta con la que se agrupan las categorias vacias / sin dato, para que un
/// grupo sin nombre nunca desaparezca silenciosamente de un resumen.
const String noDataLabel = '(sin dato)';

/// Minutos sin comunicacion exitosa tras los cuales una consola se reporta
/// "stale" aunque su flag `online` siga en verdadero.
const int adaptMacStaleMinutes = 30;

/// Tolerancia relativa antes de marcar un exceso de Safe Fill Level: solo se
/// reporta si `volume > sfl * (1 + tolerancia)`. Filtra el ruido de medicion
/// (los medidores tienen ~0.5-1% de error).
const double sflTolerancePct = 0.02;

/// Etiqueta de los despachos sin producto identificable. Se separa de
/// [noDataLabel] a proposito: el burn rate encadena por (equipo, producto), y
/// mezclar "sin producto" con "sin categoria" cruzaria series distintas.
const String noProductLabel = '(sin producto)';

/// Marcador del equipo que no se pudo identificar (el tag ya no esta en el
/// maestro ni en el historial de asignaciones).
const String unidentifiedLabel = '(no identificado)';

// ===========================================================================
// Auditoria de Burn Rate (consumo de combustible, L/h)
// ===========================================================================
// El burn rate de un equipo es el combustible que quema por unidad de SMU
// (horas-motor en la mayoria de la flota; odometro en vehiculos ligeros). Se
// calcula por el metodo 'tanque-a-tanque': entre dos despachos CONSECUTIVOS del
// mismo equipo, los litros del posterior reponen lo quemado desde el anterior, y
// el burn rate del intervalo es esos litros divididos por el avance del SMU. Es
// el mismo metodo que AdaptIQ pre-calcula (Litres Consumed / SMU Increase), pero
// reconstruido desde el endpoint para poder auditarlo.
//
// Las anomalias se detectan con estadistica ROBUSTA (mediana + MAD), inmune a
// los outliers que justamente se quieren marcar.

/// Avance minimo de SMU para que un intervalo sea valido: por debajo, el
/// cociente litros/deltaSMU se dispara por division entre casi-cero.
const double burnRateMinSmuDelta = 0.1;

/// Techo de plausibilidad (L/h): por encima no es fisicamente posible para una
/// sola maquina; es un artefacto del dato (p. ej. el SMU de un tanque que avanza
/// '1' y se le imputan miles de litros).
const double burnRateMaxPlausible = 2000.0;

/// Intervalos minimos para considerar confiable el burn rate de UN equipo: con
/// menos muestras la mediana es inestable.
const int burnRateMinSamples = 3;

/// Equipos minimos (con burn rate confiable) para fijar la linea base de UNA
/// categoria: con menos no hay con que comparar.
const int burnRateMinCategoryEquipment = 3;

/// |z robusto| a partir del cual un EQUIPO se marca como anomalo.
const double burnRateZThreshold = 3.5;

/// Ademas del z se exige una desviacion relativa minima, para no marcar
/// diferencias estadisticamente significativas pero operativamente triviales en
/// categorias muy homogeneas.
const double burnRateMinDeviationPct = 15.0;

/// |z robusto| (respecto al propio historial del equipo) para marcar UN
/// intervalo puntual como atipico.
const double burnRateIntervalZ = 4.0;

/// Factor que convierte MAD en sigma robusto (consistente bajo normalidad).
const double madToSigma = 1.4826;

// ===========================================================================
// Auditoria de Salud de Hardware y Sensores
// ===========================================================================
// El SMU SIEMPRE debe avanzar. Una caida respecto a una lectura anterior
// significa sensor roto, reiniciado o manipulado. Un valor que no cambia en
// varias cargas de un equipo operativo significa que el sensor no envia pulsos.

/// Caida minima de SMU para marcar una regresion (filtra ruido de medicion).
const double smuRegressionMinDrop = 1.0;

/// Estancamiento: mismo SMU crudo en >= N despachos consecutivos abarcando
/// >= D dias, en un equipo In Service.
const int smuStagnationMinRepeats = 5;
const int smuStagnationMinDays = 5;

/// Re-tagueo sospechoso: mas de N cambios de RFID del MISMO equipo en una
/// ventana movil de D dias — el operador podria estar destruyendo los tags para
/// forzar despachos manuales o en bypass.
const int retagMaxChanges = 3;
const int retagWindowDays = 30;

/// Degradacion del medidor: por manguera, si el caudal reciente cae >= PCT%
/// respecto a su linea base historica, los filtros estan obstruidos o la bomba
/// falla. Requiere muestras suficientes a cada lado.
const int meterRecentDays = 7;
const double meterDropPct = 40.0;
const int meterMinSamples = 5;

/// Categorias de alerta (valores canonicos, iguales a los de MSGQ).
const String alertBurnRateAnomaly = 'Burn rate anomalo';
const String alertSmuRegression = 'SMU en regresion (sensor)';
const String alertSmuStagnation = 'SMU estancado (sensor sin pulsos)';
const String alertRetag = 'Re-tagueo RFID sospechoso';
const String alertMeterDegraded = 'Caudal de medidor degradado';

// ===========================================================================
// Auditoria de Tag Hopping ("el tag en el bolsillo")
// ===========================================================================
// El tag RFID identifica al equipo: cada despacho queda imputado al equipo cuyo
// tag se leyo. Si el MISMO tag autoriza dos despachos en puntos fisicamente
// distintos en un lapso imposible, alguien removio el tag del equipo para robar
// combustible (o el tag esta clonado).

/// Velocidad implicita (km/h) sobre la cual un equipo PESADO no pudo recorrer
/// la distancia entre dos puntos: no circula por vias a esa velocidad, suele
/// transportarse en cama baja.
const double tagHopMaxSpeedKmh = 40.0;

/// Idem para VEHICULOS LIGEROS, que si se desplazan rapido por el sitio: su
/// umbral es mas alto para no marcar viajes legitimos.
const double tagHopLightMaxSpeedKmh = 100.0;

/// Distancia (km) por debajo de la cual se ignora la diferencia de GPS: filtra
/// el jitter del receptor (dos lecturas del mismo punto difieren decenas de
/// metros).
const double tagHopMinDistanceKm = 0.5;

/// Holgura (minutos) de solapamiento que se exige antes de marcar por
/// imposibilidad temporal, para absorber el desfase de reloj entre consolas.
const double tagHopClockSlackMinutes = 1.0;

const String tagHopReasonOverlap = 'Solapamiento temporal';
const String tagHopReasonSpeed = 'Velocidad imposible';
const String alertTagHopping =
    'Tag en dos lugares a la vez (posible robo de combustible)';

// ===========================================================================
// Reporte de instalacion de tags RFID ('Inventory Tag Installed')
// ===========================================================================
// Vocabulario exacto del reporte semanal. Se deriva del evento del log:
//   create  (null -> tag)  -> NEW INSTALLATION
//   update  (tag  -> tag') -> REPLACEMENT
//   destroy (tag  -> null) -> REMOVAL
// No se traducen: son la jerga del reporte, igual que los estados del FMS.

/// Tipo de operacion sobre un tag.
enum RfidOperation {
  newInstallation('NEW INSTALLATION'),
  replacement('REPLACEMENT'),
  removal('REMOVAL');

  const RfidOperation(this.label);

  final String label;

  /// Clasifica un evento del log por la presencia de sus valores antes/despues.
  static RfidOperation classify({String? before, String? after}) {
    final hasBefore = before != null && before.trim().isNotEmpty;
    final hasAfter = after != null && after.trim().isNotEmpty;
    if (!hasBefore && hasAfter) return RfidOperation.newInstallation;
    if (hasBefore && hasAfter) return RfidOperation.replacement;
    return RfidOperation.removal;
  }
}

/// Desfase horario del SITIO respecto a UTC, en horas.
///
/// Merian (Surinam, America/Paramaribo) es UTC-03 todo el año, sin horario de
/// verano. El log de auditoria guarda `changedAt` en UTC; el reporte lo
/// convierte a hora LOCAL para que la fecha y el filtro de rango reflejen el
/// DIA OPERATIVO local. Sin esto una instalacion nocturna (21:00 local = 00:00
/// UTC del dia siguiente) cae en el dia siguiente y se PIERDE de un reporte
/// "hasta el dia X".
const int siteUtcOffsetHours = -3;

/// Textos que, aun siendo no vacios, NO identifican a un equipo: un despacho
/// sin autorizar no tiene equipo aunque el campo traiga la palabra.
const Set<String> blankEquipmentTokens = {
  '<NA>',
  'NAN',
  'NONE',
  'UNAUTHORISED',
};

/// Identificador de equipo utilizable para encadenar su historial.
///
/// Un `equipmentId` que en realidad dice "Unauthorised" romperia el burn rate:
/// encadenaria despachos de maquinas distintas como si fueran una sola.
String? realEquipmentId(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return null;
  return blankEquipmentTokens.contains(text.toUpperCase()) ? null : text;
}

/// Campos del maestro cuya presencia mide la completitud del inventario
/// (`equipment_analytics._COMPLETENESS_FIELDS`).
const List<String> completenessFields = [
  'registration_number',
  'category',
  'group',
  'make',
  'model',
  'department',
  'cost_centre',
  'rfid',
];
