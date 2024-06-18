import 'package:flutter/services.dart';

// for running test flutter app

Future<String> getWorldCities() {
  return rootBundle.loadString('data/worldcities.csv');
}
