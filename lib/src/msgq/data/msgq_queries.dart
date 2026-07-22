/// Documentos GraphQL de los modulos MSGQ — port de `msgq/api/queries.py`.
///
/// Complementan a `src/api/queries.dart` (que cubre lo que necesita el
/// notificador: consolas, despachos y entregas) con las conexiones que solo usa
/// la analitica: tanques, reconciliaciones, transferencias, maestro de equipos
/// y log de auditoria.
///
/// Claves del modelo real que estas queries respetan:
///
///   * Todo es *site-scoped*: se entra por `site(id: ID!)`. La UNICA excepcion
///     es `changes`, que es una query top-level.
///   * Los movimientos son TRES conexiones distintas (`dispenses`,
///     `deliveries`, `transfers`), cada una con los campos comunes de la
///     interface `Movement` mas los suyos.
///   * Regla de oro: pedir un campo que el tenant NO expone rompe TODA la
///     query. Por eso los campos opcionales (medidor, caudal, SMU crudo) se
///     descubren por introspeccion y se inyectan con [buildDispensesQuery].
library;

// --- Campos comunes de la interface Movement -------------------------------
const String _movementCommon = '''
        id
        volume
        uom
        recordCollectedAt
        recordCreatedAt
        recordUpdatedAt
        transactionTemperature
        peakFlowRate
        cost
        rebateAmount
        gpsCoordinates
        operator
        product { code description }
        costCentre { code description }
        equipmentGroup { code description }
        equipmentCategory { code description }
        site { code description }
        adaptMac { code }''';

const String _dispenseExtra = '''
        status
        type
        smuValue
        smuType
        source { code name }
        target { equipmentId description status }
        fieldUser { name }''';

const String _deliveryExtra = '''
        status
        type
        volumeSource
        secondaryVolume
        secondaryVolumeSource
        docketNumber
        driver
        company
        target { code name }''';

const String _transferExtra = '''
        status
        type
        source { code name }
        target { code name }
        serviceTruck { equipmentId description }''';

String _connectionQuery(String connection, String nodeExtra) {
  final name = connection[0].toUpperCase() + connection.substring(1);
  return '''
query $name(\$siteId: ID!, \$filter: MovementQuery, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    $connection(filter: \$filter, first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
$_movementCommon
$nodeExtra
      } }
    }
  }
}''';
}

/// Campos OPCIONALES del despacho: no todos los tenants los exponen, asi que se
/// descubren por introspeccion y solo se piden los presentes. Clave = nombre
/// del campo en el tipo; valor = su seleccion GraphQL.
///
/// `meter` merece un aviso: la introspeccion solo valida el campo TOP-LEVEL, no
/// sus subcampos. El tipo `Meter` de este tenant solo expone code/description;
/// pedirle `erpReference` rompia TODA la query de despachos.
const Map<String, String> optionalDispenseFields = {
  'meter': 'meter { code description }',
  'averageFlowRate': 'averageFlowRate',
  'duration': 'duration',
  'rawSmuValue': 'rawSmuValue',
  'calculatedSmuValue': 'calculatedSmuValue',
  'smuSource': 'smuSource',
  'smuValueSource': 'smuValueSource',
};

/// Tipos candidatos del nodo de despacho para introspeccionar sus campos.
const List<String> dispenseTypeCandidates = ['Dispense', 'Movement'];

/// Query de despachos con los campos opcionales que el tenant SI expone.
String buildDispensesQuery([Set<String> optional = const {}]) {
  final picks = optionalDispenseFields.entries
      .where((e) => optional.contains(e.key))
      .map((e) => e.value)
      .toList();
  final extra = picks.isEmpty
      ? _dispenseExtra
      : '$_dispenseExtra\n        ${picks.join('\n        ')}';
  return _connectionQuery('dispenses', extra);
}

final String dispensesQuery = buildDispensesQuery();
final String deliveriesQuery = _connectionQuery('deliveries', _deliveryExtra);
final String transfersQuery = _connectionQuery('transfers', _transferExtra);

/// Tanques del sitio (registro maestro, conexion paginada).
const String tanksQuery = '''
query Tanks(\$siteId: ID!, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    tanks(first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        id code description name virtual enabled capacity volumeUnit
        product { code description }
        parentTank { code }
        tankType { description }
      } }
    }
  }
}''';

/// Reconciliacion diaria por tanque ('Detailed Reconciliation' nativo).
///
/// Una fila por tanque/dia. `volume` es el ERROR de reconciliacion ya calculado
/// por la API. Filtrable incremental por `filter:{updatedFrom}`, igual que los
/// movimientos. `status` ∈ {all_ok, unconfirmed, pending}.
const String reconciliationsQuery = '''
query Reconciliations(\$siteId: ID!, \$filter: MovementQuery, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    reconciliations(filter: \$filter, first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        id periodStart periodEnd
        openingStock closingStock inflowVolume outflowVolume volume
        status recordUpdatedAt
        target { code description }
        product { code description }
      } }
    }
  }
}''';

/// Log de auditoria de cambios. Es la UNICA query top-level: no cuelga del
/// site, asi que se pagina con [MsgqClient.paginateTopLevel].
const String changesQuery = '''
query Changes(\$filter: ChangeEventQuery, \$first: Int, \$after: String) {
  changes(filter: \$filter, first: \$first, after: \$after) {
    pageInfo { hasNextPage endCursor }
    edges { node {
      changedAt
      recordType
      recordId
      event
      whodunnit
      changes { attribute before after }
    } }
  }
}''';

/// Maestro de equipos para el nombre de conexion descubierto en el Site.
///
/// El tipo `Equipment Item` no se puede listar por si mismo (solo aparece como
/// `target` de un despacho); si el tenant expone una conexion, su nombre se
/// descubre por introspeccion y la query se arma aqui.
String buildEquipmentQuery(String fieldName) => '''
query EquipmentItems(\$siteId: ID!, \$first: Int, \$after: String) {
  site(id: \$siteId) {
    $fieldName(first: \$first, after: \$after) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        id
        equipmentId
        fieldId
        description
        fieldDescription
        status
        make
        model
        division
        contractor
        isLightVehicle
        isContractorVehicle
        isRebateEligible
        dispenseLimited
        dispenseLimitPeriod
        serviceInterval
        serviceIntervalType
        smuValueSource
        rfidTags
        projectCode
        sap
        orderNumber
        orderItem
        erpReference
        gpsCoordinates
        volumeUnit
        expiryDate
        lastChangedAt
        consumptionTanks { id sfl product { code description } }
        equipmentGroup { code description }
        equipmentCategory { code description }
        costCentre { code description }
        department { code description }
      } }
    }
  }
}''';

/// Introspeccion de los campos de un tipo (p. ej. 'Dispense').
String typeFieldsIntrospection(String typeName) =>
    '{ __type(name: "$typeName") { fields { name } } }';
