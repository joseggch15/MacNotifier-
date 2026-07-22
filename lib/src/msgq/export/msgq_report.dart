/// Modelo de reporte y su render a PDF / CSV — port de `msgq/export/`.
///
/// El escritorio dibuja sus graficas con matplotlib y las incrusta como imagen.
/// Aqui se dibujan como VECTORES con los widgets de grafica del paquete `pdf`:
/// el archivo pesa menos, el texto queda seleccionable y no hace falta rasterizar
/// nada en un telefono.
///
/// La separacion que hace esto manejable: un modulo NO sabe de PDF. Describe su
/// reporte ([MsgqReport]: KPIs, tablas y series) y esta capa decide como se
/// pinta. Anadir un modulo nuevo al export no toca este archivo.
///
/// La paleta es la misma que la de pantalla ([MsgqPalette]), en sus pasos
/// claros: el papel es una superficie clara, y que un tanque tenga el mismo
/// color en la app y en el PDF es lo que permite leerlos juntos.
library;

import 'dart:convert';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Un indicador de cabecera.
class MsgqReportKpi {
  const MsgqReportKpi(this.label, this.value, {this.hint});

  final String label;
  final String value;
  final String? hint;
}

/// Una tabla: cabeceras y filas ya formateadas a texto.
class MsgqReportTable {
  const MsgqReportTable({
    required this.headers,
    required this.rows,
    this.maxRows = 60,
  });

  final List<String> headers;
  final List<List<String>> rows;

  /// Tope de filas impresas. Un PDF de auditoria no es un volcado de la base:
  /// pasado el tope se anota cuantas quedaron fuera.
  final int maxRows;
}

/// Un punto de una serie del reporte.
class MsgqReportPoint {
  const MsgqReportPoint(this.label, this.value);

  /// Etiqueta del eje X (fecha ya formateada, o nombre de categoria).
  final String label;

  final double value;
}

/// Una serie con nombre.
class MsgqReportSeries {
  const MsgqReportSeries({required this.label, required this.points});

  final String label;
  final List<MsgqReportPoint> points;
}

enum MsgqChartKind { bars, lines }

/// Una grafica del reporte.
class MsgqReportChart {
  const MsgqReportChart({
    required this.kind,
    required this.series,
    this.referenceValue,
    this.referenceLabel,
  });

  final MsgqChartKind kind;
  final List<MsgqReportSeries> series;

  /// Linea horizontal de referencia (linea base de una categoria, un umbral).
  final double? referenceValue;
  final String? referenceLabel;
}

/// Un bloque del reporte: titulo, nota opcional y una grafica y/o una tabla.
class MsgqReportSection {
  const MsgqReportSection({
    required this.title,
    this.note,
    this.chart,
    this.table,
  });

  final String title;
  final String? note;
  final MsgqReportChart? chart;
  final MsgqReportTable? table;
}

/// Lo que un modulo entrega para exportar.
class MsgqReport {
  const MsgqReport({
    required this.title,
    required this.subtitle,
    this.kpis = const [],
    this.sections = const [],
    this.footnotes = const [],
  });

  final String title;
  final String subtitle;
  final List<MsgqReportKpi> kpis;
  final List<MsgqReportSection> sections;

  /// Advertencias del propio dato (cobertura parcial, capacidad ausente). Van
  /// EN el PDF, no solo en pantalla: un reporte que se comparte por fuera de la
  /// app tiene que llevar sus propias salvedades.
  final List<String> footnotes;

  /// Nombre de archivo sugerido, sin extension.
  String fileSlug(DateTime at) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final stamp = '${at.year}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}';
    return 'msgq_${slug}_$stamp';
  }
}

// ===========================================================================
// Render a PDF
// ===========================================================================

/// Pasos claros de la paleta categorica validada (los mismos de pantalla).
const List<PdfColor> _palette = [
  PdfColor.fromInt(0xFF2A78D6),
  PdfColor.fromInt(0xFFEB6834),
  PdfColor.fromInt(0xFF1BAF7A),
  PdfColor.fromInt(0xFFEDA100),
  PdfColor.fromInt(0xFFE87BA4),
  PdfColor.fromInt(0xFF008300),
];

/// Series distinguibles a la vez. Igual que en pantalla, pasado el tope no se
/// generan hues nuevos.
const int _maxSeries = 6;

final _titleStyle =
    pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold);
final _sectionStyle =
    pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold);
const _noteStyle = pw.TextStyle(fontSize: 8, color: PdfColors.grey700);
const _cellStyle = pw.TextStyle(fontSize: 7);
final _headerStyle =
    pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold);

/// Construye el PDF de un reporte.
Future<List<int>> buildMsgqPdf(MsgqReport report, {DateTime? generatedAt}) async {
  final at = generatedAt ?? DateTime.now();
  final doc = pw.Document();

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(24),
    header: (ctx) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('MSGQ · ${report.title}', style: _noteStyle),
          pw.Text('Pagina ${ctx.pageNumber} de ${ctx.pagesCount}',
              style: _noteStyle),
        ],
      ),
    ),
    build: (ctx) => [
      pw.Text(report.title, style: _titleStyle),
      pw.SizedBox(height: 3),
      pw.Text(report.subtitle, style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 2),
      pw.Text('Generado el ${_stamp(at)}', style: _noteStyle),
      if (report.kpis.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        _kpiRow(report.kpis),
      ],
      for (final section in report.sections) ..._section(section),
      if (report.footnotes.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        pw.Divider(color: PdfColors.grey400),
        for (final note in report.footnotes)
          pw.Bullet(text: note, style: _noteStyle),
      ],
    ],
  ));
  return doc.save();
}

pw.Widget _kpiRow(List<MsgqReportKpi> kpis) => pw.Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final k in kpis)
          pw.Container(
            width: 118,
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(k.label, style: _noteStyle),
                pw.SizedBox(height: 2),
                pw.Text(k.value,
                    style: pw.TextStyle(
                        fontSize: 13, fontWeight: pw.FontWeight.bold)),
                if (k.hint != null)
                  pw.Text(k.hint!,
                      style:
                          const pw.TextStyle(fontSize: 7, color: PdfColors.grey600)),
              ],
            ),
          ),
      ],
    );

List<pw.Widget> _section(MsgqReportSection section) => [
      pw.SizedBox(height: 14),
      pw.Text(section.title, style: _sectionStyle),
      if (section.note != null) ...[
        pw.SizedBox(height: 2),
        pw.Text(section.note!, style: _noteStyle),
      ],
      pw.SizedBox(height: 6),
      if (section.chart != null) _chart(section.chart!),
      if (section.chart != null && section.table != null)
        pw.SizedBox(height: 8),
      if (section.table != null) _table(section.table!),
    ];

pw.Widget _chart(MsgqReportChart chart) {
  final shown = chart.series
      .where((s) => s.points.isNotEmpty)
      .take(_maxSeries)
      .toList();
  if (shown.isEmpty) {
    return pw.Text('Sin datos en el periodo.', style: _noteStyle);
  }
  final omitted =
      chart.series.where((s) => s.points.isNotEmpty).length - shown.length;

  // Eje X compartido: las series se alinean por POSICION, asi que cada una
  // debe traer la misma rejilla de puntos (las pantallas ya las construyen asi).
  final labels = shown.first.points.map((p) => p.label).toList();
  var maxY = shown
      .expand((s) => s.points)
      .map((p) => p.value)
      .fold<double>(0, (a, b) => b > a ? b : a);
  var minY = shown
      .expand((s) => s.points)
      .map((p) => p.value)
      .fold<double>(0, (a, b) => b < a ? b : a);
  if (chart.referenceValue != null) {
    if (chart.referenceValue! > maxY) maxY = chart.referenceValue!;
    if (chart.referenceValue! < minY) minY = chart.referenceValue!;
  }
  if (maxY == minY) maxY = minY + 1;
  final pad = (maxY - minY) * 0.1;

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.SizedBox(
        height: 150,
        child: pw.Chart(
          grid: pw.CartesianGrid(
            xAxis: pw.FixedAxis<int>(
              // Solo unas pocas marcas: etiquetar cada punto las solapa. Con un
              // unico punto se anade una marca vacia: un eje de span cero hace
              // que la escala del grafico divida entre cero y salga NaN.
              _tickPositions(labels.length),
              buildLabel: (v) {
                final i = v as int;
                return pw.Text(
                  i < labels.length ? labels[i] : '',
                  style: const pw.TextStyle(fontSize: 6),
                );
              },
              divisions: false,
            ),
            yAxis: pw.FixedAxis<double>(
              _yTicks(minY - pad, maxY + pad),
              divisions: true,
              divisionsColor: PdfColors.grey300,
              format: (v) => _compact(v as double),
              textStyle: const pw.TextStyle(fontSize: 6),
            ),
          ),
          datasets: [
            for (var i = 0; i < shown.length; i++)
              if (chart.kind == MsgqChartKind.bars)
                pw.BarDataSet(
                  legend: shown.length > 1 ? shown[i].label : null,
                  color: _palette[i % _palette.length],
                  width: (320 / labels.length).clamp(2, 14),
                  data: _points(shown[i]),
                )
              else
                pw.LineDataSet(
                  legend: shown.length > 1 ? shown[i].label : null,
                  color: _palette[i % _palette.length],
                  lineWidth: 1.5,
                  drawPoints: labels.length <= 20,
                  pointSize: 2,
                  data: _points(shown[i]),
                ),
            if (chart.referenceValue != null)
              pw.LineDataSet(
                legend: chart.referenceLabel,
                color: PdfColors.grey600,
                lineWidth: 1,
                drawPoints: false,
                data: [
                  pw.PointChartValue(0, chart.referenceValue!),
                  pw.PointChartValue(
                      (labels.length - 1).toDouble(), chart.referenceValue!),
                ],
              ),
          ],
        ),
      ),
      if (shown.length > 1 || chart.referenceLabel != null) ...[
        pw.SizedBox(height: 4),
        pw.Wrap(spacing: 10, children: [
          for (var i = 0; i < shown.length; i++)
            _legendChip(_palette[i % _palette.length], shown[i].label),
          if (chart.referenceLabel != null)
            _legendChip(PdfColors.grey600, chart.referenceLabel!),
        ]),
      ],
      if (omitted > 0)
        pw.Text('+$omitted series mas (ver la tabla)', style: _noteStyle),
    ],
  );
}

pw.Widget _legendChip(PdfColor color, String label) => pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(width: 7, height: 7, color: color),
        pw.SizedBox(width: 3),
        // El texto va en tinta, no en el color de la serie: el cuadrito ya
        // lleva la identidad y la etiqueta se lee igual en blanco y negro.
        pw.Text(label, style: const pw.TextStyle(fontSize: 7)),
      ],
    );

List<pw.PointChartValue> _points(MsgqReportSeries series) => [
      for (var i = 0; i < series.points.length; i++)
        pw.PointChartValue(i.toDouble(), series.points[i].value),
    ];

/// Hasta 6 marcas repartidas por el eje X.
///
/// Nunca devuelve menos de dos: `FixedAxis` necesita un span mayor que cero
/// para escalar, y con una sola marca el render entero cae con NaN.
List<int> _tickPositions(int count) {
  if (count <= 1) return const [0, 1];
  if (count <= 6) return [for (var i = 0; i < count; i++) i];
  final step = (count / 5).ceil();
  final ticks = <int>[];
  for (var i = 0; i < count; i += step) {
    ticks.add(i);
  }
  if (ticks.last != count - 1) ticks.add(count - 1);
  return ticks;
}

/// Cinco marcas redondas en el eje Y.
List<double> _yTicks(double min, double max) {
  final step = (max - min) / 4;
  return [for (var i = 0; i <= 4; i++) min + step * i];
}

pw.Widget _table(MsgqReportTable table) {
  if (table.rows.isEmpty) {
    return pw.Text('Sin filas.', style: _noteStyle);
  }
  final shown = table.rows.take(table.maxRows).toList();
  final omitted = table.rows.length - shown.length;
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.TableHelper.fromTextArray(
        headers: table.headers,
        data: shown,
        cellStyle: _cellStyle,
        headerStyle: _headerStyle,
        headerDecoration:
            const pw.BoxDecoration(color: PdfColor.fromInt(0xFFDDE5F0)),
        cellPadding:
            const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.4),
      ),
      if (omitted > 0)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 3),
          child: pw.Text(
            '$omitted filas mas no impresas (usa el export CSV para el detalle '
            'completo).',
            style: _noteStyle,
          ),
        ),
    ],
  );
}

String _stamp(DateTime at) =>
    '${at.day.toString().padLeft(2, '0')}/'
    '${at.month.toString().padLeft(2, '0')}/${at.year} '
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

String _compact(double value) {
  final abs = value.abs();
  if (abs >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (abs >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  if (abs >= 10) return value.toStringAsFixed(0);
  return value.toStringAsFixed(1);
}

// ===========================================================================
// Render a CSV
// ===========================================================================

/// CSV de TODAS las tablas del reporte, una detras de otra.
///
/// El PDF recorta filas para seguir siendo legible; el CSV no recorta nada — es
/// el que se abre en Excel cuando hay que revisar el detalle completo.
String buildMsgqCsv(MsgqReport report) {
  final buffer = StringBuffer();
  buffer.writeln(_csvRow([report.title]));
  buffer.writeln(_csvRow([report.subtitle]));
  for (final kpi in report.kpis) {
    buffer.writeln(_csvRow([kpi.label, kpi.value, kpi.hint ?? '']));
  }
  for (final section in report.sections) {
    final table = section.table;
    if (table == null) continue;
    buffer.writeln();
    buffer.writeln(_csvRow([section.title]));
    buffer.writeln(_csvRow(table.headers));
    for (final row in table.rows) {
      buffer.writeln(_csvRow(row));
    }
  }
  for (final note in report.footnotes) {
    buffer.writeln();
    buffer.writeln(_csvRow([note]));
  }
  // BOM: sin el, Excel en Windows abre los acentos como mojibake.
  return '﻿$buffer';
}

String _csvRow(List<String> cells) => cells.map(_csvCell).join(',');

String _csvCell(String value) {
  final needsQuotes = value.contains(RegExp(r'[",\n\r]'));
  final escaped = value.replaceAll('"', '""');
  return needsQuotes ? '"$escaped"' : escaped;
}

/// Bytes UTF-8 del CSV, listos para escribir a disco.
List<int> csvBytes(String csv) => utf8.encode(csv);
