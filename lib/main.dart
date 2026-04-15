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
  var _battery = Battery(0, 0);
  SimSummary? _summary;
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
    final rng = Random();
    // generate generators until megawattsRequired is met
    while (megawattsRequired > 0) {
      var gen = switch (rng.nextInt(3)) {
        0 => GeneratorCarbon(1000, 1000),
        1 => GeneratorWind(250, 1000, 60, 15),
        2 => GeneratorSolar(250, 1000),
        _ => throw Exception('Invalid generator type'),
      };
      newGenerators.add(gen);
      megawattsRequired -= gen.megawattMax;
    }
    // battery: 2 hours of base demand as storage, 50% of base demand as max power
    final newBattery = Battery(
        city.baseEnergyRequirement() * 2.0, city.baseEnergyRequirement() * 0.5);
    setState(() {
      _city = city;
      _generators = newGenerators;
      _battery = newBattery;
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
    var w24 = Weather24h();
    printWeather24(w24);
    for (var gen in _generators) {
      gen.reset();
    }
    _battery.reset();
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
        batteryContribution = _battery.discharge(gap);
        gap -= batteryContribution;
      } else {
        batteryAccumHour = _battery.charge(-gap);
      }

      // 3. Carbon fills any remaining gap (dispatchable peaker)
      final carbonGens = _generators.whereType<GeneratorCarbon>().toList();
      final totalCarbonCapacity =
          carbonGens.fold(0, (sum, g) => sum + g.megawattMax);
      var carbonOutput = 0.0;
      var carbonCost = 0;
      if (totalCarbonCapacity > 0 && gap > 0) {
        final carbonPercent =
            min(100, (gap / totalCarbonCapacity * 100).round());
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
      batteryCharge.add(FlSpot(wp.hour.toDouble(), _battery.chargeMWh));
      batteryAccum.add(FlSpot(wp.hour.toDouble(), batteryAccumHour));
      batteryDischarge.add(FlSpot(wp.hour.toDouble(), batteryContribution));

      totalDemand += demandMW;
      totalProduced += totalProducedHour;
      if (totalProducedHour < demandMW) {
        totalShortfall += demandMW - totalProducedHour;
      }
      if (totalProducedHour > demandMW) {
        totalSurplus += totalProducedHour - demandMW;
      }
      totalRenewable += freeOutput;
      totalCarbon += carbonOutput;
      totalBattery += batteryContribution;
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
      _windData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: wind,
              isCurved: true,
              barWidth: 2,
              color: Colors.blue,
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
          _summaryRow('Surplus', '${s.surplusMWh.toStringAsFixed(0)} MWh'),
          const Divider(),
          _summaryRow(
              'Renewable (solar/wind)',
              '${s.renewableMWh.toStringAsFixed(0)} MWh'
                  '  (${s.renewablePercent.toStringAsFixed(1)}%)'),
          _summaryRow(
              'Battery (discharged)', '${s.batteryMWh.toStringAsFixed(0)} MWh'),
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
                    onPressed: _sim, child: const Text('Run simulation')),
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
                  Column(mainAxisAlignment: MainAxisAlignment.start, children: [
                    Text(
                      'Generators (${_generators.length})',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      'Battery: ${_battery.capacityMWh.toStringAsFixed(0)} MWh capacity'
                      ' / ${_battery.maxPowerMW.toStringAsFixed(0)} MW max power',
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                    const SizedBox(height: 4),
                    ..._generators.map(
                      (g) =>
                          Text('Type: ${g.type()}, Max: ${g.megawattMax} MW'),
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
