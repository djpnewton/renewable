import 'dart:math';

import 'cities.dart';
import 'config.dart';
import 'sim.dart';

enum OptimizeMode { operational, capital, both }

class OptimizeResult {
  final List<Generator> generators;
  final List<Battery> batteries;
  OptimizeResult(this.generators, this.batteries);
}

// ── Pure helpers ──────────────────────────────────────────────────────────────

Generator cloneGenerator(Generator g, {int? mw}) {
  final m = mw ?? g.megawattMax;
  if (g is GeneratorCarbon) return GeneratorCarbon(m);
  if (g is GeneratorSolar) return GeneratorSolar(m);
  if (g is GeneratorWind) {
    return GeneratorWind(m, maxWind: g.maxWind, minWind: g.minWind);
  }
  throw StateError('Unknown generator type: ${g.type()}');
}

Battery cloneBattery(Battery b, {double? capacityMWh}) {
  final cap = capacityMWh ?? b.capacityMWh;
  return Battery(cap, cap / 2);
}

/// Converts the one-time capital cost to a daily equivalent using an annuity
/// formula, so it is on the same numeric scale as daily operational cost.
int _dailyCapCost(int capCost) {
  if (capCost == 0) return 0;
  const r = loanInterestRate;
  const n = loanTermYears;
  return (capCost * r * pow(1 + r, n) / (pow(1 + r, n) - 1) / 365).round();
}

/// Returns the scalar that the optimizer minimises.
int computeObjective(
    int opCost, List<Generator> gens, List<Battery> bats, OptimizeMode mode) {
  if (mode == OptimizeMode.operational) return opCost;
  final capCost = gens.fold<int>(0, (s, g) => s + g.capitalCost) +
      bats.fold<int>(0, (s, b) => s + b.capitalCost);
  final dailyCap = _dailyCapCost(capCost);
  return switch (mode) {
    OptimizeMode.capital => dailyCap,
    OptimizeMode.both => opCost + dailyCap,
    OptimizeMode.operational => opCost, // unreachable
  };
}

// ── Simulation ────────────────────────────────────────────────────────────────

/// Runs a full 24-hour simulation. Returns (shortfall MWh, operational cost $).
/// Resets all generators and batteries before running.
(double shortfall, int operationalCost) evalSim(
    List<Generator> gens, List<Battery> bats, Weather24h w24, City city) {
  for (final g in gens) {
    g.reset();
  }
  for (final b in bats) {
    b.reset();
  }
  var shortfall = 0.0;
  var totalCost = 0;
  for (final wp in w24.periods) {
    final demandMW = wp.energyDemand(city).toDouble();

    // 1. Renewables run at full weather capacity.
    var freeOutput = 0.0;
    var freeCost = 0;
    for (final gen in gens) {
      if (gen is! GeneratorCarbon) {
        final gp = gen.generate(wp, 100);
        freeOutput += gp.megawattHoursGenerated;
        freeCost += gp.cost;
      }
    }
    var gap = demandMW - freeOutput;

    // 2. Battery discharges into shortfall or absorbs surplus.
    var batteryContrib = 0.0;
    final costBefore = bats.fold(0, (s, b) => s + b.totalCost);
    if (gap > 0) {
      for (final b in bats) {
        batteryContrib += b.discharge(gap - batteryContrib);
      }
      gap -= batteryContrib;
    } else {
      var acc = 0.0;
      for (final b in bats) {
        acc += b.charge((-gap) - acc);
      }
    }
    final batteryCostHour =
        bats.fold(0, (s, b) => s + b.totalCost) - costBefore;
    final batteryMaintHour = bats.fold(0, (s, b) => s + b.omCostPerHour);

    // 3. Carbon fills any remaining gap.
    final carbonGens = gens.whereType<GeneratorCarbon>().toList();
    final totalCarbonCap = carbonGens.fold(0, (s, g) => s + g.megawattMax);
    var carbonOutput = 0.0;
    var carbonCost = 0;
    if (totalCarbonCap > 0 && gap > 0) {
      final pct = min(100.0, gap / totalCarbonCap * 100);
      for (final g in carbonGens) {
        final gp = g.generate(wp, pct);
        carbonOutput += gp.megawattHoursGenerated;
        carbonCost += gp.cost;
      }
    } else {
      for (final g in carbonGens) {
        g.generate(wp, 0);
      }
    }

    final produced = freeOutput + batteryContrib + carbonOutput;
    final diff = produced - demandMW;
    if (diff < -0.001) shortfall += -diff;
    totalCost += freeCost + batteryCostHour + batteryMaintHour + carbonCost;
  }
  return (shortfall, totalCost);
}

// ── Optimizer ─────────────────────────────────────────────────────────────────

/// Finds the lowest-cost fleet (sized to the given [mode]) that produces no
/// shortfall against [weather] for [city].
///
/// - [generators] and [batteries]: starting fleet (only types are used as
///   hints; sizes are freely optimised).
/// - [mode]: which cost component to minimise.
/// - [includeBaseload]: if true, ensures carbon capacity ≥ peak demand.
OptimizeResult optimize(
  City city,
  List<Generator> generators,
  List<Battery> batteries,
  OptimizeMode mode,
  Weather24h weather, {
  bool includeBaseload = false,
}) {
  final w24 = weather;
  final rng = Random();
  final peakDemand = w24.periods.map((wp) => wp.energyDemand(city)).reduce(max);
  final upperMW = (peakDemand * 20).round().clamp(1000, 2000000);
  final upperCap = w24.periods.fold(0.0, (s, wp) => s + wp.energyDemand(city));

  // ── Augmented seed fleet ───────────────────────────────────────────────────
  final hasSolar = generators.any((g) => g is GeneratorSolar);
  final hasWind = generators.any((g) => g is GeneratorWind);
  final hasCarbon = generators.any((g) => g is GeneratorCarbon);
  final seedGens = <Generator>[
    ...generators.map(cloneGenerator),
    if (!hasSolar) GeneratorSolar(peakDemand.round().clamp(1, upperMW)),
    if (!hasWind) GeneratorWind(peakDemand.round().clamp(1, upperMW)),
    if (!hasCarbon) GeneratorCarbon(peakDemand.round().clamp(1, upperMW)),
  ];
  final seedBats = <Battery>[
    ...batteries.map(cloneBattery),
    if (batteries.isEmpty)
      Battery(
        (peakDemand * 4.0).clamp(1.0, upperCap),
        (peakDemand * 2.0).clamp(1.0, upperCap / 2),
      ),
  ];

  // ── Coordinate-descent helper ──────────────────────────────────────────────
  (List<Generator>, List<Battery>, int) runDescent(
      List<Generator> g0, List<Battery> b0) {
    var gens = g0.map(cloneGenerator).toList();
    var bats = b0.map(cloneBattery).toList();

    (double, int) eg(int i, int mw) {
      final gs = [
        for (var j = 0; j < gens.length; j++)
          j == i ? cloneGenerator(gens[j], mw: mw) : cloneGenerator(gens[j])
      ];
      final batsClone = bats.map(cloneBattery).toList();
      final (sf, opCost) = evalSim(gs, batsClone, w24, city);
      return (sf, computeObjective(opCost, gs, batsClone, mode));
    }

    (double, int) eb(int i, double cap) {
      final bs = [
        for (var j = 0; j < bats.length; j++)
          j == i
              ? cloneBattery(bats[j], capacityMWh: cap)
              : cloneBattery(bats[j])
      ];
      final gensClone = gens.map(cloneGenerator).toList();
      final (sf, opCost) = evalSim(gensClone, bs, w24, city);
      return (sf, computeObjective(opCost, gensClone, bs, mode));
    }

    var prevCost = 0x7fffffff;
    for (int pass = 0; pass < 12; pass++) {
      // ── Generators ────────────────────────────────────────────────────────
      for (int i = 0; i < gens.length; i++) {
        if (eg(i, upperMW).$1 > 0.001) continue;

        var mwMin = 0;
        if (eg(i, 0).$1 > 0.001) {
          var lo = 1, hi = upperMW;
          mwMin = upperMW;
          while (lo <= hi) {
            final mid = (lo + hi) ~/ 2;
            if (eg(i, mid).$1 <= 0.001) {
              mwMin = mid;
              hi = mid - 1;
            } else {
              lo = mid + 1;
            }
          }
        }
        var lo = mwMin, hi = upperMW;
        for (int s = 0; s < 50; s++) {
          final third = (hi - lo) ~/ 3;
          if (third == 0) break;
          final m1 = lo + third, m2 = hi - third;
          if (eg(i, m1).$2 <= eg(i, m2).$2) {
            hi = m2;
          } else {
            lo = m1;
          }
        }
        var best = lo, bestC = eg(i, lo).$2;
        for (var mw = lo + 1; mw <= hi; mw++) {
          final c = eg(i, mw).$2;
          if (c < bestC) {
            bestC = c;
            best = mw;
          }
        }
        gens[i] = cloneGenerator(gens[i], mw: best);
      }

      // ── Batteries ─────────────────────────────────────────────────────────
      for (int i = 0; i < bats.length; i++) {
        double capMin = 0;
        if (eb(i, 0).$1 > 0.001) {
          if (eb(i, upperCap).$1 > 0.001) continue;
          double loF = 0, hiF = upperCap;
          for (int s = 0; s < 32; s++) {
            final mid = (loF + hiF) / 2;
            if (eb(i, mid).$1 <= 0.001) {
              capMin = mid;
              hiF = mid;
            } else {
              loF = mid;
            }
          }
        }
        double loF = capMin, hiF = upperCap;
        for (int s = 0; s < 50; s++) {
          if (hiF - loF < 0.5) break;
          final third = (hiF - loF) / 3;
          final m1 = loF + third, m2 = hiF - third;
          if (eb(i, m1).$2 <= eb(i, m2).$2) {
            hiF = m2;
          } else {
            loF = m1;
          }
        }
        bats[i] = cloneBattery(bats[i], capacityMWh: (loF + hiF) / 2);
      }

      final (sf, cost) = evalSim(gens.map(cloneGenerator).toList(),
          bats.map(cloneBattery).toList(), w24, city);
      final obj = computeObjective(cost, gens, bats, mode);
      if (sf > 0.001) break;
      if (prevCost - obj < 1) break;
      prevCost = obj;
    }

    final (sf, cost) = evalSim(gens.map(cloneGenerator).toList(),
        bats.map(cloneBattery).toList(), w24, city);
    final finalObj = computeObjective(cost, gens, bats, mode);
    return (gens, bats, sf <= 0.001 ? finalObj : 0x7fffffff);
  }

  // ── Perturbation helpers ───────────────────────────────────────────────────
  List<Generator> shakeGens(List<Generator> gens, double logScale) =>
      gens.map((g) {
        final f = exp((rng.nextDouble() * 2 - 1) * logScale);
        return cloneGenerator(g,
            mw: (g.megawattMax * f).round().clamp(1, upperMW));
      }).toList();

  List<Battery> shakeBats(List<Battery> bats, double logScale) => bats.map((b) {
        final f = exp((rng.nextDouble() * 2 - 1) * logScale);
        return cloneBattery(b,
            capacityMWh: (b.capacityMWh * f).clamp(1.0, upperCap));
      }).toList();

  // ── Multi-start ────────────────────────────────────────────────────────────
  var bestGens = seedGens;
  var bestBats = seedBats;
  var bestCost = 0x7fffffff;

  const shakeSchedule = [
    0.0,
    0.3,
    0.6,
    0.3,
    1.0,
    0.5,
    1.5,
    0.4,
    0.8,
    1.2,
    0.7,
    2.0,
    0.4,
    1.0,
    0.6,
  ];
  for (final scale in shakeSchedule) {
    final startGens = scale == 0.0
        ? seedGens.map(cloneGenerator).toList()
        : shakeGens(seedGens, scale);
    final startBats = scale == 0.0
        ? seedBats.map(cloneBattery).toList()
        : shakeBats(seedBats, scale);
    final (g, b, c) = runDescent(startGens, startBats);
    if (c < bestCost) {
      bestGens = g;
      bestBats = b;
      bestCost = c;
    }
  }

  // ── Topology seeds ─────────────────────────────────────────────────────────
  final topologySeeds = <(List<Generator>, List<Battery>)>[
    (
      [GeneratorCarbon(peakDemand.round().clamp(1, upperMW))],
      <Battery>[],
    ),
    (
      [GeneratorSolar(peakDemand.round().clamp(1, upperMW))],
      [
        Battery(upperCap.clamp(1.0, upperCap),
            peakDemand.toDouble().clamp(1.0, upperCap / 2))
      ],
    ),
    (
      [GeneratorWind(peakDemand.round().clamp(1, upperMW))],
      [
        Battery(upperCap.clamp(1.0, upperCap),
            peakDemand.toDouble().clamp(1.0, upperCap / 2))
      ],
    ),
  ];
  for (final (tGens, tBats) in topologySeeds) {
    final (g, b, c) = runDescent(tGens, tBats);
    if (c < bestCost) {
      bestGens = g;
      bestBats = b;
      bestCost = c;
    }
  }

  // ── Prune pass ─────────────────────────────────────────────────────────────
  var finalGens = List<Generator>.from(bestGens);
  var finalBats = List<Battery>.from(bestBats);
  for (int i = finalGens.length - 1; i >= 0; i--) {
    if (finalGens.length <= 1) break;
    final testGens = List<Generator>.from(finalGens)..removeAt(i);
    final (sf, c) = evalSim(testGens.map(cloneGenerator).toList(),
        finalBats.map(cloneBattery).toList(), w24, city);
    final obj = computeObjective(c, testGens, finalBats, mode);
    if (sf <= 0.001 && obj <= bestCost + 1) {
      finalGens = testGens;
      bestCost = obj;
    }
  }
  for (int i = finalBats.length - 1; i >= 0; i--) {
    final testBats = List<Battery>.from(finalBats)..removeAt(i);
    final (sf, c) = evalSim(finalGens.map(cloneGenerator).toList(),
        testBats.map(cloneBattery).toList(), w24, city);
    final obj = computeObjective(c, finalGens, testBats, mode);
    if (sf <= 0.001 && obj <= bestCost + 1) {
      finalBats = testBats;
      bestCost = obj;
    }
  }

  // ── Consolidation pass ─────────────────────────────────────────────────────
  final consolidatedGens = <Generator>[];
  for (final type in [GeneratorCarbon, GeneratorSolar, GeneratorWind]) {
    final group = finalGens.where((g) => g.runtimeType == type).toList();
    if (group.isEmpty) continue;
    final totalMW = group.fold(0, (sum, g) => sum + g.megawattMax);
    consolidatedGens.add(cloneGenerator(group.first, mw: totalMW));
  }
  final totalBatCap = finalBats.fold(0.0, (sum, b) => sum + b.capacityMWh);
  final totalBatPower = finalBats.fold(0.0, (sum, b) => sum + b.maxPowerMW);
  final consolidatedBats =
      finalBats.isEmpty ? <Battery>[] : [Battery(totalBatCap, totalBatPower)];

  // ── Baseload constraint ────────────────────────────────────────────────────
  if (includeBaseload) {
    final carbonIdx = consolidatedGens.indexWhere((g) => g is GeneratorCarbon);
    final requiredMW = peakDemand.round().clamp(1, upperMW);
    if (carbonIdx >= 0) {
      final existing = consolidatedGens[carbonIdx];
      if (existing.megawattMax < requiredMW) {
        consolidatedGens[carbonIdx] = GeneratorCarbon(requiredMW);
      }
    } else {
      consolidatedGens.add(GeneratorCarbon(requiredMW));
    }
  }

  return OptimizeResult(consolidatedGens, consolidatedBats);
}
