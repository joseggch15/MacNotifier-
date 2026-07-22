/// Export de los modulos MSGQ a PDF y CSV.
///
/// Cada modulo describe SU reporte ([MsgqReport]) a partir de la auditoria que
/// ya tiene calculada en memoria; esta capa no recalcula nada ni vuelve a la
/// API. Eso importa: lo que se exporta es EXACTAMENTE lo que el auditor esta
/// viendo, con el mismo rango, el mismo circuito y el mismo producto.
///
/// Los archivos se escriben en la carpeta temporal y se entregan a la hoja de
/// compartir del sistema, igual que los reportes del notificador.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../analytics/activity_audit.dart';
import '../analytics/burn_rate.dart';
import '../analytics/equipment_analytics.dart';
import '../domain/equipment.dart';
import '../analytics/hardware_health.dart';
import '../analytics/product_audit.dart';
import '../analytics/rfid_inventory.dart';
import '../analytics/tag_hopping.dart';
import '../analytics/tank_analytics.dart';
import '../domain/fms_vocabulary.dart';
import 'msgq_report.dart';

/// Formato de salida.
enum MsgqExportFormat {
  pdf('PDF', 'pdf', 'application/pdf'),
  csv('CSV', 'csv', 'text/csv');

  const MsgqExportFormat(this.label, this.extension, this.mimeType);

  final String label;
  final String extension;
  final String mimeType;
}

class MsgqExportService {
  const MsgqExportService();

  /// Escribe el reporte y abre la hoja de compartir.
  Future<void> share(
    MsgqReport report, {
    MsgqExportFormat format = MsgqExportFormat.pdf,
    DateTime? now,
  }) async {
    final file = await write(report, format: format, now: now);
    // Misma API que usa el reporte del notificador (share_plus 10.x).
    await Share.shareXFiles([file], subject: report.title);
  }

  /// Escribe el reporte en la carpeta temporal y devuelve el archivo.
  Future<XFile> write(
    MsgqReport report, {
    MsgqExportFormat format = MsgqExportFormat.pdf,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${report.fileSlug(at)}.${format.extension}';
    final file = File(path);
    if (format == MsgqExportFormat.pdf) {
      await file.writeAsBytes(await buildMsgqPdf(report, generatedAt: at));
    } else {
      await file.writeAsBytes(csvBytes(buildMsgqCsv(report)));
    }
    return XFile(path, mimeType: format.mimeType, name: file.uri.pathSegments.last);
  }
}

// ===========================================================================
// Constructores de reporte por modulo
// ===========================================================================

String _l(double v) => '${v.toStringAsFixed(1)} L';
String _n(num v) => v.toString();
String _pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} %';
String _day(DateTime? d) => d == null
    ? '—'
    : '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Reporte de Tanques y consumo.
MsgqReport buildTankReport(
  TankAnalytics analytics, {
  required String scope,
}) {
  final byProduct = analytics.consumptionByProduct();
  final byTank = analytics.consumptionByTank();
  final burn = analytics.burnRate();
  final flows = analytics.flowByTank();
  final detail = analytics.reconciliationDetail();
  final kpis = analytics.reconciliationKpis();
  final totalDispensed = byProduct.fold<double>(0, (a, g) => a + g.volumeL);

  return MsgqReport(
    title: 'Tanques y consumo',
    subtitle: scope,
    kpis: [
      MsgqReportKpi('Despachado', _l(totalDispensed)),
      MsgqReportKpi('Productos', _n(byProduct.length)),
      MsgqReportKpi('Tanques', _n(byTank.length)),
      if (kpis != null) ...[
        MsgqReportKpi('Error de reconciliacion', _l(kpis.totalErrorL),
            hint: '${kpis.errorPctOfOutflow} % del outflow'),
        MsgqReportKpi('Peor tanque', kpis.worstTank,
            hint: _l(kpis.worstErrorL)),
      ],
    ],
    sections: [
      MsgqReportSection(
        title: 'Consumo en el tiempo',
        note: 'Volumen despachado por dia',
        chart: MsgqReportChart(
          kind: MsgqChartKind.bars,
          series: [
            MsgqReportSeries(
              label: 'Despachado',
              points: burn
                  .map((p) => MsgqReportPoint(_day(p.period), p.volumeL))
                  .toList(),
            ),
          ],
        ),
      ),
      MsgqReportSection(
        title: 'Consumo por producto',
        table: MsgqReportTable(
          headers: const ['Producto', 'Despachos', 'Volumen (L)'],
          rows: byProduct
              .map((g) => [g.key, _n(g.count), g.volumeL.toStringAsFixed(1)])
              .toList(),
        ),
      ),
      MsgqReportSection(
        title: 'Flujo por tanque',
        note: 'Las transferencias cuentan como salida del tanque origen: el '
            'destino no viaja en el registro',
        table: MsgqReportTable(
          headers: const [
            'Tanque',
            'Entregas (L)',
            'Despachos (L)',
            'Transf. salida (L)',
            'Neto (L)',
          ],
          rows: flows
              .map((f) => [
                    f.tank,
                    f.deliveriesL.toStringAsFixed(1),
                    f.dispensesL.toStringAsFixed(1),
                    f.transfersOutL.toStringAsFixed(1),
                    f.netL.toStringAsFixed(1),
                  ])
              .toList(),
        ),
      ),
      MsgqReportSection(
        title: 'Reconciliacion por tanque',
        note: 'Stock medido por el sensor menos movimiento registrado',
        table: MsgqReportTable(
          headers: const [
            'Tanque',
            'Producto',
            'Stock ini.',
            'Stock fin.',
            'Inflow',
            'Outflow',
            'Error (L)',
            'Error %',
          ],
          rows: detail
              .map((r) => [
                    r.tank,
                    r.product ?? noDataLabel,
                    r.openingStockL.toStringAsFixed(1),
                    r.closingStockL.toStringAsFixed(1),
                    r.inflowL.toStringAsFixed(1),
                    r.outflowL.toStringAsFixed(1),
                    r.errorL.toStringAsFixed(1),
                    _pct(r.errorPctOfOutflow),
                  ])
              .toList(),
        ),
      ),
    ],
  );
}

/// Reporte de Burn Rate.
MsgqReport buildBurnRateReport(
  BurnRateAudit audit, {
  required String scope,
  BurnRateCoverage? coverage,
}) {
  final focus = audit.equipmentAnomalies.firstOrNull;
  final category = focus == null
      ? null
      : audit.categories.where((c) => c.category == focus.category).firstOrNull;
  final series = focus == null
      ? const <BurnRateSample>[]
      : audit.equipmentSeries(focus.equipmentId, product: audit.product);

  return MsgqReport(
    title: 'Burn Rate',
    subtitle: audit.product == null ? scope : '$scope · ${audit.product}',
    kpis: [
      MsgqReportKpi('Equipos analizados', _n(audit.kpis.equipmentAnalysed)),
      MsgqReportKpi('Anomalos', _n(audit.kpis.anomalousEquipment)),
      MsgqReportKpi('Burn rate flota', '${audit.kpis.fleetBurnRate} L/h'),
      MsgqReportKpi('Peor desviacion', _pct(audit.kpis.worstDeviationPct)),
      MsgqReportKpi('Intervalos', _n(audit.kpis.intervals),
          hint: '${audit.kpis.atypicalIntervals} atipicos'),
    ],
    sections: [
      if (focus != null && series.length >= 2)
        MsgqReportSection(
          title: 'Serie de ${focus.equipmentId}',
          note: '${focus.category} · el equipo con mayor desviacion',
          chart: MsgqReportChart(
            kind: MsgqChartKind.lines,
            series: [
              MsgqReportSeries(
                label: focus.equipmentId,
                points: series
                    .map((s) => MsgqReportPoint(_day(s.date), s.burnRate))
                    .toList(),
              ),
            ],
            referenceValue: category?.baseline,
            referenceLabel: category == null
                ? null
                : 'Base ${category.category} (${category.baseline} L/h)',
          ),
        ),
      MsgqReportSection(
        title: 'Equipos anomalos',
        note: 'Alto = sobre-consumo (fuga, robo, falla). Bajo = sub-consumo '
            '(medidor mal o despachos sin registrar)',
        table: MsgqReportTable(
          headers: const [
            'Equipo',
            'Descripcion',
            'Categoria',
            'Muestras',
            'L/h',
            'Base',
            'Desv. %',
            'Z',
            'Direccion',
          ],
          rows: audit.equipmentAnomalies
              .map((e) => [
                    e.equipmentId,
                    e.equipmentDescription,
                    e.category,
                    _n(e.samples),
                    _n(e.burnRate),
                    e.baseline?.toString() ?? '—',
                    _pct(e.deviationPct),
                    e.z?.toString() ?? '—',
                    e.direction.label,
                  ])
              .toList(),
        ),
      ),
      MsgqReportSection(
        title: 'Linea base por categoria',
        table: MsgqReportTable(
          headers: const [
            'Categoria',
            'Equipos',
            'Muestras',
            'Base (L/h)',
            'Dispersion',
            'Min',
            'Max',
            'Anomalos',
          ],
          rows: audit.categories
              .map((c) => [
                    c.category,
                    _n(c.equipmentCount),
                    _n(c.samples),
                    _n(c.baseline),
                    _n(c.dispersion),
                    _n(c.min),
                    _n(c.max),
                    _n(c.anomalous),
                  ])
              .toList(),
        ),
      ),
    ],
    footnotes: [
      if (coverage != null && coverage.partial && coverage.first != null)
        'Cobertura parcial: hay datos de SMU del ${_day(coverage.first)} al '
            '${_day(coverage.last)} (${coverage.spanDays} de '
            '${coverage.rangeDays} dias del rango). Ampliar el rango puede no '
            'cambiar el resultado.',
      'El burn rate solo se calcula con despachos que traen lectura de SMU: los '
          'equipos sin horometro no aparecen en este reporte.',
    ],
  );
}

/// Reporte de flota.
MsgqReport buildEquipmentReport(
  EquipmentAnalytics analytics, {
  required String scope,
  required EquipmentDimension dimension,
}) {
  final kpis = analytics.fleetKpis();
  final groups = analytics.groupSummary(dimension);
  final completeness = analytics.dataCompleteness();
  final transitions = analytics.statusTransitions();

  return MsgqReport(
    title: 'Equipos',
    subtitle: scope,
    kpis: kpis == null
        ? const []
        : [
            MsgqReportKpi('Equipos', _n(kpis.total)),
            MsgqReportKpi('Disponibilidad', _pct(kpis.availabilityPct),
                hint: '${kpis.inService} en servicio'),
            MsgqReportKpi('Fuera de servicio', _n(kpis.outOfService)),
            MsgqReportKpi('Dados de baja', _n(kpis.decommissioned)),
            MsgqReportKpi('Contratistas', _n(kpis.contractorVehicles),
                hint: _pct(kpis.contractorPct)),
          ],
    sections: [
      MsgqReportSection(
        title: 'Por ${dimension.label.toLowerCase()}',
        table: MsgqReportTable(
          headers: const [
            'Grupo',
            'Total',
            'En servicio',
            'Fuera',
            'De baja',
            'Disp. %',
          ],
          rows: groups
              .map((g) => [
                    g.key,
                    _n(g.total),
                    _n(g.inService),
                    _n(g.outOfService),
                    _n(g.decommissioned),
                    _pct(g.availabilityPct),
                  ])
              .toList(),
        ),
      ),
      MsgqReportSection(
        title: 'Completitud del maestro',
        note: 'Que porcentaje de equipos tiene cada campo cargado',
        chart: MsgqReportChart(
          kind: MsgqChartKind.bars,
          series: [
            MsgqReportSeries(
              label: 'Completitud',
              points: completeness
                  .map((c) => MsgqReportPoint(c.field, c.completenessPct))
                  .toList(),
            ),
          ],
        ),
        table: MsgqReportTable(
          headers: const ['Campo', 'Con datos', 'Sin datos', 'Completitud %'],
          rows: completeness
              .map((c) => [
                    c.field,
                    _n(c.filled),
                    _n(c.missing),
                    _pct(c.completenessPct),
                  ])
              .toList(),
        ),
      ),
      MsgqReportSection(
        title: 'Transiciones de estado',
        table: MsgqReportTable(
          headers: const ['Fecha', 'Equipo', 'De', 'A', 'Grupo', 'Usuario'],
          rows: transitions
              .map((t) => [
                    _day(t.changedAt),
                    t.equipmentId ?? t.recordId ?? '—',
                    t.from,
                    t.to,
                    t.group ?? noDataLabel,
                    t.whodunnit ?? '—',
                  ])
              .toList(),
        ),
      ),
    ],
  );
}

/// Reporte de salud de hardware.
MsgqReport buildHardwareReport(
  HardwareAudit audit, {
  required String scope,
}) =>
    MsgqReport(
      title: 'Salud de hardware',
      subtitle: scope,
      kpis: [
        MsgqReportKpi('Ordenes', _n(audit.kpis.workOrders)),
        MsgqReportKpi('SMU en regresion', _n(audit.kpis.smuRegressions)),
        MsgqReportKpi('SMU sin pulsos', _n(audit.kpis.smuStagnations)),
        MsgqReportKpi('Re-tagueo', _n(audit.kpis.retagAlerts)),
        MsgqReportKpi('Medidores degradados', _n(audit.kpis.degradedMeters)),
      ],
      sections: [
        MsgqReportSection(
          title: 'Ordenes de trabajo',
          note: 'Una por activo y problema, con el evento mas reciente',
          table: MsgqReportTable(
            headers: const [
              'Severidad',
              'Activo',
              'Problema',
              'Detalle',
              'Fecha',
              'Accion',
            ],
            rows: audit.workOrders
                .map((o) => [
                      o.severity.label,
                      o.asset,
                      o.type,
                      o.detail,
                      _day(o.date),
                      o.action,
                    ])
                .toList(),
          ),
        ),
        MsgqReportSection(
          title: 'Caudal por manguera',
          table: MsgqReportTable(
            headers: const [
              'Medidor',
              'Metrica',
              'Base (L/min)',
              'Reciente (L/min)',
              'Caida %',
              'Degradado',
            ],
            rows: audit.meters
                .map((m) => [
                      m.meterId,
                      m.metric,
                      _n(m.baseFlow),
                      _n(m.recentFlow),
                      _pct(m.dropPct),
                      m.degraded ? 'SI' : 'no',
                    ])
                .toList(),
          ),
        ),
      ],
      footnotes: [
        if (!audit.meterDataAvailable)
          'El tenant no expone identificador de medidor en los despachos: la '
              'salud de las mangueras NO se pudo auditar. Que la seccion este '
              'vacia no significa que esten sanas.',
      ],
    );

/// Reporte de inventario RFID.
MsgqReport buildRfidReport(
  RfidInventoryAudit audit, {
  required String scope,
}) {
  final trends = audit.auditTrends();
  return MsgqReport(
    title: 'Inventario RFID',
    subtitle: scope,
    kpis: [
      MsgqReportKpi('Nuevas', _n(audit.kpis.newInstallations)),
      MsgqReportKpi('Reemplazos', _n(audit.kpis.replacements)),
      MsgqReportKpi('Remociones', _n(audit.kpis.removals)),
      MsgqReportKpi('Tags distintos', _n(audit.kpis.distinctTags)),
      MsgqReportKpi('Equipos con RFID', _n(audit.kpis.equipmentWithRfid),
          hint: 'de ${audit.kpis.totalEquipment}'),
    ],
    sections: [
      MsgqReportSection(
        title: 'Actividad en el tiempo',
        chart: MsgqReportChart(
          kind: MsgqChartKind.lines,
          series: [
            MsgqReportSeries(
              label: 'Actividad',
              points: trends
                  .map((p) =>
                      MsgqReportPoint(_day(p.period), p.activity.toDouble()))
                  .toList(),
            ),
            MsgqReportSeries(
              label: 'Remociones',
              points: trends
                  .map((p) =>
                      MsgqReportPoint(_day(p.period), p.removals.toDouble()))
                  .toList(),
            ),
            MsgqReportSeries(
              label: 'Anomalias',
              points: trends
                  .map((p) =>
                      MsgqReportPoint(_day(p.period), p.anomalies.toDouble()))
                  .toList(),
            ),
          ],
        ),
      ),
      MsgqReportSection(
        title: 'Movimientos de tag',
        note: 'Fecha real del cambio, en hora local del sitio',
        table: MsgqReportTable(
          headers: const [
            'Tipo',
            'Fecha',
            'Equipo',
            'Tag',
            'Cost Centre',
            'Departamento',
            'Producto',
            'Usuario',
          ],
          rows: audit.report.reversed
              .map((r) => [
                    r.operation.label,
                    _day(r.date),
                    r.equipmentId,
                    r.tag ?? '—',
                    r.costCentre ?? '—',
                    r.department ?? '—',
                    r.product ?? '—',
                    r.whodunnit ?? '—',
                  ])
              .toList(),
        ),
      ),
      MsgqReportSection(
        title: 'Validaciones',
        table: MsgqReportTable(
          headers: const ['Validacion', 'Anomalias', 'Descripcion'],
          rows: audit
              .validationSummary()
              .map((v) => [v.name, _n(v.anomalies), v.description])
              .toList(),
        ),
      ),
    ],
  );
}

/// Reporte de actividad y producto.
MsgqReport buildActivityReport(
  ActivityAudit activity,
  ProductAudit product, {
  required String scope,
}) =>
    MsgqReport(
      title: 'Actividad y producto',
      subtitle: scope,
      kpis: [
        MsgqReportKpi('En servicio', _n(activity.kpis.equipmentInService)),
        MsgqReportKpi('Fantasmas', _n(activity.kpis.idleAssets),
            hint: '≥ ${activity.idleDays} dias'),
        MsgqReportKpi('Nunca despacharon', _n(activity.kpis.neverDispensed)),
        MsgqReportKpi(
            'No registrado', _l(activity.kpis.unregisteredLitres),
            hint: 'estimado'),
        MsgqReportKpi('Rachas sobre SFL', _n(activity.kpis.runsOverSfl)),
        MsgqReportKpi('Producto ajeno', _n(product.kpis.mismatches),
            hint: '${product.kpis.crossClass} cruces de clase'),
      ],
      sections: [
        MsgqReportSection(
          title: 'Equipos fantasma',
          note: 'Figuran operativos pero no despachan',
          table: MsgqReportTable(
            headers: const [
              'Equipo',
              'Descripcion',
              'Categoria',
              'Ultimo despacho',
              'Dias',
              'Despachos',
              'Clase',
            ],
            rows: activity.idleAssets
                .map((a) => [
                      a.equipmentId,
                      a.description ?? '—',
                      a.category ?? noDataLabel,
                      _day(a.lastDispense),
                      a.daysIdle?.toStringAsFixed(0) ?? '—',
                      _n(a.historicDispenses),
                      a.idleClass.label,
                    ])
                .toList(),
          ),
        ),
        MsgqReportSection(
          title: 'Combustible no registrado',
          note: 'Consumo estimado por el SMU contra lo que si quedo registrado',
          table: MsgqReportTable(
            headers: const [
              'Equipo',
              'Desde',
              'Hasta',
              'Dias',
              'Delta SMU',
              'L/h tipico',
              'Esperado (L)',
              'Registrado (L)',
              'SFL',
              'No registrado (L)',
            ],
            rows: activity.unfueled
                .map((u) => [
                      u.equipmentId,
                      _day(u.from),
                      _day(u.to),
                      u.days.toStringAsFixed(0),
                      _n(u.smuDelta),
                      _n(u.typicalBurnRate),
                      _n(u.expectedLitres),
                      _n(u.dispensedLitres),
                      _n(u.sfl),
                      _n(u.unregisteredLitres),
                    ])
                .toList(),
          ),
        ),
        MsgqReportSection(
          title: 'Despachos sin operacion',
          table: MsgqReportTable(
            headers: const [
              'Equipo',
              'Desde',
              'Hasta',
              'Dias',
              'Despachos',
              'Litros',
              'SFL',
              'Sobre SFL',
            ],
            rows: activity.frozen
                .map((f) => [
                      f.equipmentId,
                      _day(f.from),
                      _day(f.to),
                      f.days.toStringAsFixed(0),
                      _n(f.dispenses),
                      _n(f.litres),
                      f.sfl == null ? '—' : _n(f.sfl!),
                      f.overSfl ? 'SI' : 'no',
                    ])
                .toList(),
          ),
        ),
        MsgqReportSection(
          title: 'Producto ajeno al equipo',
          note: 'Un cruce ENTRE clases (combustible vs fluido) es la señal '
              'fuerte de tag clonado',
          table: MsgqReportTable(
            headers: const [
              'Fecha',
              'Equipo',
              'Producto',
              'Clase',
              'Esperados',
              'Volumen',
              'Punto',
              'Cruce',
            ],
            rows: product.mismatches
                .map((m) => [
                      _day(m.date),
                      m.equipmentId,
                      m.product ?? '—',
                      m.productClassOf.label,
                      m.expectedProducts ?? '—',
                      m.volume == null ? '—' : _n(m.volume!),
                      m.dispensingPoint ?? '—',
                      m.crossClass ? 'SI' : 'no',
                    ])
                .toList(),
          ),
        ),
      ],
      footnotes: const [
        'Los detectores de combustible no registrado y de despachos sin '
            'operacion requieren lectura de SMU por despacho: los equipos sin '
            'horometro solo participan de la deteccion de fantasmas.',
        'Un equipo sin productos establecidos se omite de la auditoria de '
            'producto: no hay base con que juzgarlo.',
      ],
    );

/// Reporte de tag hopping.
MsgqReport buildTagHoppingReport(
  TagHopAudit audit, {
  required String scope,
}) =>
    MsgqReport(
      title: 'Tag hopping',
      subtitle: scope,
      kpis: [
        MsgqReportKpi('Eventos', _n(audit.kpis.events)),
        MsgqReportKpi('Criticos', _n(audit.kpis.critical)),
        MsgqReportKpi('Equipos', _n(audit.kpis.equipmentInvolved)),
        MsgqReportKpi('Por velocidad', _n(audit.kpis.bySpeed)),
      ],
      sections: [
        MsgqReportSection(
          title: 'Eventos detectados',
          note: 'El lugar es el ACTIVO surtidor: dos tanques del mismo camion '
              'no son dos lugares',
          table: MsgqReportTable(
            headers: const [
              'Equipo',
              'Tag',
              'Antes',
              'Fecha antes',
              'Despues',
              'Fecha despues',
              'Lapso (min)',
              'Dist. (km)',
              'km/h',
              'Motivo',
              'Severidad',
            ],
            rows: audit.events
                .map((e) => [
                      e.equipmentId,
                      e.tag ?? '—',
                      e.previousLocation,
                      _day(e.previousDate),
                      e.location,
                      _day(e.date),
                      _n(e.gapMinutes),
                      e.distanceKm == null ? '—' : _n(e.distanceKm!),
                      e.speedKmh == null ? '—' : _n(e.speedKmh!),
                      e.reason,
                      e.critical ? 'CRITICO' : 'ADVERTENCIA',
                    ])
                .toList(),
          ),
        ),
      ],
      footnotes: const [
        'La regla de velocidad solo aplica donde ambos despachos traen '
            'coordenadas: en este tenant el GPS por transaccion solo lo pueblan '
            'los surtidores moviles. La cobertura la da la regla de '
            'solapamiento temporal, que no necesita coordenadas.',
      ],
    );
