/// Panel consolidado de alertas — equivalente al `combine` / `alert_summary` /
/// `compute_kpis` de `msgq/core/alerts.py`.
///
/// Diferencia deliberada con el escritorio: alli `alerts.py` REIMPLEMENTA cada
/// detector para juntarlos en una tabla. Aqui NO se reimplementa nada — los
/// detectores YA son los modulos portados (burn rate, hardware, actividad,
/// producto, SFL, tag hopping, desviacion de volumen, salud de consolas). Este
/// panel solo los AGREGA: recorre lo que cada auditor ya calculo y arma una
/// vista unica de "que esta mal ahora mismo", con enlace a cada modulo.
///
/// Que sea agregacion y no deteccion es lo que garantiza que el conteo del panel
/// y el de cada pantalla nunca discrepen: son el mismo calculo, leido una vez.
///
/// Este archivo solo define los MODELOS; el ensamblaje vive en el provider
/// (`alertsOverviewProvider`), porque componer las auditorias es leer otros
/// providers de Riverpod.
library;

/// Gravedad de una fila del panel. El orden de declaracion es el de atencion.
enum AlertSeverity {
  critical('Critico'),
  warning('Advertencia'),
  info('Informativo');

  const AlertSeverity(this.label);

  final String label;
}

/// Una categoria de alerta, con su conteo y a que modulo lleva.
class AlertCategory {
  const AlertCategory({
    required this.title,
    required this.count,
    required this.severity,
    required this.module,
    this.detail,
  });

  /// Nombre de la categoria (p. ej. "Burn rate anomalo").
  final String title;

  /// Cuantos hallazgos hay. `0` = la categoria esta limpia (se puede ocultar).
  final int count;

  final AlertSeverity severity;

  /// Modulo al que pertenece, para navegar al pulsar.
  final AlertModule module;

  /// Texto secundario opcional (p. ej. "3 cruces de clase").
  final String? detail;

  bool get isActive => count > 0;
}

/// Los modulos a los que puede saltar el panel.
enum AlertModule {
  burnRate,
  hardware,
  activity,
  product,
  sfl,
  tagHopping,
  volumeDeviation,
  macHealth,
  dataQuality,
}

/// Resumen ejecutivo del panel.
class AlertsOverview {
  const AlertsOverview({required this.categories});

  /// Todas las categorias, activas y limpias, ya ordenadas por gravedad y
  /// conteo. La UI decide si muestra las limpias.
  final List<AlertCategory> categories;

  List<AlertCategory> get active =>
      categories.where((c) => c.isActive).toList(growable: false);

  int get criticalCount => active
      .where((c) => c.severity == AlertSeverity.critical)
      .fold(0, (acc, c) => acc + c.count);

  int get warningCount => active
      .where((c) => c.severity == AlertSeverity.warning)
      .fold(0, (acc, c) => acc + c.count);

  int get totalCount => active.fold(0, (acc, c) => acc + c.count);

  /// Categorias distintas con al menos un hallazgo.
  int get activeCategories => active.length;

  /// Ordena las categorias por gravedad y luego por conteo descendente. Se
  /// aplica al construir, para que "lo mas grave primero" sea invariante.
  static AlertsOverview of(List<AlertCategory> categories) {
    final sorted = categories.toList()
      ..sort((a, b) {
        final bySeverity = a.severity.index.compareTo(b.severity.index);
        if (bySeverity != 0) return bySeverity;
        return b.count.compareTo(a.count);
      });
    return AlertsOverview(categories: List.unmodifiable(sorted));
  }
}
