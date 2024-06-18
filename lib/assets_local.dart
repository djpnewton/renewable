import 'dart:io';

// for running test script

Future<String> getWorldCities() {
  final file = File('../data/worldcities.csv');
  return file.readAsString();
}
