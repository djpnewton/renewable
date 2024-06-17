import 'package:logging/logging.dart';

import 'sim.dart';
import 'cities.dart';

final log = Logger('testlogger');

void printWeather24(Weather24h w24) {
  log.info(':: 24 hour weather outlook ::');
  log.info('  temperature high: ${w24.tempHigh} c');
  log.info('  temperature low: ${w24.tempLow} c');
  log.info('  sun avg: ${'TODO'}%');
  log.info('  wind avg: ${'TODO'} km/h');
}

void printWeather(WeatherPeriod wp) {
  log.info(':: ${wp.niceTime()} ::');
  log.info('  temperature: ${wp.temp} c');
  log.info('  sun: ${wp.sun}%');
  log.info('  wind: ${wp.wind} km/h');
}

void printGeneration(Generator g, GenerationPeriod gp) {
  log.info('  ::${g.type()} generator::');
  log.info('    cost: \$${gp.cost}');
  log.info('    energy: ${gp.megawattHoursGenerated} MWh');
  log.info('    MWh/\$: ${gp.megawattHoursGenerated / gp.cost}');
}

void printCity(City c) {
  log.info('::${c.name}, ${c.country} (${c.population} pop)::');
  log.info('  energy requirements: ${c.baseEnergyRequirement()} MW');
}

void main() {
  Logger.root.level = Level.ALL; // defaults to Level.INFO
  Logger.root.onRecord.listen((record) {
    // ignore: avoid_print
    print('${record.level.name}: ${record.time}: ${record.message}');
  });

  var coal = GeneratorCarbon(1000, 1000);
  var wind = GeneratorWind(250, 1000, 60, 15);
  var solar = GeneratorSolar(250, 1000);

  var w24 = Weather24h();
  printWeather24(w24);
  for (var wp in w24.periods) {
    printWeather(wp);

    var gp = coal.generate(wp, 100 /*TODO*/);
    printGeneration(coal, gp);

    gp = wind.generate(wp, 100 /*TODO*/);
    printGeneration(wind, gp);

    gp = solar.generate(wp, 100 /*TODO*/);
    printGeneration(solar, gp);
  }

  log.info(':: TOTALS ::');
  printGeneration(coal, coal.total());
  printGeneration(wind, wind.total());
  printGeneration(solar, solar.total());

  printCity(City.random(City.parseCsv()));
}
