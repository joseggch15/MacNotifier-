/// Auditoria de Actividad: equipos fantasma y coherencia
/// actividad <-> combustible. Port de `msgq/core/activity_audit.py`.
///
/// Tres detectores que cruzan el maestro con los despachos y el SMU
/// por-movimiento, para encontrar inconsistencias entre lo que el FMS dice que
/// opera y el combustible que realmente fluye:
///
///   1. EQUIPOS FANTASMA. 'In Service' sin despachos en >= N dias, o que nunca
///      despacharon en todo el historico replicado. Figuran operativos pero no
///      consumen: distorsionan los KPIs de disponibilidad.
///   2. TRABAJA SIN REPOSTAR. Entre dos lecturas de SMU, el avance por el burn
///      rate tipico del equipo estima lo quemado. Si el faltante contra TODO lo
///      registrado en la ventana supera un tanque con margen, el equipo no pudo
///      operar asi: recibio combustible por fuera del FMS.
///   3. REPOSTADO SIN OPERAR. Rachas de despachos cuyo SMU no avanza. Si los
///      litros acumulados superan el SFL, el tanque no pudo absorberlos sin
///      operar. La firma se solapa con un sensor dañado —que ya audita la salud
///      de hardware—; aqui se agrega el angulo de VOLUMEN, que es lo que
///      convierte la falla tecnica en riesgo de fraude.
///
/// Los detectores 2 y 3 requieren `smuValue` por despacho; los equipos sin SMU
/// solo participan del detector 1.
///
/// Dart puro: sin dependencias de Flutter, testeable sin emulador.
library;

import '../domain/equipment.dart';
import '../domain/fms_vocabulary.dart';
import '../domain/movement.dart';
import '../domain/node_parsing.dart';
import 'burn_rate.dart';
import 'grouping.dart';
import 'sfl_resolution.dart';

/// Por que un equipo figura como fantasma.
enum IdleClass {
  neverDispensed('Nunca despacho'),
  idle('Inactivo');

  const IdleClass(this.label);

  final String label;
}

/// Un equipo 'In Service' que no consume.
class IdleAsset {
  const IdleAsset({
    required this.equipmentId,
    this.description,
    this.category,
    this.group,
    this.department,
    this.status,
    this.lastDispense,
    this.daysIdle,
    required this.historicDispenses,
    required this.idleClass,
  });

  final String equipmentId;
  final String? description;
  final String? category;
  final String? group;
  final String? department;
  final String? status;

  /// `null` = nunca despacho en el historico replicado.
  final DateTime? lastDispense;

  /// `null` cuando nunca despacho: su inactividad no tiene principio conocido.
  final double? daysIdle;

  final int historicDispenses;
  final IdleClass idleClass;

  bool get isCritical =>
      idleClass == IdleClass.neverDispensed ||
      (daysIdle ?? 0) >= idleAssetDaysCritical;
}

/// Un intervalo en el que el equipo trabajo mas de lo que su tanque permite sin
/// repostar dentro del FMS.
class UnfueledActivity {
  const UnfueledActivity({
    required this.equipmentId,
    this.equipmentDescription,
    this.category,
    required this.from,
    required this.to,
    required this.days,
    required this.smuDelta,
    this.smuType,
    required this.typicalBurnRate,
    required this.expectedLitres,
    required this.dispensedLitres,
    required this.sfl,
    required this.unregisteredLitres,
    this.sourceId,
  });

  final String equipmentId;
  final String? equipmentDescription;
  final String? category;
  final DateTime from;
  final DateTime to;
  final double days;
  final double smuDelta;
  final String? smuType;

  /// Mediana del propio equipo; si no alcanza muestras, la de su categoria.
  final double typicalBurnRate;

  /// smuDelta * typicalBurnRate.
  final double expectedLitres;

  /// TODO el combustible registrado al equipo en la ventana, incluidos los
  /// despachos sin lectura de SMU. Contarlo mal aqui era el falso positivo
  /// masivo que el escritorio ya resolvio.
  final double dispensedLitres;

  final double sfl;

  /// Lo esperado menos lo registrado: el combustible que entro por fuera.
  final double unregisteredLitres;

  final String? sourceId;
}

/// Una racha de despachos con el SMU congelado.
class FuelingWithoutActivity {
  const FuelingWithoutActivity({
    required this.equipmentId,
    this.equipmentDescription,
    this.category,
    required this.from,
    required this.to,
    required this.days,
    required this.dispenses,
    required this.litres,
    this.sfl,
    required this.overSfl,
    required this.frozenSmu,
    this.smuType,
  });

  final String equipmentId;
  final String? equipmentDescription;
  final String? category;
  final DateTime from;
  final DateTime to;
  final double days;
  final int dispenses;
  final double litres;
  final double? sfl;

  /// Los litros de la racha exceden el SFL: fisicamente imposible sin operar.
  final bool overSfl;

  final double frozenSmu;
  final String? smuType;
}

class ActivityKpis {
  const ActivityKpis({
    required this.equipmentInService,
    required this.idleAssets,
    required this.neverDispensed,
    required this.idlePctOfFleet,
    required this.unfueledIntervals,
    required this.unregisteredLitres,
    required this.frozenRuns,
    required this.runsOverSfl,
  });

  final int equipmentInService;
  final int idleAssets;
  final int neverDispensed;
  final double idlePctOfFleet;
  final int unfueledIntervals;
  final double unregisteredLitres;
  final int frozenRuns;
  final int runsOverSfl;
}

// ===========================================================================
// Auditoria
// ===========================================================================

class ActivityAudit {
  const ActivityAudit._({
    required this.idleAssets,
    required this.unfueled,
    required this.frozen,
    required this.kpis,
    required this.idleDays,
  });

  final List<IdleAsset> idleAssets;
  final List<UnfueledActivity> unfueled;
  final List<FuelingWithoutActivity> frozen;
  final ActivityKpis kpis;

  /// Umbral de dias con el que se calculo la lista de fantasmas.
  final int idleDays;

  static ActivityAudit run({
    required List<Movement> movements,
    List<Equipment> equipment = const [],
    List<ConsumptionLimit> limits = const [],
    int idleDays = idleAssetDays,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now().toUtc();
    final idle = idleAssetsOf(
      equipment: equipment,
      movements: movements,
      now: at,
      minDays: idleDays.toDouble(),
    );
    final sfl = resolveSfl(
      movements: movements,
      limits: limits,
      equipment: equipment,
    );
    final unfueled = unfueledActivityOf(
      movements: movements,
      equipment: equipment,
      sflByEquipment: sfl,
    );
    final frozen = fuelingWithoutActivityOf(
      movements: movements,
      equipment: equipment,
      sflByEquipment: sfl,
    );
    final inService = equipment.where((e) => e.isInService).length;

    return ActivityAudit._(
      idleAssets: idle,
      unfueled: unfueled,
      frozen: frozen,
      idleDays: idleDays,
      kpis: ActivityKpis(
        equipmentInService: inService,
        idleAssets: idle.length,
        neverDispensed:
            idle.where((a) => a.idleClass == IdleClass.neverDispensed).length,
        idlePctOfFleet:
            inService == 0 ? 0 : roundTo(idle.length / inService * 100, 1),
        unfueledIntervals: unfueled.length,
        unregisteredLitres:
            roundTo(sumOf(unfueled, (u) => u.unregisteredLitres), 0),
        frozenRuns: frozen.length,
        runsOverSfl: frozen.where((f) => f.overSfl).length,
      ),
    );
  }
}

// ===========================================================================
// 1. Equipos fantasma
// ===========================================================================

/// Equipos 'In Service' con [minDays] o mas dias sin despachar.
///
/// Con `minDays: 0` devuelve TODOS los equipos en servicio con sus dias de
/// inactividad, para que la vista pueda mover el umbral sin recalcular.
List<IdleAsset> idleAssetsOf({
  required List<Equipment> equipment,
  required List<Movement> movements,
  DateTime? now,
  double minDays = 0,
}) {
  final at = (now ?? DateTime.now()).toUtc();

  final lastByEquipment = <String, DateTime>{};
  final countByEquipment = <String, int>{};
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    final date = m.recordCollectedAt ?? m.updatedAt;
    if (id == null || date == null) continue;
    countByEquipment[id] = (countByEquipment[id] ?? 0) + 1;
    final current = lastByEquipment[id];
    if (current == null || date.isAfter(current)) lastByEquipment[id] = date;
  }

  final seen = <String>{};
  final out = <IdleAsset>[];
  for (final e in equipment) {
    if (!e.isInService) continue;
    final id = realEquipmentId(e.equipmentId);
    if (id == null || !seen.add(id)) continue;
    final last = lastByEquipment[id];
    final days = last == null
        ? null
        : roundTo(at.difference(last).inSeconds / Duration.secondsPerDay, 1);
    // Un equipo que NUNCA despacho siempre entra: su inactividad es infinita,
    // no "menor al umbral".
    if (minDays > 0 && last != null && (days ?? 0) < minDays) continue;
    out.add(IdleAsset(
      equipmentId: id,
      description: e.description,
      category: e.category,
      group: e.group,
      department: e.department,
      status: e.status,
      lastDispense: last,
      daysIdle: days,
      historicDispenses: countByEquipment[id] ?? 0,
      idleClass: last == null ? IdleClass.neverDispensed : IdleClass.idle,
    ));
  }
  out.sort((a, b) {
    // Los que nunca despacharon van primero (inactividad infinita).
    final ad = a.daysIdle ?? double.infinity;
    final bd = b.daysIdle ?? double.infinity;
    final byDays = bd.compareTo(ad);
    return byDays != 0 ? byDays : a.equipmentId.compareTo(b.equipmentId);
  });
  return List.unmodifiable(out);
}

// ===========================================================================
// Pares consecutivos de SMU (insumo de los detectores 2 y 3)
// ===========================================================================

class _SmuPair {
  const _SmuPair({
    required this.equipmentId,
    this.description,
    required this.from,
    required this.to,
    required this.smuPrev,
    required this.smuCurr,
    required this.litresInWindow,
    this.smuType,
    this.sourceId,
  });

  final String equipmentId;
  final String? description;
  final DateTime from;
  final DateTime to;
  final double smuPrev;
  final double smuCurr;

  /// TODO lo despachado en (from, to], con o sin lectura de SMU.
  final double litresInWindow;

  final String? smuType;
  final String? sourceId;

  double get smuDelta => smuCurr - smuPrev;
  double get days => to.difference(from).inSeconds / Duration.secondsPerDay;
}

/// Pares (lectura anterior -> actual) del mismo equipo, INCLUYENDO los de
/// avance cero: a diferencia de las muestras de burn rate, aqui el SMU
/// congelado ES la señal.
///
/// Entre dos lecturas de SMU puede haber despachos SIN SMU. Se acumula TODO el
/// combustible de la ventana; sin eso, esos despachos intermedios contarian
/// como "combustible no registrado" — un falso positivo masivo.
List<_SmuPair> _smuPairs(List<Movement> movements) {
  final byEquipment = <String, List<Movement>>{};
  for (final m in movements) {
    if (!m.isDispense) continue;
    final id = realEquipmentId(m.equipmentId);
    final date = m.recordCollectedAt ?? m.updatedAt;
    final litres = m.volume;
    if (id == null || date == null || litres == null || litres <= 0) continue;
    byEquipment.putIfAbsent(id, () => <Movement>[]).add(m);
  }

  final out = <_SmuPair>[];
  for (final entry in byEquipment.entries) {
    final rows = entry.value
      ..sort((a, b) {
        final ad = a.recordCollectedAt ?? a.updatedAt!;
        final bd = b.recordCollectedAt ?? b.updatedAt!;
        final byDate = ad.compareTo(bd);
        return byDate != 0
            ? byDate
            : (a.smuValue ?? 0).compareTo(b.smuValue ?? 0);
      });

    // Acumulado de litros sobre TODOS los despachos, antes de quedarnos con los
    // que traen lectura de SMU.
    var cumulative = 0.0;
    final withSmu = <({Movement movement, double cumulative})>[];
    for (final m in rows) {
      cumulative += m.volume!;
      if (m.smuValue != null) {
        withSmu.add((movement: m, cumulative: cumulative));
      }
    }

    for (var i = 1; i < withSmu.length; i++) {
      final prev = withSmu[i - 1];
      final curr = withSmu[i];
      out.add(_SmuPair(
        equipmentId: entry.key,
        description: asText(curr.movement.equipmentDescription),
        from: prev.movement.recordCollectedAt ?? prev.movement.updatedAt!,
        to: curr.movement.recordCollectedAt ?? curr.movement.updatedAt!,
        smuPrev: prev.movement.smuValue!,
        smuCurr: curr.movement.smuValue!,
        litresInWindow: curr.cumulative - prev.cumulative,
        smuType: curr.movement.smuType,
        sourceId: curr.movement.id,
      ));
    }
  }
  return out;
}

// ===========================================================================
// 2. Trabaja sin repostar
// ===========================================================================

/// Intervalos en los que el equipo consumio mas de lo que su tanque permite sin
/// repostar dentro del FMS.
List<UnfueledActivity> unfueledActivityOf({
  required List<Movement> movements,
  List<Equipment> equipment = const [],
  Map<String, ResolvedSfl> sflByEquipment = const {},
  double sflFactor = activityUnfueledSflFactor,
}) {
  final pairs = _smuPairs(movements);
  if (pairs.isEmpty) return const [];

  // Burn rate tipico por equipo (mediana de sus intervalos), con la linea base
  // de su categoria como respaldo. Mismas muestras robustas del modulo de burn
  // rate: dos definiciones distintas darian dos verdades sobre el mismo equipo.
  final samples = intervalSamples(movements: movements, equipment: equipment);
  if (samples.isEmpty) return const [];

  final byEquipment = <String, List<double>>{};
  final byCategory = <String, List<double>>{};
  for (final s in samples) {
    byEquipment.putIfAbsent(s.equipmentId, () => <double>[]).add(s.burnRate);
    byCategory.putIfAbsent(s.category, () => <double>[]).add(s.burnRate);
  }
  final ownRate = <String, double>{
    for (final e in byEquipment.entries)
      if (e.value.length >= burnRateMinSamples) e.key: median(e.value)!,
  };
  final categoryRate = <String, double>{
    for (final e in byCategory.entries) e.key: median(e.value)!,
  };
  final categoryById = {
    for (final e in equipment)
      if (realEquipmentId(e.equipmentId) != null && e.category != null)
        realEquipmentId(e.equipmentId)!: e.category!,
  };

  final out = <UnfueledActivity>[];
  for (final p in pairs) {
    if (p.smuDelta < burnRateMinSmuDelta) continue;

    // Plausibilidad fisica: el SMU no puede avanzar mas que el tiempo de pared.
    // Los saltos que lo exceden son lecturas corruptas (dominio de la auditoria
    // de hardware); estimar consumo con ellas inventa litros fantasma.
    final elapsedHours = p.days * 24.0;
    if (elapsedHours <= 0) continue;
    final isHours = (p.smuType ?? '').trim().toLowerCase().startsWith('h');
    final maxRate =
        isHours ? activityMaxSmuPerHourHours : activityMaxSmuPerHourKm;
    if (p.smuDelta > elapsedHours * maxRate) continue;

    // Ventanas acotadas: mas alla del maximo, el burn rate por miles de horas
    // amplifica el error y las brechas de cobertura de SMU dan falsos positivos.
    if (p.days > activityUnfueledMaxGapDays) continue;

    final category = categoryById[p.equipmentId];
    final rate = ownRate[p.equipmentId] ??
        (category == null ? null : categoryRate[category]);
    if (rate == null || rate <= 0) continue;

    final sfl = sflByEquipment[p.equipmentId]?.sfl;
    if (sfl == null) continue;

    final expected = p.smuDelta * rate;
    final missing = expected - p.litresInWindow;
    if (missing <= sfl * sflFactor) continue;

    out.add(UnfueledActivity(
      equipmentId: p.equipmentId,
      equipmentDescription: p.description,
      category: category,
      from: p.from,
      to: p.to,
      days: roundTo(p.days, 1),
      smuDelta: roundTo(p.smuDelta, 1),
      smuType: p.smuType,
      typicalBurnRate: roundTo(rate, 2),
      expectedLitres: roundTo(expected, 0),
      dispensedLitres: roundTo(p.litresInWindow, 1),
      sfl: sfl,
      unregisteredLitres: roundTo(missing, 0),
      sourceId: p.sourceId,
    ));
  }
  out.sort((a, b) => b.unregisteredLitres.compareTo(a.unregisteredLitres));
  return List.unmodifiable(out);
}

// ===========================================================================
// 3. Repostado sin operar
// ===========================================================================

/// Rachas de despachos consecutivos sin avance de SMU.
///
/// Los litros de la racha son los despachados DESPUES de la primera lectura: la
/// primera pudo reponer consumo legitimo previo, y contarla inflaria cada racha.
List<FuelingWithoutActivity> fuelingWithoutActivityOf({
  required List<Movement> movements,
  List<Equipment> equipment = const [],
  Map<String, ResolvedSfl> sflByEquipment = const {},
  double epsilon = activityFrozenSmuEpsilon,
  int minDispenses = activityFrozenMinDispenses,
  double minDays = activityFrozenMinDays,
}) {
  final pairs = _smuPairs(movements);
  if (pairs.isEmpty) return const [];

  final categoryById = <String, String>{};
  final descriptionById = <String, String>{};
  for (final e in equipment) {
    final id = realEquipmentId(e.equipmentId);
    if (id == null) continue;
    if (e.category != null) categoryById[id] = e.category!;
    if (e.description != null) descriptionById[id] = e.description!;
  }

  final out = <FuelingWithoutActivity>[];
  var start = 0;
  while (start < pairs.length) {
    final head = pairs[start];
    final isFrozen = head.smuDelta.abs() <= epsilon;
    var end = start;
    // Una racha se corta al cambiar de equipo o de estado congelado/no.
    while (end + 1 < pairs.length &&
        pairs[end + 1].equipmentId == head.equipmentId &&
        (pairs[end + 1].smuDelta.abs() <= epsilon) == isFrozen) {
      end++;
    }
    if (!isFrozen) {
      start = end + 1;
      continue;
    }

    final run = pairs.sublist(start, end + 1);
    // Una racha de K pares abarca K+1 lecturas.
    final dispenses = run.length + 1;
    final days = run.last.to.difference(run.first.from).inSeconds /
        Duration.secondsPerDay;
    if (dispenses >= minDispenses && days >= minDays) {
      final litres = roundTo(sumOf(run, (p) => p.litresInWindow));
      final sfl = sflByEquipment[head.equipmentId]?.sfl;
      out.add(FuelingWithoutActivity(
        equipmentId: head.equipmentId,
        equipmentDescription:
            run.first.description ?? descriptionById[head.equipmentId],
        category: categoryById[head.equipmentId],
        from: run.first.from,
        to: run.last.to,
        days: roundTo(days, 1),
        dispenses: dispenses,
        litres: litres,
        sfl: sfl,
        overSfl: sfl != null && litres > sfl,
        frozenSmu: roundTo(run.first.smuPrev, 1),
        smuType: run.first.smuType,
      ));
    }
    start = end + 1;
  }
  out.sort((a, b) {
    if (a.overSfl != b.overSfl) return a.overSfl ? -1 : 1;
    return b.litres.compareTo(a.litres);
  });
  return List.unmodifiable(out);
}
