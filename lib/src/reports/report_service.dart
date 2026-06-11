/// Generacion de reportes (CSV / PDF) como los exports de AdaptIQ.
///
/// El reporte consulta la API EN VIVO (no la ventana local de 7 dias):
/// `filter: { updatedFrom: <inicio del periodo> }` garantiza traer todo lo
/// COLECTADO dentro del periodo (un registro colectado en el rango siempre
/// tiene `recordUpdatedAt >= recordCollectedAt >= inicio`), y luego se filtra
/// client-side por `recordCollectedAt` dentro de [inicio, fin).
///
/// Datasets, espejo de las pestañas del monitor + el export de alarmas:
///   * Entregas   — columnas tipo Movements/Deliveries (medido, guia, varianza).
///   * Despachos  — columnas tipo Movements/Dispenses.
///   * Sobrellenados SFL — formato del export de Alerts/Alarms
///     ("Equipment X - desc overfill by N L") + columnas estructuradas.
///
/// El CSV genera UN archivo por dataset (mas comodo en Excel); el PDF genera
/// UN documento con una seccion por dataset. Los archivos van a la carpeta
/// temporal y se entregan a la hoja de compartir del sistema.
library;

import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../api/adaptiq_client.dart';
import '../config/app_settings.dart';
import '../core/delivery_check.dart';
import '../core/sfl_check.dart';
import '../models/delivery.dart';
import '../models/dispense.dart';
import '../storage/app_store.dart';

enum ReportPeriod { daily, weekly, monthly, yearly }

enum ReportFormat { csv, pdf }

extension ReportPeriodX on ReportPeriod {
  String get label => switch (this) {
        ReportPeriod.daily => 'Diario (hoy)',
        ReportPeriod.weekly => 'Semanal (ultimos 7 dias)',
        ReportPeriod.monthly => 'Mensual (mes actual)',
        ReportPeriod.yearly => 'Anual (año actual)',
      };

  String get slug => switch (this) {
        ReportPeriod.daily => 'diario',
        ReportPeriod.weekly => 'semanal',
        ReportPeriod.monthly => 'mensual',
        ReportPeriod.yearly => 'anual',
      };

  /// Rango [inicio, fin) en hora LOCAL del dispositivo (los cortes de dia que
  /// espera el auditor), devuelto en UTC para la API.
  ({DateTime start, DateTime end}) range(DateTime nowLocal) {
    final today = DateTime(nowLocal.year, nowLocal.month, nowLocal.day);
    final start = switch (this) {
      ReportPeriod.daily => today,
      ReportPeriod.weekly => today.subtract(const Duration(days: 6)),
      ReportPeriod.monthly => DateTime(nowLocal.year, nowLocal.month, 1),
      ReportPeriod.yearly => DateTime(nowLocal.year, 1, 1),
    };
    return (start: start.toUtc(), end: nowLocal.toUtc());
  }
}

class ReportRequest {
  const ReportRequest({
    required this.period,
    required this.format,
    this.includeDeliveries = true,
    this.includeDispenses = false,
    this.includeOverfills = true,
  });

  final ReportPeriod period;
  final ReportFormat format;
  final bool includeDeliveries;
  final bool includeDispenses;
  final bool includeOverfills;

  bool get hasAnyDataset =>
      includeDeliveries || includeDispenses || includeOverfills;
}

class ReportResult {
  const ReportResult({required this.files, required this.summary});

  final List<XFile> files;
  final String summary;
}

// ---------------------------------------------------------------------------
// CSV (puro y testeable)
// ---------------------------------------------------------------------------

/// Escapa un valor CSV (RFC 4180): comillas si trae coma/comilla/salto.
String csvEscape(Object? value) {
  final text = value == null ? '' : value.toString();
  if (text.contains(',') || text.contains('"') || text.contains('\n')) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String buildCsv(List<List<Object?>> rows) =>
    rows.map((r) => r.map(csvEscape).join(',')).join('\r\n');

// ---------------------------------------------------------------------------
// Servicio
// ---------------------------------------------------------------------------

class ReportService {
  ReportService(this._settings, this._store);

  final AppSettings _settings;
  final AppStore _store;

  static final _dt = DateFormat('yyyy-MM-dd HH:mm');
  static final _num = NumberFormat('0.0#');

  /// Genera los archivos del reporte. [onProgress] recibe estados legibles
  /// para la UI ("Descargando entregas…").
  Future<ReportResult> generate(
    ReportRequest request, {
    void Function(String status)? onProgress,
  }) async {
    if (!request.hasAnyDataset) {
      throw const ApiException('Selecciona al menos un dataset.');
    }
    final nowLocal = DateTime.now();
    final range = request.period.range(nowLocal);

    final client = AdaptIQClient(
      _settings,
      siteId: _store.cachedSiteId,
      knownOptionalFields: _store.cachedAdaptMacFields,
      equipmentField: _store.cachedEquipmentField,
    );
    List<Delivery> deliveries = const [];
    List<Dispense> dispenses = const [];
    List<OverfillAlert> overfills = const [];
    try {
      if (request.includeDeliveries) {
        onProgress?.call('Descargando entregas…');
        deliveries = (await client.fetchDeliveries(updatedFrom: range.start))
            .where((d) => _inRange(d.collectedAt, range))
            .toList()
          ..sort((a, b) => (b.collectedAt ?? DateTime(0))
              .compareTo(a.collectedAt ?? DateTime(0)));
      }
      if (request.includeDispenses || request.includeOverfills) {
        onProgress?.call('Descargando despachos…');
        dispenses = (await client.fetchDispenses(updatedFrom: range.start))
            .where((d) => _inRange(d.collectedAt, range))
            .toList()
          ..sort((a, b) => (b.collectedAt ?? DateTime(0))
              .compareTo(a.collectedAt ?? DateTime(0)));
      }
      if (request.includeOverfills) {
        onProgress?.call('Cruzando despachos contra SFL…');
        var limits = _store.loadSflLimits();
        if (limits == null || limits.isEmpty) {
          limits = await client.fetchSflLimits();
          if (limits != null) {
            await _store.saveSflLimits(limits,
                equipmentField: client.equipmentField ?? '',
                now: DateTime.now().toUtc());
          }
        }
        overfills = limits == null || limits.isEmpty
            ? const []
            : detectOverfills(dispenses: dispenses, limits: limits);
      }
    } finally {
      client.close();
    }

    onProgress?.call('Generando ${request.format.name.toUpperCase()}…');
    final dir = await getTemporaryDirectory();
    final stamp = DateFormat('yyyy-MM-dd_HHmm').format(nowLocal);
    final base = 'adaptiq_${request.period.slug}_$stamp';

    final files = <XFile>[];
    if (request.format == ReportFormat.csv) {
      if (request.includeDeliveries) {
        files.add(await _writeFile(
            dir, '${base}_entregas.csv', buildCsv(_deliveryRows(deliveries))));
      }
      if (request.includeDispenses) {
        files.add(await _writeFile(
            dir, '${base}_despachos.csv', buildCsv(_dispenseRows(dispenses))));
      }
      if (request.includeOverfills) {
        files.add(await _writeFile(dir, '${base}_sobrellenados_sfl.csv',
            buildCsv(_overfillRows(overfills))));
      }
    } else {
      final bytes = await _buildPdf(
        request: request,
        range: range,
        deliveries: deliveries,
        dispenses: dispenses,
        overfills: overfills,
        generatedAt: nowLocal,
      );
      final file = File('${dir.path}${Platform.pathSeparator}$base.pdf');
      await file.writeAsBytes(bytes, flush: true);
      files.add(XFile(file.path, mimeType: 'application/pdf'));
    }

    final summary = [
      'Reporte ${request.period.slug} '
          '(${_dt.format(range.start.toLocal())} → ${_dt.format(range.end.toLocal())})',
      if (request.includeDeliveries) '${deliveries.length} entregas',
      if (request.includeDispenses) '${dispenses.length} despachos',
      if (request.includeOverfills) '${overfills.length} sobrellenados SFL',
    ].join(' · ');
    return ReportResult(files: files, summary: summary);
  }

  bool _inRange(DateTime? at, ({DateTime start, DateTime end}) range) =>
      at != null && !at.isBefore(range.start) && at.isBefore(range.end);

  Future<XFile> _writeFile(Directory dir, String name, String content) async {
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(content, flush: true);
    return XFile(file.path, mimeType: 'text/csv');
  }

  // -- filas ---------------------------------------------------------------------

  List<List<Object?>> _deliveryRows(List<Delivery> deliveries) => [
        [
          'Collected At', 'Tank', 'Product', 'Docket', 'Type', 'Status',
          'Metered Volume (L)', 'Docket Volume (L)', 'Variance (L)',
          'Variance (%)', 'Driver', 'Company', 'AdaptMAC',
        ],
        for (final d in deliveries)
          [
            d.collectedAt == null ? '' : _dt.format(d.collectedAt!.toLocal()),
            d.tank, d.product, d.docketNumber, d.type, d.status,
            d.volume == null ? '' : _num.format(d.volume),
            d.secondaryVolume == null ? '' : _num.format(d.secondaryVolume),
            d.deviationL == null ? '' : _num.format(d.deviationL),
            d.deviationPct == null ? '' : _num.format(d.deviationPct),
            d.driver, d.company, d.adaptMac,
          ],
      ];

  List<List<Object?>> _dispenseRows(List<Dispense> dispenses) => [
        [
          'Collected At', 'Equipment', 'Description', 'Product', 'Volume (L)',
          'Type', 'Status', 'Dispensing Point', 'Operator', 'AdaptMAC',
        ],
        for (final d in dispenses)
          [
            d.collectedAt == null ? '' : _dt.format(d.collectedAt!.toLocal()),
            d.equipmentId, d.equipmentDescription, d.product,
            d.volume == null ? '' : _num.format(d.volume),
            d.type, d.status, d.tank, d.fieldUser, d.adaptMac,
          ],
      ];

  /// Mismo encabezado que el export de Alerts/Alarms de AdaptIQ + columnas
  /// estructuradas para poder filtrar en Excel.
  List<List<Object?>> _overfillRows(List<OverfillAlert> overfills) => [
        [
          'Raised at', 'Description', 'Equipment', 'Product', 'Volume (L)',
          'SFL (L)', 'Overfill (L)', 'Dispensing Point', 'Operator',
        ],
        for (final o in overfills)
          [
            o.collectedAt == null ? '' : _dt.format(o.collectedAt!.toLocal()),
            'Equipment ${o.equipmentId}'
                '${(o.equipmentDescription ?? '').isEmpty ? '' : ' - ${o.equipmentDescription}'}'
                ' overfill by ${_num.format(o.excess)} L',
            o.equipmentId, o.product,
            _num.format(o.volume), _num.format(o.sfl), _num.format(o.excess),
            o.tank, o.fieldUser,
          ],
      ];

  // -- PDF ---------------------------------------------------------------------------

  /// Tope de filas por tabla en el PDF: un anual de despachos puede traer
  /// decenas de miles de filas — eso es dominio del CSV, el PDF es el resumen.
  static const _pdfMaxRows = 600;

  Future<List<int>> _buildPdf({
    required ReportRequest request,
    required ({DateTime start, DateTime end}) range,
    required List<Delivery> deliveries,
    required List<Dispense> dispenses,
    required List<OverfillAlert> overfills,
    required DateTime generatedAt,
  }) async {
    final doc = pw.Document();
    final titleStyle =
        pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold);
    final sectionStyle =
        pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold);
    const cellStyle = pw.TextStyle(fontSize: 7);
    final headerStyle =
        pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold);

    pw.Widget table(List<List<Object?>> rows) {
      final data = rows.length > _pdfMaxRows + 1
          ? rows.sublist(0, _pdfMaxRows + 1)
          : rows;
      return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.TableHelper.fromTextArray(
          headers: data.first,
          data: data.sublist(1),
          headerStyle: headerStyle,
          cellStyle: cellStyle,
          headerDecoration:
              const pw.BoxDecoration(color: PdfColor.fromInt(0xFFDDE5F0)),
          cellPadding:
              const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 1.5),
        ),
        if (rows.length > _pdfMaxRows + 1)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(
              'Mostrando $_pdfMaxRows de ${rows.length - 1} filas — '
              'usa el formato CSV para el detalle completo.',
              style: const pw.TextStyle(fontSize: 7),
            ),
          ),
      ]);
    }

    final flagged = deliveries
        .where((d) => conditionsForDelivery(d,
                thresholdPct: _settings.varianceThresholdPct)
            .isNotEmpty)
        .length;

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      header: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 6),
        child: pw.Text(
          'AdaptIQ Monitor — sitio ${_settings.siteMatch} — '
          'pagina ${ctx.pageNumber}/${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
        ),
      ),
      build: (ctx) => [
        pw.Text('Reporte ${request.period.slug} de combustible (FMS)',
            style: titleStyle),
        pw.SizedBox(height: 4),
        pw.Text(
          'Periodo: ${_dt.format(range.start.toLocal())} → '
          '${_dt.format(range.end.toLocal())}   ·   '
          'Generado: ${_dt.format(generatedAt)}',
          style: const pw.TextStyle(fontSize: 9),
        ),
        pw.SizedBox(height: 8),
        pw.Bullet(
            text: request.includeDeliveries
                ? 'Entregas: ${deliveries.length} ($flagged con anomalias)'
                : 'Entregas: (no incluidas)',
            style: const pw.TextStyle(fontSize: 9)),
        if (request.includeDispenses)
          pw.Bullet(
              text: 'Despachos: ${dispenses.length}',
              style: const pw.TextStyle(fontSize: 9)),
        if (request.includeOverfills)
          pw.Bullet(
              text: 'Sobrellenados SFL: ${overfills.length} '
                  '(exceso total ${_num.format(overfills.fold<double>(0, (acc, o) => acc + o.excess))} L)',
              style: const pw.TextStyle(fontSize: 9)),
        if (request.includeDeliveries) ...[
          pw.SizedBox(height: 12),
          pw.Text('Entregas', style: sectionStyle),
          pw.SizedBox(height: 4),
          table(_deliveryRows(deliveries)),
        ],
        if (request.includeOverfills) ...[
          pw.SizedBox(height: 12),
          pw.Text('Sobrellenados SFL (Equipment Overfill)',
              style: sectionStyle),
          pw.SizedBox(height: 4),
          table(_overfillRows(overfills)),
        ],
        if (request.includeDispenses) ...[
          pw.SizedBox(height: 12),
          pw.Text('Despachos', style: sectionStyle),
          pw.SizedBox(height: 4),
          table(_dispenseRows(dispenses)),
        ],
      ],
    ));
    return doc.save();
  }
}
