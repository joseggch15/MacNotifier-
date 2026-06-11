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
