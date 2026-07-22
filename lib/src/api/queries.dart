/// Documentos GraphQL para la API de AdaptIQ (AdaptFMS).
///
/// Port de `msgq/api/queries.py` reducido a lo que necesita el monitor de
/// consolas. Claves del modelo real:
///
///   * Todo es *site-scoped*: se entra por `site(id: ID!) { ... }`.
///   * `adaptMacs` es una conexion paginada por cursor
///     (`pageInfo { hasNextPage endCursor }`, limite 100 por pagina).
///   * Los campos de comunicacion (`lastSuccessfulComms`, `lastFailedComms`,
///     `updatedAt`) y el `site` anidado NO estan en todos los tenants: pedir un
///     campo inexistente rompe TODA la query ("Field doesn't exist"), asi que
///     se descubren por introspeccion y solo se piden los presentes — la misma
///     leccion que dejo `erpReference` sobre `Meter` en MSGQ.
library;

/// Descubrimiento de sitios (tambien valida el token).
const sitesQuery = '{ sites { id code description } }';

/// Candidatos del nombre del tipo GraphQL del nodo de consola, para
/// introspeccionar sus campos.
const adaptMacTypeCandidates = ['AdaptMac', 'AdaptMAC', 'Adaptmac'];

/// Query de introspeccion de los campos de un tipo (p. ej. 'AdaptMac').
String typeFieldsIntrospection(String typeName) =>
    '{ __type(name: "$typeName") { fields { name } } }';

/// Campos OPCIONALES del nodo AdaptMac. Clave = nombre del campo segun la
/// introspeccion; valor = su seleccion GraphQL.
const optionalAdaptMacFields = <String, String>{
  'site': 'site { code description }',
  'lastSuccessfulComms': 'lastSuccessfulComms',
  'lastFailedComms': 'lastFailedComms',
  'updatedAt': 'updatedAt',
};

/// Entregas (deliveries): conexion paginada y filtrable incrementalmente con
/// `filter: { updatedFrom: ISO8601 }` (tipo MovementQuery). Todos los campos
/// pedidos estan en la query de produccion de MSGQ contra Merian — no
/// necesitan introspeccion. `volume` = MEDIDO; `secondaryVolume` = GUIA.
const deliveriesQuery = '''
query Deliveries(\$siteId: ID!, \$filter: MovementQuery, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    deliveries(filter: \$filter, first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        id
        status
        type
        volume
        uom
        secondaryVolume
        volumeSource
        secondaryVolumeSource
        docketNumber
        driver
        company
        recordCollectedAt
        recordUpdatedAt
        product { code description }
        target { code name }
        adaptMac { code }
      } }
    }
  }
}''';

/// Seleccion BASE del nodo Dispense: campos minimos para la auditoria SFL, los
/// no-autorizados y los reportes — todos en la query de produccion de MSGQ
/// contra Merian.
const _dispenseSelection = '''
        id
        status
        type
        volume
        recordCollectedAt
        recordUpdatedAt
        product { code description }
        target { equipmentId description }
        source { code name }
        fieldUser { name }
        adaptMac { code description }''';

/// Campos de la interface Movement que la AUDITORIA de caudal/temperatura pide
/// en la query de dispenses (subconjunto de [flowTempProbeFields]: solo los que
/// el check realmente consume). Se incluyen unicamente cuando la introspeccion
/// confirma que el tenant los expone (pedir uno inexistente rompe la query).
const flowTempQueryFields = <String>{
  'duration',
  'peakFlowRate',
  'transactionTemperature',
};

/// Arma la query de dispenses con los campos de Movement [extra] presentes en
/// el tenant (descubiertos por introspeccion). Sin extras = query base, la
/// misma que MSGQ usa en produccion.
String buildDispensesQuery(Set<String> extra) {
  final tail = extra.isEmpty ? '' : '\n        ${extra.join('\n        ')}';
  return '''
query Dispenses(\$siteId: ID!, \$filter: MovementQuery, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    dispenses(filter: \$filter, first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
$_dispenseSelection$tail
      } }
    }
  }
}''';
}

/// Query base de dispenses (sin campos de caudal/temperatura), para el backfill
/// de "Sin ID" y demas usos que no necesitan los campos opcionales.
final dispensesQuery = buildDispensesQuery(const {});

/// Introspeccion del tipo Site para hallar la conexion de EQUIPOS (su nombre
/// varia por tenant; igual que `SITE_FIELDS_INTROSPECTION` en MSGQ).
const siteFieldsIntrospectionQuery =
    '{ __type(name: "Site") { fields { name } } }';

/// Candidatos del nombre del tipo GraphQL de un MOVIMIENTO, para introspeccionar
/// sus campos. Dispense/Delivery implementan la interface `Movement` (doc
/// AdaptIQ p. 21-24): `__type` sobre el tipo concreto ya devuelve los campos
/// heredados, asi que probamos los concretos primero y la interface al final.
const movementTypeCandidates = ['Dispense', 'Delivery', 'Movement', 'Transaction'];

/// Campos de la interface Movement para las alertas de CAUDAL y TEMPERATURA.
/// Nombres en camelCase (formato de query real; el doc los lista en snake_case
/// pero la API responde camelCase — ver `updated_from`→`updatedFrom`, p. 11).
/// `averageFlowRate`/`flow*` no estan en el doc de jul-2023 pero MSGQ ya los
/// mapea (`transform.flatten_movement`): son opcionales segun tenant.
const flowTempProbeFields = <String>{
  'duration', // Int, segundos (not null en la interface)
  'peakFlowRate', // String (can be null)
  'averageFlowRate', // opcional (no documentado en jul-2023)
  'transactionTemperature', // Float (can be null), arg `unit`: celsius/fahrenheit
  'transactionEndedAt',
  'flowStartedAt',
  'flowEndedAt',
};

/// Nombres candidatos de la conexion de equipos (mismos que MSGQ).
const equipmentFieldCandidates = [
  'equipmentItems',
  'equipment_items',
  'equipments',
  'equipment',
];

/// Query de limites SFL: por equipo, sus `consumptionTanks` (validado en vivo
/// por MSGQ: `ConsumptionTank{sfl, product{code description}}`). Solo se piden
/// los campos del cruce SFL para no arrastrar todo el maestro de equipos.
String buildSflLimitsQuery(String fieldName) => '''
query SflLimits(\$siteId: ID!, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    $fieldName(first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        equipmentId
        consumptionTanks { sfl product { code description } }
      } }
    }
  }
}''';

/// Arma la query de consolas incluyendo solo los campos opcionales presentes
/// en `optional` (descubiertos por introspeccion). Sin opcionales queda la
/// query base, identica a la que MSGQ usa en produccion contra Merian.
String buildAdaptMacsQuery(Set<String> optional) {
  final extra = [
    for (final entry in optionalAdaptMacFields.entries)
      if (optional.contains(entry.key)) entry.value,
  ].join('\n        ');
  return '''
query AdaptMacs(\$siteId: ID!, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    adaptMacs(first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        code
        description
        erpReference
        keyBypass
        online
        $extra
      } }
    }
  }
}''';
}
