/// Piezas visuales compartidas por las pantallas MSGQ.
///
/// Sin libreria de graficas: las series se dibujan con barras proporcionales
/// hechas a mano. Es deliberado — meter una dependencia de charting por cuatro
/// vistas cargaria el bundle y, en una pantalla de telefono, una barra con su
/// cifra al lado se lee mejor que un eje comprimido a 300 px de ancho.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Tarjeta de indicador: un numero grande con su etiqueta.
class MsgqKpiCard extends StatelessWidget {
  const MsgqKpiCard({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.emphasis,
  });

  final String label;
  final String value;
  final String? hint;

  /// Color de acento (p. ej. rojo para un descuadre). `null` = color del tema.
  final Color? emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: emphasis,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Fila de KPIs con scroll horizontal (en un telefono nunca caben todos).
class MsgqKpiRow extends StatelessWidget {
  const MsgqKpiRow({super.key, required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: cards),
      );
}

/// Bloque titulado.
class MsgqSection extends StatelessWidget {
  const MsgqSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Un dato de una barra.
class MsgqBar {
  const MsgqBar({
    required this.label,
    required this.value,
    this.caption,
    this.color,
  });

  final String label;
  final double value;

  /// Texto secundario a la derecha (p. ej. "142 despachos").
  final String? caption;
  final Color? color;
}

/// Lista de barras proporcionales al mayor valor.
///
/// Los valores negativos se dibujan con su magnitud y se marcan con el color de
/// error: en un flujo neto o un descuadre, el signo es justo lo que importa.
class MsgqBarList extends StatelessWidget {
  const MsgqBarList({
    super.key,
    required this.bars,
    this.maxItems = 12,
    this.valueFormatter,
    this.emptyMessage = 'Sin datos en el periodo.',
  });

  final List<MsgqBar> bars;
  final int maxItems;
  final String Function(double)? valueFormatter;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (bars.isEmpty) return MsgqEmpty(message: emptyMessage);
    final theme = Theme.of(context);
    final shown = bars.take(maxItems).toList();
    final peak = shown
        .map((b) => b.value.abs())
        .fold<double>(0, (acc, v) => v > acc ? v : acc);
    final format = valueFormatter ?? formatLitres;
    return Column(
      children: shown.map((bar) {
        final fraction = peak == 0 ? 0.0 : (bar.value.abs() / peak);
        final color = bar.color ??
            (bar.value < 0 ? theme.colorScheme.error : theme.colorScheme.primary);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(bar.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium),
                  ),
                  const SizedBox(width: 8),
                  Text(format(bar.value),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: fraction.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              if (bar.caption != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(bar.caption!,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

/// Mensaje de "aqui no hay nada", con su motivo.
///
/// Nunca se deja una tabla vacia sin explicacion: en una auditoria, "no hay
/// datos" y "no hay anomalias" son conclusiones opuestas.
class MsgqEmpty extends StatelessWidget {
  const MsgqEmpty({super.key, required this.message, this.icon});

  final String message;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          Icon(icon ?? Icons.inbox_outlined,
              size: 32, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// Banner de error que NO reemplaza al contenido: los datos replicados siguen
/// siendo validos aunque la ultima sincronizacion fallara.
class MsgqErrorBanner extends StatelessWidget {
  const MsgqErrorBanner({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 18, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onErrorContainer)),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Reintentar')),
          ],
        ),
      ),
    );
  }
}

// -- formateo ----------------------------------------------------------------

final NumberFormat _litres = NumberFormat('#,##0.0');
final NumberFormat _integer = NumberFormat('#,##0');
final DateFormat _day = DateFormat('dd/MM');
final DateFormat _month = DateFormat('MM/yyyy');
final DateFormat _dayTime = DateFormat('dd/MM/yyyy HH:mm');

String formatLitres(double value) => '${_litres.format(value)} L';
String formatCount(num value) => _integer.format(value);
String formatPercent(double? value) =>
    value == null ? '—' : '${_litres.format(value)} %';
String formatDay(DateTime value) => _day.format(value.toLocal());
String formatMonth(DateTime value) => _month.format(value.toLocal());
String formatDateTime(DateTime? value) =>
    value == null ? '—' : _dayTime.format(value.toLocal());
