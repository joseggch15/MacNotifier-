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
