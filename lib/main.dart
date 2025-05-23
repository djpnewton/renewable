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
  var _tempData = LineChartData();
  var _sunData = LineChartData();
  var _windData = LineChartData();
  var _demandData = LineChartData();
  var _producedData = LineChartData();
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
    // generate generators until megawattsRequired is met
    while (megawattsRequired > 0) {
      // randomly select a generator
      var rng = Random();
      var gen = switch (rng.nextInt(3)) {
        0 => GeneratorCarbon(1000, 1000),
        1 => GeneratorWind(250, 1000, 60, 15),
        2 => GeneratorSolar(250, 1000),
        _ => throw Exception('Invalid generator type'),
      };
      // add generator to list
      _generators.add(gen);
      // decrease megawattsRequired by the generator's max capacity
      megawattsRequired -= gen.megawattMax;
    }
    setState(() {
      _city = city;
      _generators = _generators;
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
      axisSide: meta.axisSide,
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
    List<FlSpot> temp = [];
    List<FlSpot> sun = [];
    List<FlSpot> wind = [];
    List<FlSpot> demand = [];
    List<FlSpot> produced = [];
    List<FlSpot> cost = [];
    for (var wp in w24.periods) {
      printWeather(wp, _city);
      temp.add(FlSpot(wp.hour.toDouble(), wp.temp.toDouble()));
      sun.add(FlSpot(wp.hour.toDouble(), wp.sun.toDouble()));
      wind.add(FlSpot(wp.hour.toDouble(), wp.wind.toDouble()));
      demand.add(FlSpot(wp.hour.toDouble(), wp.energyDemand(_city).toDouble()));
      var totalProduced = 0.0;
      var totalCost = 0;
      for (var gen in _generators) {
        var gp = gen.generate(wp, 100 /*TODO*/);
        totalProduced += gp.megawattHoursGenerated;
        totalCost += gp.cost;
      }
      produced.add(FlSpot(wp.hour.toDouble(), totalProduced));
      cost.add(FlSpot(wp.hour.toDouble(), totalCost.toDouble()));
    }
    setState(() {
      _tempData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: temp,
              isCurved: true,
              barWidth: 2,
              color: Colors.red,
              dotData: const FlDotData(
                show: false,
              )),
        ],
        minY: 0,
        maxY: 40,
        borderData: FlBorderData(
          show: false,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(
          show: true,
          verticalInterval: 1,
          horizontalInterval: 5,
        ),
      );
      _sunData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: sun,
              isCurved: true,
              barWidth: 2,
              color: Colors.yellow,
              dotData: const FlDotData(
                show: false,
              )),
        ],
        minY: 0,
        maxY: 100,
        borderData: FlBorderData(
          show: false,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(
          show: true,
          verticalInterval: 1,
          horizontalInterval: 5,
        ),
      );
      _windData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: wind,
              isCurved: true,
              barWidth: 2,
              color: Colors.blue,
              dotData: const FlDotData(
                show: false,
              )),
        ],
        minY: 0,
        maxY: 100,
        borderData: FlBorderData(
          show: false,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(
          show: true,
          verticalInterval: 1,
          horizontalInterval: 5,
        ),
      );
      _demandData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: demand,
              isCurved: true,
              barWidth: 2,
              color: Colors.green,
              dotData: const FlDotData(
                show: false,
              )),
        ],
        minY: 0,
        maxY: 15000,
        borderData: FlBorderData(
          show: false,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(
          show: true,
          verticalInterval: 1,
          horizontalInterval: 1000,
        ),
      );
      _producedData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: produced,
              isCurved: true,
              barWidth: 2,
              color: Colors.red,
              dotData: const FlDotData(
                show: false,
              )),
        ],
        minY: 0,
        maxY: 15000,
        borderData: FlBorderData(
          show: false,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(
          show: true,
          verticalInterval: 1,
          horizontalInterval: 1000,
        ),
      );
      _costData = LineChartData(
        lineBarsData: [
          LineChartBarData(
              spots: cost,
              isCurved: true,
              barWidth: 2,
              color: Colors.purple,
              dotData: const FlDotData(
                show: false,
              )),
        ],
        minY: 0,
        maxY: 15000,
        borderData: FlBorderData(
          show: false,
        ),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              getTitlesWidget: _bottomTitleWidgets,
            ),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        gridData: const FlGridData(
          show: true,
          verticalInterval: 1,
          horizontalInterval: 1000,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${_city.name}, ${_city.country} (pop. ${_city.population})',
          ),
          TextButton(onPressed: _sim, child: const Text('Run simulation')),
          Row(
            //mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(mainAxisAlignment: MainAxisAlignment.start, children: [
                //  Row(children: [
                _chart('Temp (degrees C)', _tempData),
                _chart('Sun (%)', _sunData),
                //  ]),
                //  Row(children: [
                _chart('Wind (km/h)', _windData),
                //  ]),
              ]),
              Column(mainAxisAlignment: MainAxisAlignment.start, children: [
                _chart('Energy Demand (MW)', _demandData),
                _chart('Energy Produced (MW)', _producedData),
                _chart('Energy Cost (MW/\$)', _costData),
              ]),
              Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  //mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Generators (${_generators.length})',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    ..._generators
                        .map(
                          (g) => Text(
                              'Type: ${g.type()}, Max capacity: ${g.megawattMax}'),
                        )
                        .toList(),
                  ])
            ],
          ),
        ],
      ),
    );
  }
}
