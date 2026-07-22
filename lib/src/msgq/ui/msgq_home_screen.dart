/// Hub de los modulos MSGQ — equivalente movil de la barra de botones que abre
/// las ventanas secundarias en el dashboard de escritorio (`MainWindow`).
///
/// Es tambien el unico punto donde se dispara una sincronizacion completa: las
/// pantallas hijas leen de la replica y solo ofrecen refrescar, para que abrir
/// un modulo nunca cueste una descarga sorpresa en datos moviles.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/l10n.dart';
import '../../state/providers.dart';
import '../data/replica_database.dart';
import '../state/msgq_providers.dart';
import 'equipment_screen.dart';
import 'msgq_filters.dart';
import 'msgq_widgets.dart';
import 'tank_screen.dart';

class MsgqHomeScreen extends ConsumerWidget {
  const MsgqHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final l = L10n(settings.languageCode);
    final dataset = ref.watch(msgqDatasetProvider);
    final syncError = ref.watch(msgqSyncErrorProvider);
    final counts = ref.watch(replicaCountsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l.t('Analitica MSGQ', 'MSGQ analytics')),
        actions: [
          IconButton(
            tooltip: l.t('Sincronizar replica', 'Sync replica'),
            icon: const Icon(Icons.sync),
            onPressed: () => ref.read(msgqDatasetProvider.notifier).syncNow(),
          ),
        ],
      ),
      body: !settings.isConfigured
          ? MsgqEmpty(
              icon: Icons.key_off_outlined,
              message: l.t(
                'Falta el token de la API.\nConfiguralo para poder replicar '
                    'movimientos, tanques y equipos.',
                'API token missing.\nSet it up to replicate movements, tanks '
                    'and equipment.',
              ),
            )
          : ListView(
              children: [
                if (syncError != null)
                  MsgqErrorBanner(
                    message: syncError,
                    onRetry: () =>
                        ref.read(msgqDatasetProvider.notifier).syncNow(),
                  ),
                const MsgqSyncStatusBar(),
                const Divider(height: 1),
                _ModuleTile(
                  icon: Icons.local_gas_station_outlined,
                  title: l.t('Tanques y consumo', 'Tanks & consumption'),
                  subtitle: l.t(
                    'Consumo por producto y tanque, burn rate, flujo y '
                        'reconciliacion de stock',
                    'Consumption by product and tank, burn rate, flow and '
                        'stock reconciliation',
                  ),
                  onTap: () => _open(context, const TankScreen()),
                ),
                _ModuleTile(
                  icon: Icons.precision_manufacturing_outlined,
                  title: l.t('Equipos', 'Equipment'),
                  subtitle: l.t(
                    'KPIs de flota, transiciones de estado, RFID y log de '
                        'auditoria',
                    'Fleet KPIs, status transitions, RFID and audit log',
                  ),
                  onTap: () => _open(context, const EquipmentScreen()),
                ),
                const Divider(height: 24),
                _ReplicaPanel(counts: counts, dataset: dataset),
              ],
            ),
    );
  }

  void _open(BuildContext context, Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: ListTile(
          leading: Icon(icon, size: 28),
          title: Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          isThreeLine: true,
          onTap: onTap,
        ),
      );
}

/// Panel de diagnostico: cuanto hay replicado por tabla.
///
/// No es adorno: si una pantalla sale vacia, esto responde de inmediato si el
/// problema es "no hay datos" o "el tenant no expone esa conexion".
class _ReplicaPanel extends StatelessWidget {
  const _ReplicaPanel({required this.counts, required this.dataset});

  final AsyncValue<Map<String, int>> counts;
  final AsyncValue<dynamic> dataset;

  @override
  Widget build(BuildContext context) {
    const labels = {
      ReplicaTable.movements: 'Movimientos',
      ReplicaTable.equipment: 'Equipos',
      ReplicaTable.tanks: 'Tanques',
      ReplicaTable.reconciliations: 'Reconciliaciones',
      ReplicaTable.changeEvents: 'Eventos de auditoria',
      ReplicaTable.consumptionLimits: 'Limites SFL',
    };
    return MsgqSection(
      title: 'Replica local',
      subtitle: 'Historico guardado en el dispositivo',
      child: counts.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => MsgqEmpty(message: 'No se pudo leer la replica: $e'),
        data: (values) => Column(
          children: labels.entries
              .map((e) => ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(e.value),
                    trailing: Text(formatCount(values[e.key] ?? 0)),
                  ))
              .toList(),
        ),
      ),
    );
  }
}
