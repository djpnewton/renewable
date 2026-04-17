import 'dart:math';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:renewable/config.dart';

import 'cities.dart';
import 'assets.dart';
import 'sim.dart';
import 'optimizer.dart';
import 'test.dart';

final log = Logger('mainlogger');

void main() {
  Logger.root.level = Level.ALL; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  log.info('build GIT SHA: $gitSha');
  log.info('build date: $buildDate');

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Renewable',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: MyHomePage(title: 'Renewable $appVersion'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  var _city = City.empty();
  var _generators = <Generator>[];
  var _batteries = <Battery>[];
  SimSummary? _summary;
  Weather24h? _lastWeather;
  var _includeBaseload = false;
  var _optimizeMode = OptimizeMode.operational;
  var _sunEnabled = true;
  var _windEnabled = true;
  var _tempData = LineChartData();
  var _sunData = LineChartData();
  var _windData = LineChartData();
  var _energyData = LineChartData();
  var _batteryData = LineChartData();
  var _costData = LineChartData();

  @override
  void initState() {
    _generateCity();
    super.initState();
  }

  void _generateCity() async {
    final data = await getWorldCities();
    final city = City.random(City.parseCsv(data));
    var megawattsRequired = city.baseEnergyRequirement();
    final newGenerators = <Generator>[];
    // start with all carbon generators
    while (megawattsRequired > 0) {
      var gen = GeneratorCarbon(1000);
      newGenerators.add(gen);
      megawattsRequired -= gen.megawattMax;
    }
    // battery: 2 hours of base demand as storage, 50% of base demand as max power
    setState(() {
      _city = city;
      _generators = newGenerators;
      _batteries = [];
      _summary = null;
      _tempData = LineChartData();
      _sunData = LineChartData();
      _windData = LineChartData();
      _energyData = LineChartData();
      _batteryData = LineChartData();
      _costData = LineChartData();
    });
  }

  Widget _bottomTitleWidgets(double value, TitleMeta meta) {
    if (value.toInt() % 3 != 0) return const SizedBox();

    const style = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.bold,
    );
    final text = niceTime(value.toInt());

    return SideTitleWidget(
      meta: meta,
      space: 4,
      child: Text(text, style: style),
    );
  }

  Widget _chartTitle(String label, List<(String, Color)> legend) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1)),
          for (final (name, color) in legend) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: color, borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 3),
                Text(name,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _chart(String title, LineChartData data,
      {List<(String, Color)> legend = const [], Widget? action}) {
    return Column(children: [
      SizedBox(
        width: 400,
        child: Row(children: [
          Expanded(child: _chartTitle(title, legend)),
          if (action != null) action,
        ]),
      ),
      SizedBox(
          width: 400,
          height: 200,
          child: Padding(
              padding: const EdgeInsets.only(
                left: 10,
                right: 18,
                top: 10,
                bottom: 4,
              ),
              child: LineChart(data)))
    ]);
  }

  void _sim() async {
    final w24 = Weather24h();
    _lastWeather = w24;
    _runSim(w24);
  }

  void _runSim(Weather24h w24) {
    printWeather24(w24);
    for (var gen in _generators) {
      gen.reset();
    }
    for (var b in _batteries) {
      b.reset();
    }
    List<FlSpot> temp = [];
    List<FlSpot> sun = [];
    List<FlSpot> wind = [];
    List<FlSpot> demand = [];
    List<FlSpot> produced = [];
    List<FlSpot> cost = [];
    List<FlSpot> batteryCharge = [];
    List<FlSpot> batteryAccum = [];
    List<FlSpot> batteryDischarge = [];
    var totalDemand = 0.0;
    var totalProduced = 0.0;
    var totalShortfall = 0.0;
    var totalSurplus = 0.0;
    var totalRenewable = 0.0;
    var totalCarbon = 0.0;
    var totalBattery = 0.0;
    var totalBatteryCharged = 0.0;
    var totalCostSum = 0;
    for (var wpOrig in w24.periods) {
      final wp = WeatherPeriod(
        wpOrig.hour,
        wpOrig.temp,
        _sunEnabled ? wpOrig.sun : 0,
        _windEnabled ? wpOrig.wind : 0,
      );
      printWeather(wp, _city);
      temp.add(FlSpot(wp.hour.toDouble(), wp.temp.toDouble()));
      sun.add(FlSpot(wp.hour.toDouble(), wp.sun.toDouble()));
      wind.add(FlSpot(wp.hour.toDouble(), wp.wind.toDouble()));
      final demandMW = wp.energyDemand(_city).toDouble();
      demand.add(FlSpot(wp.hour.toDouble(), demandMW));

      // 1. Renewables (solar, wind) run at full weather capacity
      var freeOutput = 0.0;
      var freeCost = 0;
      for (var gen in _generators) {
        if (gen is! GeneratorCarbon) {
          var gp = gen.generate(wp, 100);
          freeOutput += gp.megawattHoursGenerated;
          freeCost += gp.cost;
        }
      }

      var baselineOutput = freeOutput;
      var gap = demandMW - baselineOutput;

      // 2. Battery: discharge during shortfall, charge during surplus
      var batteryContribution = 0.0;
      var batteryAccumHour = 0.0;
      final batteryTotalCostBefore =
          _batteries.fold(0, (s, b) => s + b.totalCost);
      if (gap > 0) {
        for (final b in _batteries) {
          final got = b.discharge(gap - batteryContribution);
          batteryContribution += got;
        }
        gap -= batteryContribution;
      } else {
        for (final b in _batteries) {
          batteryAccumHour += b.charge((-gap) - batteryAccumHour);
        }
      }
      final batteryCostHour = _batteries.fold(0, (s, b) => s + b.totalCost) -
          batteryTotalCostBefore;
      final batteryMaintenanceHour =
          _batteries.fold(0, (s, b) => s + b.omCostPerHour);

      // 3. Carbon fills any remaining gap (dispatchable peaker)
      final carbonGens = _generators.whereType<GeneratorCarbon>().toList();
      final totalCarbonCapacity =
          carbonGens.fold(0, (sum, g) => sum + g.megawattMax);
      var carbonOutput = 0.0;
      var carbonCost = 0;
      if (totalCarbonCapacity > 0 && gap > 0) {
        final carbonPercent = min(100.0, gap / totalCarbonCapacity * 100);
        for (var gen in carbonGens) {
          var gp = gen.generate(wp, carbonPercent);
          carbonOutput += gp.megawattHoursGenerated;
          carbonCost += gp.cost;
        }
      } else {
        for (var gen in carbonGens) {
          gen.generate(wp, 0);
        }
      }

      final totalProducedHour =
          baselineOutput + carbonOutput + batteryContribution;
      final totalCostHour =
          freeCost + carbonCost + batteryCostHour + batteryMaintenanceHour;
      produced.add(FlSpot(wp.hour.toDouble(), totalProducedHour));
      cost.add(FlSpot(wp.hour.toDouble(), totalCostHour.toDouble()));
      batteryCharge.add(FlSpot(
          wp.hour.toDouble(), _batteries.fold(0.0, (s, b) => s + b.chargeMWh)));
      batteryAccum.add(FlSpot(wp.hour.toDouble(), batteryAccumHour));
      batteryDischarge.add(FlSpot(wp.hour.toDouble(), batteryContribution));

      totalDemand += demandMW;
      totalProduced += totalProducedHour;
      final diff = totalProducedHour - demandMW;
      if (diff < -0.001) {
        totalShortfall += -diff;
      }
      if (diff > 0.001) {
        totalSurplus += diff;
      }
      totalRenewable += freeOutput;
      totalCarbon += carbonOutput;
      totalBattery += batteryContribution;
      totalBatteryCharged += batteryAccumHour;
      totalCostSum += totalCostHour;
    }
    setState(() {
      _summary = SimSummary(
        totalDemandMWh: totalDemand,
        totalProducedMWh: totalProduced,
        shortfallMWh: totalShortfall,
        surplusMWh: totalSurplus,
        renewableMWh: totalRenewable,
        carbonMWh: totalCarbon,
        batteryMWh: totalBattery,
        batteryChargedMWh: totalBatteryCharged,
        totalCost: totalCostSum,
        totalCapitalCost: _generators.fold(0, (s, g) => s + g.capitalCost) +
            _batteries.fold(0, (s, b) => s + b.capitalCost),
      );
      _tempData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: temp,
              isCurved: true,
              barWidth: 2,
              color: Colors.red,
              dotData: const FlDotData(show: false)),
        ],
        minY: 0,
        maxY: 40,
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(
            show: true, verticalInterval: 1, horizontalInterval: 5),
      );
      _sunData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: sun,
              isCurved: true,
              barWidth: 2,
              color: Colors.yellow,
              dotData: const FlDotData(show: false)),
        ],
        minY: 0,
        maxY: 100,
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(
            show: true, verticalInterval: 1, horizontalInterval: 10),
      );
      final windGens = _generators.whereType<GeneratorWind>().toList();
      final windCutoff = windGens.isNotEmpty
          ? windGens.map((g) => g.maxWind).reduce(max).toDouble()
          : null;
      final windMin = windGens.isNotEmpty
          ? windGens.map((g) => g.minWind).reduce(min).toDouble()
          : null;
      _windData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: wind,
              isCurved: true,
              barWidth: 2,
              color: Colors.blue,
              dotData: const FlDotData(show: false)),
        ],
        extraLinesData: windCutoff != null
            ? ExtraLinesData(horizontalLines: [
                HorizontalLine(
                  y: windCutoff,
                  color: Colors.red.withValues(alpha: 0.7),
                  strokeWidth: 1,
                  dashArray: [6, 4],
                  label: HorizontalLineLabel(
                    show: true,
                    alignment: Alignment.topRight,
                    labelResolver: (_) => ' too windy ',
                    style: const TextStyle(
                        fontSize: 9,
                        color: Colors.red,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                HorizontalLine(
                  y: windMin!,
                  color: Colors.orange.withValues(alpha: 0.7),
                  strokeWidth: 1,
                  dashArray: [6, 4],
                  label: HorizontalLineLabel(
                    show: true,
                    alignment: Alignment.topRight,
                    labelResolver: (_) => ' too calm ',
                    style: const TextStyle(
                        fontSize: 9,
                        color: Colors.orange,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ])
            : const ExtraLinesData(),
        minY: 0,
        maxY: 100,
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(
            show: true, verticalInterval: 1, horizontalInterval: 10),
      );
      _energyData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: demand,
              isCurved: true,
              barWidth: 2,
              color: Colors.green,
              dotData: const FlDotData(show: false)),
          LineChartBarData(
              spots: produced,
              isCurved: true,
              barWidth: 2,
              color: Colors.red,
              dotData: const FlDotData(show: false)),
        ],
        minY: 0,
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(
            show: true, verticalInterval: 1, horizontalInterval: 1000),
      );
      _batteryData = LineChartData(
        lineBarsData: [
          // Storage level (MWh) — orange fill
          LineChartBarData(
              spots: batteryCharge,
              isCurved: true,
              barWidth: 2,
              color: Colors.orange,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                  show: true, color: Colors.orange.withValues(alpha: 0.15))),
          // Accumulation / charging (MWh per hour) — green
          LineChartBarData(
              spots: batteryAccum,
              isCurved: false,
              barWidth: 2,
              color: Colors.green,
              dotData: const FlDotData(show: false)),
          // Discharge (MWh per hour) — red
          LineChartBarData(
              spots: batteryDischarge,
              isCurved: false,
              barWidth: 2,
              color: Colors.red,
              dotData: const FlDotData(show: false)),
        ],
        minY: 0,
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(
            show: true, verticalInterval: 1, horizontalInterval: 1000),
      );
      final hourlyCapital = _summary!.dailyLoanRepayment / 24;
      final capitalSpots =
          List.generate(24, (h) => FlSpot(h.toDouble(), hourlyCapital));
      final totalSpots =
          cost.map((s) => FlSpot(s.x, s.y + hourlyCapital)).toList();
      _costData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: cost,
              isCurved: true,
              barWidth: 2,
              color: Colors.purple,
              dotData: const FlDotData(show: false)),
          LineChartBarData(
              spots: capitalSpots,
              isCurved: false,
              barWidth: 2,
              color: Colors.orange,
              dashArray: [4, 4],
              dotData: const FlDotData(show: false)),
          LineChartBarData(
              spots: totalSpots,
              isCurved: true,
              barWidth: 2,
              color: Colors.red,
              dotData: const FlDotData(show: false)),
        ],
        minY: 0,
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: const FlGridData(
            show: true, verticalInterval: 1, horizontalInterval: 500),
      );
    });
  }

  Widget _buildSummary(SimSummary s) {
    final shortfallColor = s.shortfallMWh > 0 ? Colors.red : Colors.green;

    String fmtDollars(int v) =>
        '\$${v.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';

    Widget cell(String label, String value, {Color? valueColor}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10,
                    color: Colors.black54,
                    fontWeight: FontWeight.w500)),
            Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: valueColor)),
          ],
        ),
      );
    }

    Widget hrow(List<Widget> cells) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade50,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '24-Hour Simulation Summary',
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1),
            ),
          ),
          const Divider(height: 10),
          hrow([
            cell('Demand', '${s.totalDemandMWh.toStringAsFixed(0)} MWh'),
            cell('Produced', '${s.totalProducedMWh.toStringAsFixed(0)} MWh'),
            cell(
              'Shortfall',
              s.shortfallMWh > 0
                  ? '${s.shortfallMWh.toStringAsFixed(0)} MWh'
                  : 'none',
              valueColor: shortfallColor,
            ),
            cell(
              'Surplus',
              s.surplusMWh > 0
                  ? '${s.surplusMWh.toStringAsFixed(0)} MWh'
                  : 'none',
            ),
          ]),
          const Divider(height: 10),
          hrow([
            cell('Renewable',
                '${s.renewableMWh.toStringAsFixed(0)} MWh (${s.renewablePercent.toStringAsFixed(1)}%)'),
            cell('Battery',
                '${s.batteryMWh.toStringAsFixed(0)} MWh (${s.batteryPercent.toStringAsFixed(1)}%)'),
            cell(
              'Carbon',
              '${s.carbonMWh.toStringAsFixed(0)} MWh (${s.carbonPercent.toStringAsFixed(1)}%)',
              valueColor: s.carbonMWh > 0 ? Colors.orange : Colors.green,
            ),
          ]),
          const Divider(height: 10),
          hrow([
            cell('Capital Cost', fmtDollars(s.totalCapitalCost)),
            cell('Daily Loan Repayment',
                '\$${s.dailyLoanRepayment.toStringAsFixed(0)} / day'),
            if (s.totalDemandMWh > 0)
              cell('Loan / kWh',
                  '\$${(s.dailyLoanRepayment / (s.totalDemandMWh * 1000)).toStringAsFixed(4)}'),
            cell('Operational Cost', fmtDollars(s.totalCost)),
            if (s.totalDemandMWh > 0)
              cell('Operational / kWh',
                  '\$${(s.totalCost / (s.totalDemandMWh * 1000)).toStringAsFixed(4)}'),
            if (s.totalDemandMWh > 0)
              cell('Total / kWh',
                  '\$${((s.totalCost + s.dailyLoanRepayment) / (s.totalDemandMWh * 1000)).toStringAsFixed(4)}'),
          ]),
        ],
      ),
    );
  }

  // ── Optimiser ────────────────────────────────────────────────────────────

  void _optimize() {
    if (_lastWeather == null) return;
    final result = optimize(
      _city,
      _generators,
      _batteries,
      _optimizeMode,
      _lastWeather!,
      includeBaseload: _includeBaseload,
    );
    setState(() {
      _generators = result.generators;
      _batteries = result.batteries;
    });
    _runSim(_lastWeather!);
  }

  void _convertGenerator(int index, String toType) {
    final existing = _generators[index];
    final replacement = switch (toType) {
      'solar' => GeneratorSolar(existing.megawattMax) as Generator,
      'wind' => GeneratorWind(existing.megawattMax),
      'carbon' => GeneratorCarbon(existing.megawattMax),
      _ => throw Exception('Unknown type'),
    };
    _generators[index] = replacement;
    if (_lastWeather != null) {
      _runSim(_lastWeather!);
    } else {
      setState(() => _summary = null);
    }
  }

  void _removeGenerator(int index) {
    if (_generators.length <= 1) return;
    _generators.removeAt(index);
    if (_lastWeather != null) {
      _runSim(_lastWeather!);
    } else {
      setState(() {});
    }
  }

  void _addGenerator(int mw) {
    _generators.add(GeneratorCarbon(mw));
    if (_lastWeather != null) {
      _runSim(_lastWeather!);
    } else {
      setState(() {});
    }
  }

  void _addBattery(int mwh) {
    _batteries.add(Battery(mwh.toDouble(), (mwh / 2).toDouble()));
    if (_lastWeather != null) {
      _runSim(_lastWeather!);
    } else {
      setState(() {});
    }
  }

  void _removeBattery(int index) {
    _batteries.removeAt(index);
    if (_lastWeather != null) {
      _runSim(_lastWeather!);
    } else {
      setState(() {});
    }
  }

  Widget _buildBatteryCard(int index, Battery b) {
    const color = Colors.orange;
    final count = _batteries.length;
    final chargedMWh =
        count > 0 ? (_summary?.batteryChargedMWh ?? 0.0) / count : 0.0;
    final dischargedMWh =
        count > 0 ? (_summary?.batteryMWh ?? 0.0) / count : 0.0;
    final chargeUtil =
        b.capacityMWh > 0 ? (chargedMWh / b.capacityMWh).clamp(0.0, 1.0) : 0.0;
    final dischargeUtil = b.capacityMWh > 0
        ? (dischargedMWh / b.capacityMWh).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      width: 240,
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: const Border(left: BorderSide(color: color, width: 4)),
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.battery_charging_full, size: 16, color: color),
                const SizedBox(width: 6),
                const Text(
                  'Battery',
                  style: TextStyle(fontWeight: FontWeight.bold, color: color),
                ),
                const Spacer(),
                Text('${b.capacityMWh.toStringAsFixed(0)} MWh',
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => _removeBattery(index),
                  borderRadius: BorderRadius.circular(10),
                  child:
                      const Icon(Icons.close, size: 14, color: Colors.black38),
                ),
              ],
            ),
            Text(
              'max ${b.maxPowerMW.toStringAsFixed(0)} MW',
              style: const TextStyle(fontSize: 10, color: Colors.black45),
            ),
            if (_summary != null) ...[
              const SizedBox(height: 4),
              // Charge bar (green)
              Row(
                children: [
                  const SizedBox(
                      width: 68,
                      child: Text('Charged',
                          style:
                              TextStyle(fontSize: 10, color: Colors.black54))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: chargeUtil,
                        minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.green),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                '${chargedMWh.toStringAsFixed(0)} MWh  '
                '(${(chargeUtil * 100).toStringAsFixed(0)}% of cap)',
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
              const SizedBox(height: 4),
              // Discharge bar (red)
              Row(
                children: [
                  const SizedBox(
                      width: 68,
                      child: Text('Discharged',
                          style:
                              TextStyle(fontSize: 10, color: Colors.black54))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: dischargeUtil,
                        minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(Colors.red),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                '${dischargedMWh.toStringAsFixed(0)} MWh  '
                '(${(dischargeUtil * 100).toStringAsFixed(0)}% of cap)',
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGeneratorCard(int index, Generator g) {
    final color = switch (g.type()) {
      'solar' => Colors.amber,
      'wind' => Colors.lightBlue,
      _ => Colors.blueGrey,
    };
    final icon = switch (g.type()) {
      'solar' => Icons.wb_sunny,
      'wind' => Icons.air,
      _ => Icons.factory,
    };
    final maxMWh = g.megawattMax * 24.0;
    final generatedMWh = g.total().megawattHoursGenerated;
    final utilization =
        maxMWh > 0 ? (generatedMWh / maxMWh).clamp(0.0, 1.0) : 0.0;
    return Container(
      width: 240,
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 4)),
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Text(
                  '${g.type()[0].toUpperCase()}${g.type().substring(1)}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color.withValues(alpha: 0.85)),
                ),
                const Spacer(),
                Text('${g.megawattMax} MW',
                    style: const TextStyle(fontSize: 12)),
                if (_generators.length > 1) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => _removeGenerator(index),
                    borderRadius: BorderRadius.circular(10),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.black38),
                  ),
                ],
              ],
            ),
            if (g is GeneratorCarbon) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  _convertButton(index, 'solar', Colors.amber, Icons.wb_sunny),
                  const SizedBox(width: 6),
                  _convertButton(index, 'wind', Colors.lightBlue, Icons.air),
                ],
              ),
            ] else ...[
              const SizedBox(height: 4),
              _convertButton(index, 'carbon', Colors.blueGrey, Icons.factory),
            ],
            if (_summary != null) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: utilization,
                  minHeight: 5,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${generatedMWh.toStringAsFixed(0)} / ${maxMWh.toStringAsFixed(0)} MWh  '
                '(${(utilization * 100).toStringAsFixed(0)}%)',
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _convertButton(int index, String toType, Color color, IconData icon) {
    return InkWell(
      onTap: () => _convertGenerator(index, toType),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              '→ ${toType[0].toUpperCase()}${toType.substring(1)}',
              style: TextStyle(
                  fontSize: 10, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _assumptionRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Expanded(
            flex: 2,
            child: Text(value,
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _assumptionSection(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(title,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
        const Divider(height: 6),
        ...rows,
      ],
    );
  }

  Widget _buildAssumptionsDrawer() {
    return Drawer(
      width: 320,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Model Assumptions',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                _assumptionSection('Carbon Generators', [
                  _assumptionRow('Capital cost',
                      '\$${(carbonCapitalCostPerMw / 1000).round()}k / MW'),
                  _assumptionRow(
                      'Operating cost', '\$$carbonCostPerMwh / MWh dispatched'),
                  _assumptionRow('O&M cost',
                      '\$$carbonOMCostPerMwh / MWh capacity (always)'),
                  _assumptionRow('Dispatch', 'On-demand to fill gap'),
                ]),
                _assumptionSection('Solar Generators', [
                  _assumptionRow('Capital cost',
                      '\$${(solarCapitalCostPerMw / 1000).round()}k / MW'),
                  _assumptionRow(
                      'Operating cost', '\$$solarCostPerMwh / MWh dispatched'),
                  _assumptionRow('O&M cost',
                      '\$$solarOMCostPerMwh / MWh capacity (always)'),
                  _assumptionRow('Output', 'Scales with sun % (0–100)'),
                  _assumptionRow('Dispatch', 'Always at full sun capacity'),
                ]),
                _assumptionSection('Wind Generators', [
                  _assumptionRow('Capital cost',
                      '\$${(windCapitalCostPerMw / 1000).round()}k / MW'),
                  _assumptionRow(
                      'Operating cost', '\$$windCostPerMwh / MWh dispatched'),
                  _assumptionRow('O&M cost',
                      '\$$windOMCostPerMwh / MWh capacity (always)'),
                  _assumptionRow(
                      'Min wind', '$windMinKmh km/h (no output below)'),
                  _assumptionRow(
                      'Max wind', '$windMaxKmh km/h (shutdown above)'),
                  _assumptionRow(
                      'Output', 'Linear between min and max wind speed'),
                  _assumptionRow('Dispatch', 'Always at full wind capacity'),
                ]),
                _assumptionSection('Battery Storage', [
                  _assumptionRow('Capital cost',
                      '\$${(batteryCapitalCostPerMwh / 1000).round()}k / MWh'),
                  _assumptionRow('Discharge cost',
                      '\$$batteryCostPerMwhDischarged / MWh discharged'),
                  _assumptionRow('O&M cost',
                      '\$$batteryOMCostPerMwh / MWh capacity (always)'),
                  _assumptionRow('Max power', '50% of capacity (MWh → MW)'),
                  _assumptionRow('Charge', 'Absorbs surplus renewable first'),
                  _assumptionRow(
                      'Discharge', 'Fills gap before carbon dispatch'),
                ]),
                _assumptionSection('Demand Model', [
                  _assumptionRow('Base demand',
                      '${mwPerThousandPeople.toStringAsFixed(0)} MW per 1,000 people'),
                  _assumptionRow('Minimum', '$minCityDemandMw MW'),
                  _assumptionRow('Extreme temp (≤10 or ≥30 °C)',
                      '×$extremeTempDemandMultiplier'),
                  _assumptionRow('Night (0–5h)', '×0.60'),
                  _assumptionRow('Early morning (6–7h)', '×0.75'),
                  _assumptionRow('Morning peak (8–10h)', '×1.00'),
                  _assumptionRow('Midday (11–14h)', '×0.85'),
                  _assumptionRow('Afternoon (15–17h)', '×0.90'),
                  _assumptionRow('Evening peak (18–21h)', '×1.10'),
                  _assumptionRow('Late night (22–23h)', '×0.70'),
                ]),
                _assumptionSection('Capital Financing', [
                  _assumptionRow('Loan interest rate',
                      '${(loanInterestRate * 100).toStringAsFixed(0)}%'),
                  _assumptionRow('Loan term', '$loanTermYears years'),
                  _assumptionRow(
                      'Repayment', 'Annuity formula, daily portion shown'),
                ]),
                _assumptionSection('Simulation', [
                  _assumptionRow('Duration', '24 hours'),
                  _assumptionRow('Weather', 'Random per simulation run'),
                  _assumptionRow(
                      'Priority order', 'Renewables → Battery → Carbon'),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              tooltip: 'Assumptions',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
            ),
          ),
        ],
      ),
      endDrawer: _buildAssumptionsDrawer(),
      body: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${_city.name}, ${_city.country} (pop. ${_city.population})',
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                    onPressed: _sim, child: const Text('Create simulation')),
                TextButton(
                    onPressed: _generateCity,
                    child: const Text('Regenerate city')),
              ],
            ),
            if (_summary != null) _buildSummary(_summary!),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(mainAxisAlignment: MainAxisAlignment.start, children: [
                    _chart('Temp (°C)', _tempData),
                    _chart('Sun (%)', _sunData,
                        action: IconButton(
                          icon: Icon(Icons.wb_sunny,
                              size: 18,
                              color: _sunEnabled ? Colors.amber : Colors.grey),
                          tooltip: _sunEnabled ? 'Disable sun' : 'Enable sun',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            setState(() => _sunEnabled = !_sunEnabled);
                            if (_lastWeather != null) _runSim(_lastWeather!);
                          },
                        )),
                    _chart('Wind (km/h)', _windData,
                        action: IconButton(
                          icon: Icon(Icons.air,
                              size: 18,
                              color: _windEnabled
                                  ? Colors.lightBlue
                                  : Colors.grey),
                          tooltip:
                              _windEnabled ? 'Disable wind' : 'Enable wind',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            setState(() => _windEnabled = !_windEnabled);
                            if (_lastWeather != null) _runSim(_lastWeather!);
                          },
                        )),
                  ]),
                  Column(mainAxisAlignment: MainAxisAlignment.start, children: [
                    _chart('Energy (MW)', _energyData, legend: [
                      ('demand', Colors.green),
                      ('produced', Colors.red),
                    ]),
                    _chart('Battery (MWh)', _batteryData, legend: [
                      ('storage', Colors.orange),
                      ('charge', Colors.green),
                      ('discharge', Colors.red),
                    ]),
                    _chart('Cost (\$)', _costData, legend: [
                      ('operational', Colors.purple),
                      ('capital', Colors.orange),
                      ('total', Colors.red),
                    ]),
                  ]),
                  Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_lastWeather != null) ...[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: SizedBox(
                              width: 240,
                              child: FilledButton.icon(
                                onPressed: _optimize,
                                icon: const Icon(Icons.auto_fix_high, size: 16),
                                label: const Text('Optimize'),
                                style: FilledButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  textStyle: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 240,
                            child: RadioGroup<OptimizeMode>(
                              groupValue: _optimizeMode,
                              onChanged: (v) =>
                                  setState(() => _optimizeMode = v!),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (final mode in OptimizeMode.values)
                                    SizedBox(
                                      height: 28,
                                      child: Row(
                                        children: [
                                          Radio<OptimizeMode>(
                                            value: mode,
                                            materialTapTargetSize:
                                                MaterialTapTargetSize
                                                    .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          Text(
                                            switch (mode) {
                                              OptimizeMode.operational =>
                                                'Min operational costs',
                                              OptimizeMode.capital =>
                                                'Min capital costs',
                                              OptimizeMode.both => 'Min both',
                                            },
                                            style:
                                                const TextStyle(fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 240,
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                    value: _includeBaseload,
                                    onChanged: (v) =>
                                        setState(() => _includeBaseload = v!),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Expanded(
                                  child: Text(
                                    'Include baseload for 0 wind/solar days',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          )
                        ],
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Generators',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        ..._generators.indexed
                            .map((e) => _buildGeneratorCard(e.$1, e.$2)),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 240,
                          child: Row(
                            children: [
                              for (final mw in [250, 500, 1000])
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: OutlinedButton(
                                      onPressed: () => _addGenerator(mw),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        textStyle:
                                            const TextStyle(fontSize: 11),
                                      ),
                                      child: Text('+${mw}MW'),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            'Storage',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                        ..._batteries.indexed
                            .map((e) => _buildBatteryCard(e.$1, e.$2)),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 240,
                          child: Row(
                            children: [
                              for (final mwh in [250, 500, 1000])
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: OutlinedButton(
                                      onPressed: () => _addBattery(mwh),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 4),
                                        textStyle:
                                            const TextStyle(fontSize: 11),
                                      ),
                                      child: Text('+${mwh}MWh'),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ])
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
