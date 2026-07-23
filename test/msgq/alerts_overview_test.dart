import 'package:adapt_mac_notifier/src/msgq/analytics/alerts_overview.dart';
import 'package:flutter_test/flutter_test.dart';

AlertCategory cat(
  String title,
  int count,
  AlertSeverity severity,
) =>
    AlertCategory(
      title: title,
      count: count,
      severity: severity,
      module: AlertModule.sfl,
    );

void main() {
  group('AlertsOverview', () {
    test('ordena por gravedad y luego por conteo', () {
      final overview = AlertsOverview.of([
        cat('Info alto', 50, AlertSeverity.info),
        cat('Advertencia', 3, AlertSeverity.warning),
        cat('Critico bajo', 1, AlertSeverity.critical),
        cat('Critico alto', 9, AlertSeverity.critical),
      ]);
      expect(overview.categories.map((c) => c.title), [
        'Critico alto', // criticas primero, mayor conteo arriba
        'Critico bajo',
        'Advertencia',
        'Info alto',
      ]);
    });

    test('separa el conteo critico del de advertencia', () {
      final overview = AlertsOverview.of([
        cat('a', 3, AlertSeverity.critical),
        cat('b', 2, AlertSeverity.critical),
        cat('c', 5, AlertSeverity.warning),
        cat('d', 4, AlertSeverity.info),
      ]);
      expect(overview.criticalCount, 5);
      expect(overview.warningCount, 5);
      expect(overview.totalCount, 14);
      expect(overview.activeCategories, 4);
    });

    test('las categorias en cero no cuentan como activas', () {
      final overview = AlertsOverview.of([
        cat('activa', 2, AlertSeverity.critical),
        cat('limpia', 0, AlertSeverity.warning),
      ]);
      expect(overview.active.map((c) => c.title), ['activa']);
      // Pero siguen en categories, para poder mostrarlas con "ver limpias".
      expect(overview.categories, hasLength(2));
      expect(overview.activeCategories, 1);
    });

    test('todo limpio da conteos en cero', () {
      final overview = AlertsOverview.of([
        cat('a', 0, AlertSeverity.critical),
        cat('b', 0, AlertSeverity.warning),
      ]);
      expect(overview.totalCount, 0);
      expect(overview.active, isEmpty);
    });
  });
}
