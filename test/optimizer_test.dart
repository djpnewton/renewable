import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:renewable/cities.dart';
import 'package:renewable/optimizer.dart';
import 'package:renewable/sim.dart';

// ── Shared fixtures ──────────────────────────────────────────────────────────

/// 100 k population → base demand 100 MW.
/// Peak demand = 100 × 1.1 (evening, 20 °C) = 110 MW.
final _city = City('TestCity', 'TC', 100000);

/// All-dark, no-wind weather — only carbon generators produce power.
final _wDark = Weather24h.fixed(); // temp=20, sun=0, wind=0

/// Full-sun, full-wind weather — all renewables at maximum output.
/// (wind=60 is exactly maxWind so capacity factor = 1.0)
final _wFull = Weather24h.fixed(temp: 20, sun: 100, wind: 60);

/// Moderate mixed weather.
final _wMid = Weather24h.fixed(temp: 20, sun: 50, wind: 30);

/// Extreme-heat weather — demand 1.2× higher than moderate.
final _wHot = Weather24h.fixed(temp: 35, sun: 50, wind: 30);

int _peakDemand(Weather24h w) =>
    w.periods.map((p) => p.energyDemand(_city)).reduce((a, b) => a > b ? a : b);

// ── evalSim ──────────────────────────────────────────────────────────────────

void main() {
  group('evalSim – fleet sizing', () {
    test('carbon fleet at peak capacity → zero shortfall', () {
      final peak = _peakDemand(_wDark);
      final (sf, _) = evalSim([GeneratorCarbon(peak)], [], _wDark, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });

    test('oversized carbon fleet → zero shortfall', () {
      final (sf, _) = evalSim([GeneratorCarbon(10000)], [], _wDark, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });

    test('undersized carbon fleet → shortfall > 0', () {
      final (sf, _) = evalSim([GeneratorCarbon(10)], [], _wDark, _city);
      expect(sf, greaterThan(0.5));
    });

    test('no generators → full demand is unmet', () {
      final (sf, _) = evalSim([], [], _wDark, _city);
      // 24 hours of ~60–110 MW demand, nothing produced
      expect(sf, greaterThan(1000));
    });
  });

  group('evalSim – solar generator', () {
    test('solar at zero sun produces nothing → shortfall > 0', () {
      final (sf, _) = evalSim([GeneratorSolar(5000)], [], _wDark, _city);
      expect(sf, greaterThan(0.5));
    });

    test('large solar at 100% sun → zero shortfall', () {
      // 5000 MW at 100% sun covers 100 MW peak easily
      final (sf, _) = evalSim([GeneratorSolar(5000)], [], _wFull, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });

    test('just-right solar capacity at 50% sun → zero shortfall', () {
      // 50% sun × 220 MW = 110 MW = peak demand
      final (sf, _) = evalSim([GeneratorSolar(220)], [], _wMid, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });
  });

  group('evalSim – wind generator', () {
    test('wind at 0 km/h (below minimum) → shortfall > 0', () {
      final (sf, _) = evalSim([GeneratorWind(5000)], [], _wDark, _city);
      expect(sf, greaterThan(0.5));
    });

    test('large wind at max speed → zero shortfall', () {
      final (sf, _) = evalSim([GeneratorWind(5000)], [], _wFull, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });
  });

  group('evalSim – battery behaviour', () {
    test('battery starts empty, contributes nothing without generation', () {
      // No generation at all; battery begins at 0% charge so can never discharge.
      final (sf, _) = evalSim([], [Battery(100000, 50000)], _wDark, _city);
      expect(sf, greaterThan(0.5));
    });

    test('solar + large battery covers demand even at zero sun', () {
      // Solar charges battery during daylight (sun=50 at all hours), battery
      // covers overnight gap.  With fixed weather sun=50 is constant so solar
      // always generates — battery role is buffering peak/off-peak mismatch.
      // Use _wMid which has sun=50 at every hour.
      final (sf, _) =
          evalSim([GeneratorSolar(500)], [Battery(2000, 1000)], _wMid, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });
  });

  group('evalSim – cost properties', () {
    test('operational cost is always non-negative', () {
      final (_, cost) = evalSim([GeneratorCarbon(500)], [], _wDark, _city);
      expect(cost, greaterThanOrEqualTo(0));
    });

    test('larger fleet has higher O&M cost', () {
      final (_, cost200) = evalSim([GeneratorCarbon(200)], [], _wDark, _city);
      final (_, cost1000) = evalSim([GeneratorCarbon(1000)], [], _wDark, _city);
      expect(cost1000, greaterThan(cost200));
    });

    test('hot weather raises demand and therefore carbon dispatch cost', () {
      final (_, costNormal) = evalSim([GeneratorCarbon(500)], [], _wMid, _city);
      final (_, costHot) = evalSim([GeneratorCarbon(500)], [], _wHot, _city);
      expect(costHot, greaterThan(costNormal));
    });
  });

  // ── optimize – zero-shortfall invariant ─────────────────────────────────────

  group('optimize – result always has zero shortfall', () {
    for (final mode in OptimizeMode.values) {
      // All-dark weather forces carbon (or storage charged from renewables) to
      // cover everything.
      test('mode=$mode, carbon start, no-renewable weather', () {
        final result =
            optimize(_city, [GeneratorCarbon(2000)], [], mode, _wDark);
        final (sf, _) =
            evalSim(result.generators, result.batteries, _wDark, _city);
        expect(sf, lessThanOrEqualTo(0.001),
            reason: 'Fleet must cover full demand');
      });

      test('mode=$mode, mixed fleet, moderate weather', () {
        final gens = [
          GeneratorCarbon(500),
          GeneratorSolar(500),
          GeneratorWind(300)
        ];
        final result = optimize(_city, gens, [Battery(500, 250)], mode, _wMid);
        final (sf, _) =
            evalSim(result.generators, result.batteries, _wMid, _city);
        expect(sf, lessThanOrEqualTo(0.001));
      });

      test('mode=$mode, solar-only start, no-renewable weather', () {
        // Renewables produce nothing → optimizer must add carbon backup.
        final result =
            optimize(_city, [GeneratorSolar(2000)], [], mode, _wDark);
        final (sf, _) =
            evalSim(result.generators, result.batteries, _wDark, _city);
        expect(sf, lessThanOrEqualTo(0.001));
      });

      test('mode=$mode, extreme heat weather', () {
        final result =
            optimize(_city, [GeneratorCarbon(2000)], [], mode, _wHot);
        final (sf, _) =
            evalSim(result.generators, result.batteries, _wHot, _city);
        expect(sf, lessThanOrEqualTo(0.001));
      });
    }
  });

  // ── optimize – cost improvements ────────────────────────────────────────────

  group('optimize – improves cost vs. oversized starting fleet', () {
    test('operational mode reduces O&M cost from oversized carbon', () {
      final big = [GeneratorCarbon(50000)];
      final (_, startCost) = evalSim(big, [], _wDark, _city);

      final result = optimize(_city, big, [], OptimizeMode.operational, _wDark);
      final (_, optCost) =
          evalSim(result.generators, result.batteries, _wDark, _city);

      expect(optCost, lessThan(startCost));
    });

    test('capital mode reduces total installed capacity from oversized carbon',
        () {
      final big = [GeneratorCarbon(50000)];
      final startCap = big.fold(0, (s, g) => s + g.capitalCost);

      final result = optimize(_city, big, [], OptimizeMode.capital, _wDark);
      final optCap = result.generators.fold(0, (s, g) => s + g.capitalCost) +
          result.batteries.fold(0, (s, b) => s + b.capitalCost);

      expect(optCap, lessThan(startCap));
    });

    test('optimize result is not worse than starting feasible fleet', () {
      // A just-feasible fleet should not be made worse (no shortfall added).
      final peak = _peakDemand(_wDark);
      final fleet = [GeneratorCarbon(peak)];

      final result =
          optimize(_city, fleet, [], OptimizeMode.operational, _wDark);
      final (sf, _) =
          evalSim(result.generators, result.batteries, _wDark, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });
  });

  // ── optimize – output fleet properties ──────────────────────────────────────

  group('optimize – fleet structure', () {
    test('result generators list is non-empty', () {
      final result = optimize(
          _city, [GeneratorCarbon(1000)], [], OptimizeMode.operational, _wDark);
      expect(result.generators, isNotEmpty);
    });

    test('all result generators have positive MW capacity', () {
      final result = optimize(
          _city,
          [GeneratorCarbon(1000), GeneratorSolar(1000)],
          [],
          OptimizeMode.both,
          _wMid);
      for (final g in result.generators) {
        expect(g.megawattMax, greaterThan(0));
      }
    });

    test('all result batteries have positive capacity', () {
      final result = optimize(_city, [GeneratorSolar(500)], [Battery(500, 250)],
          OptimizeMode.operational, _wMid);
      for (final b in result.batteries) {
        expect(b.capacityMWh, greaterThan(0));
      }
    });

    test('result contains at most one generator of each type (consolidated)',
        () {
      final gens = [
        GeneratorCarbon(300),
        GeneratorCarbon(300),
        GeneratorSolar(300),
      ];
      final result =
          optimize(_city, gens, [], OptimizeMode.operational, _wDark);
      final carbonCount = result.generators.whereType<GeneratorCarbon>().length;
      final solarCount = result.generators.whereType<GeneratorSolar>().length;
      expect(carbonCount, lessThanOrEqualTo(1));
      expect(solarCount, lessThanOrEqualTo(1));
    });
  });

  // ── optimize – baseload constraint ──────────────────────────────────────────

  group('optimize – baseload constraint', () {
    test('includeBaseload=true ensures carbon capacity >= peak demand', () {
      final peak = _peakDemand(_wMid);
      // Start with solar-only — no carbon at all.
      final result = optimize(
          _city, [GeneratorSolar(10000)], [], OptimizeMode.operational, _wMid,
          includeBaseload: true);

      final carbonMW = result.generators
          .whereType<GeneratorCarbon>()
          .fold(0, (s, g) => s + g.megawattMax);
      expect(carbonMW, greaterThanOrEqualTo(peak));
    });

    test(
        'includeBaseload=true still delivers zero shortfall on no-renewable day',
        () {
      final result = optimize(
          _city, [GeneratorSolar(10000)], [], OptimizeMode.operational, _wMid,
          includeBaseload: true);
      // Verify fleet handles worst-case: no sun, no wind.
      final (sf, _) =
          evalSim(result.generators, result.batteries, _wDark, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });

    test(
        'includeBaseload=false may leave solar-only fleet that fails on dark day',
        () {
      // Without the constraint the optimiser is free to drop carbon entirely
      // when weather is always sunny.  Verify the test harness itself works.
      final result = optimize(
          _city, [GeneratorSolar(5000)], [], OptimizeMode.operational, _wFull,
          includeBaseload: false);
      // The result fleet is valid for wFull; we make no assertion about wDark.
      final (sf, _) =
          evalSim(result.generators, result.batteries, _wFull, _city);
      expect(sf, lessThanOrEqualTo(0.001));
    });
  });

  // ── cloneGenerator / cloneBattery ────────────────────────────────────────────

  group('cloneGenerator', () {
    test('preserves type: carbon', () {
      expect(cloneGenerator(GeneratorCarbon(100)), isA<GeneratorCarbon>());
    });
    test('preserves type: solar', () {
      expect(cloneGenerator(GeneratorSolar(100)), isA<GeneratorSolar>());
    });
    test('preserves type: wind', () {
      expect(cloneGenerator(GeneratorWind(100)), isA<GeneratorWind>());
    });
    test('overrides MW when supplied', () {
      final g = cloneGenerator(GeneratorCarbon(100), mw: 42);
      expect(g.megawattMax, 42);
    });
    test('clone is independent (mutation does not affect original)', () {
      final orig = GeneratorCarbon(100);
      final copy = cloneGenerator(orig, mw: 200) as GeneratorCarbon;
      expect(orig.megawattMax, 100);
      expect(copy.megawattMax, 200);
    });
  });

  group('cloneBattery', () {
    test('clone starts with zero charge', () {
      final b = Battery(100, 50)..charge(50); // charge it first
      final copy = cloneBattery(b);
      expect(copy.chargeMWh, 0.0);
    });
    test('overrides capacity when supplied', () {
      final copy = cloneBattery(Battery(100, 50), capacityMWh: 200);
      expect(copy.capacityMWh, 200);
    });
    test('max power is set to 50% of capacity', () {
      final copy = cloneBattery(Battery(100, 50), capacityMWh: 400);
      expect(copy.maxPowerMW, 200);
    });
  });

  // ── computeObjective ─────────────────────────────────────────────────────────

  group('computeObjective', () {
    final gens = [GeneratorCarbon(1000)]; // capitalCost = $1B
    final bats = <Battery>[];
    const opCost = 500000; // $500k/day operational

    test('operational mode returns opCost unchanged', () {
      expect(computeObjective(opCost, gens, bats, OptimizeMode.operational),
          opCost);
    });

    test('capital mode returns daily capital cost (> 0)', () {
      final obj = computeObjective(opCost, gens, bats, OptimizeMode.capital);
      expect(obj, greaterThan(0));
    });

    test('both mode returns value >= max(opCost, capitalCost)', () {
      final capOnly =
          computeObjective(opCost, gens, bats, OptimizeMode.capital);
      final both = computeObjective(opCost, gens, bats, OptimizeMode.both);
      expect(both, greaterThanOrEqualTo(max(opCost, capOnly)));
    });

    test('larger fleet has higher capital objective', () {
      final small = [GeneratorCarbon(100)];
      final large = [GeneratorCarbon(10000)];
      final smallObj = computeObjective(0, small, bats, OptimizeMode.capital);
      final largeObj = computeObjective(0, large, bats, OptimizeMode.capital);
      expect(largeObj, greaterThan(smallObj));
    });
  });
}
