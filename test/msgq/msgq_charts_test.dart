import 'package:adapt_mac_notifier/src/msgq/ui/msgq_charts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ancho de un telefono estrecho: es donde una grafica desborda o le colisionan
/// las etiquetas, no en el emulador de tablet.
const Size _phone = Size(360, 640);

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(useMaterial3: true, brightness: brightness),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

List<MsgqPoint> _series(int days, {double base = 60}) => List.generate(
      days,
      (i) => MsgqPoint(
        DateTime.utc(2026, 6, 1).add(Duration(days: i)),
        base + (i % 7) * 2.0,
      ),
    );

/// Fija el lienzo al tamano de un telefono estrecho. Un desbordamiento de
/// layout se reporta como excepcion, asi que que el test falle por eso es justo
/// lo que se quiere.
void asPhone(WidgetTester tester) {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('paleta', () {
    testWidgets('asigna color por clave ordenada, no por posicion en la lista',
        (tester) async {
      asPhone(tester);
      late Map<String, Color> todas;
      late Map<String, Color> filtradas;
      await tester.pumpWidget(_host(Builder(builder: (context) {
        todas = MsgqPalette.assign(context, ['T3', 'T1', 'T2']);
        // La vista filtra y deja solo dos: los supervivientes NO deben cambiar
        // de color.
        filtradas = MsgqPalette.assign(context, ['T1', 'T3']);
        return const SizedBox.shrink();
      })));
      expect(todas['T1'], isNot(todas['T2']));
      expect(filtradas['T1'], todas['T1']);
      // T3 SI cambia, porque su posicion en el conjunto ordenado cambio: por eso
      // el mapa se construye con el conjunto COMPLETO en las pantallas.
      expect(todas.keys.toList()..sort(), ['T1', 'T2', 'T3']);
    });

    testWidgets('el modo oscuro usa sus propios pasos, no los claros',
        (tester) async {
      asPhone(tester);
      late List<Color> claros;
      late List<Color> oscuros;
      // Ambos modos en UN arbol: asi cada Builder lee el Theme que lo envuelve,
      // sin depender de que un segundo pumpWidget reconstruya el anterior.
      await tester.pumpWidget(_host(Column(children: [
        Theme(
          data: ThemeData(brightness: Brightness.light),
          child: Builder(builder: (context) {
            claros = MsgqPalette.of(context);
            return const SizedBox.shrink();
          }),
        ),
        Theme(
          data: ThemeData(brightness: Brightness.dark),
          child: Builder(builder: (context) {
            oscuros = MsgqPalette.of(context);
            return const SizedBox.shrink();
          }),
        ),
      ])));
      expect(claros.first, isNot(oscuros.first));
      expect(claros.length, oscuros.length);
    });
  });

  group('serie temporal', () {
    testWidgets('renderiza una serie sin desbordar', (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqTimeSeriesChart(
        series: [MsgqSeries(label: 'EX01', points: _series(90))],
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Una sola serie no lleva leyenda: el titulo de la seccion ya la nombra.
      expect(find.text('EX01'), findsNothing);
    });

    testWidgets('con dos o mas series siempre hay leyenda con texto',
        (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqTimeSeriesChart(
        series: [
          MsgqSeries(label: 'MER.13', points: _series(30)),
          MsgqSeries(label: 'MER.14', points: _series(30, base: 40)),
        ],
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('MER.13'), findsOneWidget);
      expect(find.text('MER.14'), findsOneWidget);
    });

    testWidgets('pasado el tope de series no se ciclan colores: se avisa',
        (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqTimeSeriesChart(
        series: [
          for (var i = 0; i < MsgqPalette.maxSeries + 3; i++)
            MsgqSeries(label: 'T$i', points: _series(10, base: 10.0 * i + 5)),
        ],
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('+3 mas'), findsOneWidget);
      // Las que no caben no se dibujan, en vez de repetir un hue ya usado.
      expect(find.text('T${MsgqPalette.maxSeries + 2}'), findsNothing);
    });

    testWidgets('dibuja la banda de referencia con su etiqueta', (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqTimeSeriesChart(
        series: [MsgqSeries(label: 'EX01', points: _series(20))],
        band: const MsgqReferenceBand(
          value: 60,
          spread: 4,
          label: 'Base Excavadoras',
        ),
        valueFormatter: (v) => '${v.toStringAsFixed(1)} L/h',
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Base Excavadoras'), findsOneWidget);
      expect(find.textContaining('±'), findsOneWidget);
    });

    testWidgets('una serie plana no revienta el rango del eje', (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqTimeSeriesChart(
        series: [
          MsgqSeries(
            label: 'Plano',
            points: List.generate(
              10,
              (i) => MsgqPoint(
                  DateTime.utc(2026, 6, 1).add(Duration(days: i)), 42),
            ),
          ),
        ],
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('sin datos muestra el motivo, no un lienzo vacio',
        (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(const MsgqTimeSeriesChart(
        series: [MsgqSeries(label: 'X', points: [])],
        emptyMessage: 'Sin lecturas de stock en el rango.',
      )));
      await tester.pumpAndSettle();
      expect(find.text('Sin lecturas de stock en el rango.'), findsOneWidget);
    });
  });

  group('barras por periodo', () {
    testWidgets('renderiza muchas barras sin desbordar', (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqPeriodBarChart(points: _series(90))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('acepta valores negativos (un neto puede ser negativo)',
        (tester) async {
      asPhone(tester);
      await tester.pumpWidget(_host(MsgqPeriodBarChart(
        points: [
          MsgqPoint(DateTime.utc(2026, 6, 1), 500),
          MsgqPoint(DateTime.utc(2026, 6, 2), -300),
          MsgqPoint(DateTime.utc(2026, 6, 3), 100),
        ],
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('sin datos muestra el motivo', (tester) async {
      asPhone(tester);
      await tester.pumpWidget(
          _host(const MsgqPeriodBarChart(points: [])));
      await tester.pumpAndSettle();
      expect(find.textContaining('Sin datos'), findsOneWidget);
    });
  });
}
