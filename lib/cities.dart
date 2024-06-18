import 'dart:math';

import 'package:csv/csv.dart';

class City {
  String name;
  String country;
  int population;
  City(this.name, this.country, this.population);

  int baseEnergyRequirement() {
    // megawatts
    return (population / 1000000.0).round() * 1000;
  }

  factory City.empty() {
    return City('', '', 0);
  }

  static List<City> parseCsv(String data) {
    final list = List<City>.empty(growable: true);
    final res = const CsvToListConverter().convert(data);
    for (var index = 1; index < res.length; index++) {
      final cityRow = res[index];
      final name = cityRow[0] as String;
      final country = cityRow[3] as String;
      final population = cityRow[6] as int;
      list.add(City(name, country, population));
    }
    return list;
  }

  static City random(List<City> cities) {
    return cities[Random().nextInt(cities.length)];
  }
}
