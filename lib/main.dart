import 'dart:math';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:renewable/config.dart';

import 'cities.dart';
import 'assets.dart';
import 'sim.dart';
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
      home: const MyHomePage(title: 'Renewable'),
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
      var gen = GeneratorCarbon(1000, 1000);
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

  Widget _chart(String title, LineChartData data) {
    return Column(children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 2,
        ),
        textAlign: TextAlign.center,
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
    for (var wp in w24.periods) {
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
      final totalCostHour = freeCost + carbonCost;
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
      _costData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: cost,
              isCurved: true,
              barWidth: 2,
              color: Colors.purple,
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

  Widget _summaryRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 220,
            child: Text(label,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
          Text(value,
              style: TextStyle(color: valueColor, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildSummary(SimSummary s) {
    final shortfallColor = s.shortfallMWh > 0 ? Colors.red : Colors.green;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade50,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '24-Hour Simulation Summary',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
          ),
          const Divider(),
          _summaryRow(
              'Total Demand', '${s.totalDemandMWh.toStringAsFixed(0)} MWh'),
          _summaryRow(
              'Total Produced', '${s.totalProducedMWh.toStringAsFixed(0)} MWh'),
          _summaryRow(
              'Shortfall',
              s.shortfallMWh > 0
                  ? '${s.shortfallMWh.toStringAsFixed(0)} MWh'
                  : 'none',
              valueColor: shortfallColor),
          _summaryRow(
              'Surplus',
              s.surplusMWh > 0
                  ? '${s.surplusMWh.toStringAsFixed(0)} MWh'
                  : 'none'),
          const Divider(),
          _summaryRow(
              'Renewable (solar/wind)',
              '${s.renewableMWh.toStringAsFixed(0)} MWh'
                  '  (${s.renewablePercent.toStringAsFixed(1)}%)'),
          _summaryRow(
              'Battery (discharged)',
              '${s.batteryMWh.toStringAsFixed(0)} MWh'
                  '  (${s.batteryPercent.toStringAsFixed(1)}%)'),
          _summaryRow(
              'Carbon',
              '${s.carbonMWh.toStringAsFixed(0)} MWh'
                  '  (${s.carbonPercent.toStringAsFixed(1)}%)',
              valueColor: s.carbonMWh > 0 ? Colors.orange : Colors.green),
          const Divider(),
          _summaryRow('Total Operational Cost',
              '\$${s.totalCost.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}'),
          if (s.totalDemandMWh > 0)
            _summaryRow('Cost per kWh',
                '\$${(s.totalCost / (s.totalDemandMWh * 1000)).toStringAsFixed(4)}'),
        ],
      ),
    );
  }

  void _convertGenerator(int index, String toType) {
    final existing = _generators[index];
    final replacement = switch (toType) {
      'solar' => GeneratorSolar(250, existing.megawattMax) as Generator,
      'wind' => GeneratorWind(250, existing.megawattMax, 60, 15),
      'carbon' => GeneratorCarbon(1000, existing.megawattMax),
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
    _generators.add(GeneratorCarbon(mw, mw));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
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
                    _chart('Temp (degrees C)', _tempData),
                    _chart('Sun (%)', _sunData),
                    _chart('Wind (km/h)', _windData),
                  ]),
                  Column(mainAxisAlignment: MainAxisAlignment.start, children: [
                    _chart('Energy: Demand (green) vs Produced (red) (MW)',
                        _energyData),
                    _chart(
                        'Battery: Storage (orange) / Charge (green) / Discharge (red) (MWh)',
                        _batteryData),
                    _chart('Operational Cost (\$)', _costData),
                  ]),
                  Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
