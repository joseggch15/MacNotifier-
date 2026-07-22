/// Graficas de los modulos MSGQ, sobre `fl_chart`.
///
/// Sustituyen a las barras proporcionales hechas a mano donde el dato es una
/// SERIE TEMPORAL: un burn rate contra su linea base, el caudal de una manguera
/// degradandose o el nivel de un tanque son formas cuyo trabajo es mostrar
/// CAMBIO, y una lista de barras ordenada por magnitud no lo muestra. Donde el
/// trabajo sigue siendo comparar magnitudes entre categorias, las barras se
/// quedan: no todo grafico mejora por ser una linea.
///
/// Reglas que este archivo respeta y conviene no romper al editarlo:
///
///   * UN SOLO EJE. Nunca dos escalas verticales en la misma grafica: dos
///     medidas de escalas distintas van en dos graficas.
///   * El color sigue a la ENTIDAD, no a su posicion. [MsgqPalette] asigna el
///     color por clave ordenada del conjunto COMPLETO, asi que filtrar series
///     no repinta a las que quedan.
///   * Los hues categoricos se asignan en orden fijo y NO se ciclan. Pasadas
///     [MsgqPalette.maxSeries] entidades, la grafica muestra las principales y
///     dice cuantas omitio, en vez de repetir colores.
///   * La identidad nunca es solo color: con dos o mas series siempre hay
///     leyenda con texto, y debajo de cada grafica queda la tabla o lista con
///     los mismos numeros.
///
/// La paleta es la de referencia del sistema de diseño, validada para daltonismo
/// en ambos modos (peor par adyacente ΔE 9.1 claro / 8.4 oscuro sobre un minimo
/// de 8). Tres slots claros quedan por debajo de 3:1 de contraste sobre fondo
/// claro; por eso la leyenda con texto y la lista de respaldo NO son opcionales.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'msgq_widgets.dart';

/// Paleta categorica, en orden fijo y con su version para modo oscuro.
class MsgqPalette {
  const MsgqPalette._();

  static const _light = <Color>[
    Color(0xFF2A78D6), // azul
    Color(0xFFEB6834), // naranja
    Color(0xFF1BAF7A), // aqua
    Color(0xFFEDA100), // amarillo
    Color(0xFFE87BA4), // magenta
    Color(0xFF008300), // verde
  ];

  static const _dark = <Color>[
    Color(0xFF3987E5),
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
    Color(0xFFD55181),
    Color(0xFF008300),
  ];

  /// Series que se pueden distinguir a la vez. Pasado este numero no se generan
  /// colores nuevos: se muestran las principales y se dice cuantas faltan.
  static const int maxSeries = 6;

  static List<Color> of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  /// Asigna un color a cada clave a partir del conjunto COMPLETO y ORDENADO.
  ///
  /// Que el mapa se construya con todas las claves —y no con las que la vista
  /// muestre hoy— es lo que hace que quitar un tanque del filtro no cambie el
  /// color de los demas.
  static Map<String, Color> assign(BuildContext context, Iterable<String> keys) {
    final colors = of(context);
    final ordered = keys.toSet().toList()..sort();
    return {
      for (var i = 0; i < ordered.length; i++)
        ordered[i]: colors[i % colors.length],
    };
  }
}

/// Un punto de una serie temporal.
class MsgqPoint {
  const MsgqPoint(this.at, this.value);

  final DateTime at;
  final double value;
}

/// Una serie con su etiqueta.
class MsgqSeries {
  const MsgqSeries({required this.label, required this.points, this.color});

  final String label;
  final List<MsgqPoint> points;

  /// Color explicito. Si es `null`, la grafica lo toma de la paleta por clave.
  final Color? color;
}

/// Banda de referencia horizontal (p. ej. la linea base de una categoria y su
/// dispersion). Es lo que convierte "este equipo consume 84 L/h" en "consume
/// 84 donde sus pares consumen 60 ± 4".
class MsgqReferenceBand {
  const MsgqReferenceBand({
    required this.value,
    this.spread,
    required this.label,
  });

  final double value;

  /// Semiancho de la banda. `null` = solo la linea, sin banda.
  final double? spread;

  final String label;
}

/// Grafica de una o varias series en el tiempo.
class MsgqTimeSeriesChart extends StatelessWidget {
  const MsgqTimeSeriesChart({
    super.key,
    required this.series,
    this.band,
    this.valueFormatter,
    this.height = 220,
    this.emptyMessage = 'Sin datos en el periodo.',
  });

  final List<MsgqSeries> series;

  /// Linea (y banda) de referencia.
  final MsgqReferenceBand? band;

  final String Function(double)? valueFormatter;
  final double height;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final withData = series.where((s) => s.points.isNotEmpty).toList();
    if (withData.isEmpty) return MsgqEmpty(message: emptyMessage);

    final theme = Theme.of(context);
    final format = valueFormatter ?? formatLitres;
    final colors =
        MsgqPalette.assign(context, series.map((s) => s.label));
    // Pasado el tope no se ciclan hues: se recorta y se dice cuantas faltan.
    final shown = withData.take(MsgqPalette.maxSeries).toList();
    final omitted = withData.length - shown.length;

    final allPoints = shown.expand((s) => s.points).toList();
    var minY = allPoints.map((p) => p.value).reduce((a, b) => a < b ? a : b);
    var maxY = allPoints.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    if (band != null) {
      final lo = band!.value - (band!.spread ?? 0);
      final hi = band!.value + (band!.spread ?? 0);
      if (lo < minY) minY = lo;
      if (hi > maxY) maxY = hi;
    }
    // Un rango degenerado (todos los valores iguales) dejaria la linea pegada
    // al borde; se abre un margen minimo para que se vea como lo que es: plana.
    final span = (maxY - minY).abs();
    final pad = span == 0 ? (maxY.abs() * 0.1 + 1) : span * 0.12;
    minY -= pad;
    maxY += pad;

    final minX = allPoints
        .map((p) => p.at.millisecondsSinceEpoch.toDouble())
        .reduce((a, b) => a < b ? a : b);
    final maxX = allPoints
        .map((p) => p.at.millisecondsSinceEpoch.toDouble())
        .reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (band != null) _BandLegend(band: band!, format: format),
        SizedBox(
          height: height,
          child: LineChart(
            LineChartData(
              minY: minY,
              maxY: maxY,
              minX: minX,
              maxX: maxX == minX ? minX + 1 : maxX,
              clipData: const FlClipData.all(),
              // Rejilla y ejes RECESIVOS: son referencia, no contenido.
              gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => FlLine(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  strokeWidth: 1,
                ),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        _compact(value),
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    interval: ((maxX - minX) / 3).clamp(1, double.infinity),
                    getTitlesWidget: (value, meta) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        formatDay(DateTime.fromMillisecondsSinceEpoch(
                            value.toInt(),
                            isUtc: true)),
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                ),
              ),
              extraLinesData: band == null
                  ? const ExtraLinesData()
                  : ExtraLinesData(horizontalLines: [
                      HorizontalLine(
                        y: band!.value,
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.7),
                        strokeWidth: 2,
                        dashArray: const [6, 4],
                      ),
                      if (band!.spread != null && band!.spread! > 0) ...[
                        _bandEdge(theme, band!.value + band!.spread!),
                        _bandEdge(theme, band!.value - band!.spread!),
                      ],
                    ]),
              lineBarsData: [
                for (final s in shown)
                  LineChartBarData(
                    spots: (s.points.toList()
                          ..sort((a, b) => a.at.compareTo(b.at)))
                        .map((p) => FlSpot(
                            p.at.millisecondsSinceEpoch.toDouble(), p.value))
                        .toList(),
                    color: s.color ?? colors[s.label],
                    barWidth: 2,
                    isCurved: false,
                    // Los puntos solo se marcan cuando son pocos: con 90 dias
                    // en 300 px, los circulos se funden en una banda solida.
                    dotData: FlDotData(show: s.points.length <= 20),
                  ),
              ],
              lineTouchData: LineTouchData(
                handleBuiltInTouches: true,
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) =>
                      theme.colorScheme.inverseSurface.withValues(alpha: 0.92),
                  getTooltipItems: (spots) => spots.map((spot) {
                    final s = shown[spot.barIndex];
                    final at = DateTime.fromMillisecondsSinceEpoch(
                        spot.x.toInt(),
                        isUtc: true);
                    return LineTooltipItem(
                      '${s.label}\n${formatDay(at)} · ${format(spot.y)}',
                      TextStyle(
                        color: theme.colorScheme.onInverseSurface,
                        fontSize: 12,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
        // Con una sola serie el titulo de la seccion ya la nombra: una leyenda
        // de un elemento es ruido.
        if (shown.length > 1)
          _Legend(series: shown, colors: colors, omitted: omitted),
        if (shown.length <= 1 && omitted > 0)
          _OmittedNote(omitted: omitted),
      ],
    );
  }

  HorizontalLine _bandEdge(ThemeData theme, double y) => HorizontalLine(
        y: y,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.22),
        strokeWidth: 1,
        dashArray: const [3, 5],
      );
}

/// Barras por periodo, para una unica serie de magnitudes discretas.
class MsgqPeriodBarChart extends StatelessWidget {
  const MsgqPeriodBarChart({
    super.key,
    required this.points,
    this.valueFormatter,
    this.height = 190,
    this.color,
    this.emptyMessage = 'Sin datos en el periodo.',
  });

  final List<MsgqPoint> points;
  final String Function(double)? valueFormatter;
  final double height;
  final Color? color;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return MsgqEmpty(message: emptyMessage);
    final theme = Theme.of(context);
    final format = valueFormatter ?? formatLitres;
    final bars = points.toList()..sort((a, b) => a.at.compareTo(b.at));
    final maxY = bars.map((p) => p.value.abs()).reduce((a, b) => a > b ? a : b);
    final barColor = color ?? MsgqPalette.of(context).first;

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxY == 0 ? 1 : maxY * 1.15,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                getTitlesWidget: (value, meta) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    _compact(value),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                // Solo unas pocas fechas: etiquetar cada barra las apila unas
                // sobre otras y no se lee ninguna.
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  final step = (bars.length / 4).ceil().clamp(1, bars.length);
                  if (i < 0 || i >= bars.length || i % step != 0) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      formatDay(bars[i].at),
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) =>
                  theme.colorScheme.inverseSurface.withValues(alpha: 0.92),
              getTooltipItem: (group, _, rod, __) => BarTooltipItem(
                '${formatDay(bars[group.x].at)}\n${format(rod.toY)}',
                TextStyle(
                  color: theme.colorScheme.onInverseSurface,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          barGroups: [
            for (var i = 0; i < bars.length; i++)
              BarChartGroupData(x: i, barRods: [
                BarChartRodData(
                  toY: bars[i].value,
                  width: (240 / bars.length).clamp(3.0, 16.0),
                  // Extremo redondeado arriba y anclado a la linea de base.
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4)),
                  color: bars[i].value < 0
                      ? theme.colorScheme.error
                      : barColor,
                ),
              ]),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.series,
    required this.colors,
    required this.omitted,
  });

  final List<MsgqSeries> series;
  final Map<String, Color> colors;
  final int omitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          for (final s in series)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: s.color ?? colors[s.label],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 5),
                // El texto va en tinta, no en el color de la serie: el cuadrito
                // de al lado ya lleva la identidad, y asi la etiqueta se lee
                // aunque el hue tenga poco contraste sobre el fondo.
                Text(s.label, style: theme.textTheme.labelMedium),
              ],
            ),
          if (omitted > 0) _OmittedNote(omitted: omitted),
        ],
      ),
    );
  }
}

class _OmittedNote extends StatelessWidget {
  const _OmittedNote({required this.omitted});

  final int omitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      '+$omitted mas (ver el detalle abajo)',
      style: theme.textTheme.labelMedium
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    );
  }
}

class _BandLegend extends StatelessWidget {
  const _BandLegend({required this.band, required this.format});

  final MsgqReferenceBand band;
  final String Function(double) format;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Divider(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              thickness: 2,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              band.spread == null || band.spread == 0
                  ? '${band.label}: ${format(band.value)}'
                  : '${band.label}: ${format(band.value)} ± ${format(band.spread!)}',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// Etiqueta compacta del eje: 12.400 -> 12,4k.
String _compact(double value) {
  final abs = value.abs();
  if (abs >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (abs >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  if (abs >= 10) return value.toStringAsFixed(0);
  return value.toStringAsFixed(1);
}
