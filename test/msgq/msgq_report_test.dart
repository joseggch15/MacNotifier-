import 'package:adapt_mac_notifier/src/msgq/analytics/tank_analytics.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/fms_vocabulary.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/movement.dart';
import 'package:adapt_mac_notifier/src/msgq/domain/tank.dart';
import 'package:adapt_mac_notifier/src/msgq/export/msgq_export_service.dart';
import 'package:adapt_mac_notifier/src/msgq/export/msgq_report.dart';
import 'package:flutter_test/flutter_test.dart';

MsgqReport _sample({int rows = 5}) => MsgqReport(
      title: 'Tanques y consumo',
      subtitle: 'Ultimos 90 dias · circuito Diesel',
      kpis: const [
        MsgqReportKpi('Despachado', '12.500,0 L'),
        MsgqReportKpi('Tanques', '4', hint: 'activos'),
      ],
      sections: [
        MsgqReportSection(
          title: 'Consumo en el tiempo',
          chart: MsgqReportChart(
            kind: MsgqChartKind.bars,
            series: [
              MsgqReportSeries(
                label: 'Despachado',
                points: List.generate(
                    12, (i) => MsgqReportPoint('0${i + 1}/06', 100.0 + i * 10)),
              ),
            ],
          ),
        ),
        MsgqReportSection(
          title: 'Consumo por producto',
          table: MsgqReportTable(
            headers: const ['Producto', 'Despachos', 'Volumen (L)'],
            rows: List.generate(
                rows, (i) => ['Producto $i', '$i', '${i * 100}.0']),
            maxRows: 3,
          ),
        ),
      ],
      footnotes: const ['Una salvedad del dato.'],
    );

void main() {
  group('nombre de archivo', () {
    test('se deriva del titulo y lleva la fecha', () {
      final slug = _sample().fileSlug(DateTime.utc(2026, 7, 5));
      expect(slug, 'msgq_tanques_y_consumo_20260705');
    });

    test('no deja separadores sueltos al inicio ni al final', () {
      const report = MsgqReport(title: '¡Tag hopping!', subtitle: '');
      final slug = report.fileSlug(DateTime.utc(2026, 12, 31));
      expect(slug, 'msgq_tag_hopping_20261231');
    });
  });

  group('PDF', () {
    test('genera un documento valido con graficas y tablas', () async {
      final bytes = await buildMsgqPdf(_sample(),
          generatedAt: DateTime.utc(2026, 7, 5, 14, 30));
      expect(bytes, isNotEmpty);
      // Cabecera y cola de un PDF bien formado.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(String.fromCharCodes(bytes.skip(bytes.length - 6)),
          contains('%%EOF'));
    });

    test('un reporte sin secciones sigue produciendo un PDF', () async {
      const vacio = MsgqReport(title: 'Vacio', subtitle: 'Sin datos');
      final bytes = await buildMsgqPdf(vacio);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('una grafica de UN solo punto no revienta el render', () async {
      // Un eje de span cero hacia que la escala dividiera entre cero: el PDF
      // salia con NaN y el documento entero fallaba.
      const report = MsgqReport(
        title: 'Un punto',
        subtitle: '',
        sections: [
          MsgqReportSection(
            title: 'Serie minima',
            chart: MsgqReportChart(
              kind: MsgqChartKind.bars,
              series: [
                MsgqReportSeries(
                  label: 'Unico',
                  points: [MsgqReportPoint('01/06', 500)],
                ),
              ],
            ),
          ),
        ],
      );
      final bytes = await buildMsgqPdf(report);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('una grafica sin puntos no revienta el render', () async {
      const report = MsgqReport(
        title: 'Sin serie',
        subtitle: '',
        sections: [
          MsgqReportSection(
            title: 'Serie vacia',
            chart: MsgqReportChart(kind: MsgqChartKind.lines, series: []),
          ),
        ],
      );
      final bytes = await buildMsgqPdf(report);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group('CSV', () {
    test('incluye TODAS las filas aunque el PDF las recorte', () {
      // maxRows es 3, pero el CSV es el que se abre para revisar el detalle.
      final csv = buildMsgqCsv(_sample(rows: 10));
      for (var i = 0; i < 10; i++) {
        expect(csv, contains('Producto $i'));
      }
    });

    test('escapa comas y comillas', () {
      const report = MsgqReport(
        title: 'X',
        subtitle: '',
        sections: [
          MsgqReportSection(
            title: 'T',
            table: MsgqReportTable(
              headers: ['A', 'B'],
              rows: [
                ['con, coma', 'con "comillas"'],
              ],
            ),
          ),
        ],
      );
      final csv = buildMsgqCsv(report);
      expect(csv, contains('"con, coma"'));
      expect(csv, contains('"con ""comillas"""'));
    });

    test('lleva BOM para que Excel no rompa los acentos', () {
      final csv = buildMsgqCsv(_sample());
      expect(csv.codeUnitAt(0), 0xFEFF);
    });

    test('arrastra las salvedades del reporte', () {
      expect(buildMsgqCsv(_sample()), contains('Una salvedad del dato.'));
    });
  });

  group('constructores por modulo', () {
    test('el reporte de tanques lleva KPIs, grafica y tablas', () {
      final analytics = TankAnalytics(
        movements: [
          Movement(
            id: 'a',
            kind: MovementKind.dispense,
            equipmentId: 'EX01',
            product: 'Diesel',
            tank: 'T1',
            volume: 500,
            updatedAt: DateTime.utc(2026, 6, 1),
          ),
          Movement(
            id: 'b',
            kind: MovementKind.delivery,
            product: 'Diesel',
            tank: 'T1',
            volume: 20000,
            updatedAt: DateTime.utc(2026, 6, 2),
          ),
        ],
        reconciliations: [
          Reconciliation(
            id: 'r1',
            tank: 'T1',
            periodEnd: DateTime.utc(2026, 6, 2),
            openingStock: 10000,
            closingStock: 9000,
            inflow: 0,
            outflow: 900,
            product: 'Diesel',
          ),
        ],
      );
      final report =
          buildTankReport(analytics, scope: 'Ultimos 90 dias');
      expect(report.title, 'Tanques y consumo');
      expect(report.subtitle, 'Ultimos 90 dias');
      expect(report.kpis, isNotEmpty);
      expect(report.sections.map((s) => s.title),
          contains('Reconciliacion por tanque'));
      // La grafica de consumo existe y trae el punto del despacho.
      final chart = report.sections.first.chart!;
      expect(chart.kind, MsgqChartKind.bars);
      expect(chart.series.single.points, hasLength(1));
    });

    test('el reporte se puede convertir a PDF de punta a punta', () async {
      final analytics = TankAnalytics(movements: [
        Movement(
          id: 'a',
          kind: MovementKind.dispense,
          product: 'Diesel',
          tank: 'T1',
          volume: 500,
          updatedAt: DateTime.utc(2026, 6, 1),
        ),
      ]);
      final bytes =
          await buildMsgqPdf(buildTankReport(analytics, scope: 'Todo'));
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group('formatos', () {
    test('cada formato conoce su extension y su mime type', () {
      expect(MsgqExportFormat.pdf.extension, 'pdf');
      expect(MsgqExportFormat.pdf.mimeType, 'application/pdf');
      expect(MsgqExportFormat.csv.extension, 'csv');
      expect(MsgqExportFormat.csv.mimeType, 'text/csv');
    });
  });
}
