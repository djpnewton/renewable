import 'dart:math';

class WeatherPeriod {
  // one hour of weather
  int hour; // hour of day 0 -> 23
  int temp; // degrees C
  int sun; // percentage
  int wind; // km/h
  WeatherPeriod(this.hour, this.temp, this.sun, this.wind);

  String niceTime() {
    assert(hour >= 0 && hour <= 23);
    if (hour == 0) return '12 am';
    if (hour <= 11) return '$hour am';
    if (hour == 12) return '12 pm';
    return '${hour - 12} pm';
  }

  factory WeatherPeriod.sim(int hour, int tempHigh, int tempLow) {
    var rnd = Random();
    var temp = hour / 12.0 * (tempHigh - tempLow) + tempLow;
    if (hour > 12) {
      temp = tempHigh - ((hour - 12) / 12.0 * (tempHigh - tempLow));
    }
    var sun = rnd.nextInt(101); // sun percentage
    if (hour < 7 || hour > 18) {
      sun = 0;
    }
    var wind = rnd.nextInt(101); // wind speed >= 0, <= 100
    return WeatherPeriod(hour, temp.round(), sun, wind);
  }
}

class Weather24h {
  late int tempHigh;
  late int tempLow;
  //late int sunAvg; //TODO
  //late int windAge; //TODO
  late List<WeatherPeriod> periods;

  Weather24h() {
    var rnd = Random();
    tempHigh = rnd.nextInt(30) + 10;
    tempLow = tempHigh - 10;

    periods = [];
    for (var i = 0; i <= 23; i++) {
      periods.add(WeatherPeriod.sim(i, tempHigh, tempLow));
    }
  }
}

class GenerationPeriod {
  // one hour of generation
  int cost; // operational cost in dollars
  double megawattHoursGenerated; // generated power
  double megawattHoursRequired;
  GenerationPeriod(
      this.cost, this.megawattHoursGenerated, this.megawattHoursRequired);

  factory GenerationPeriod.zero() {
    return GenerationPeriod(0, 0, 0);
  }

  GenerationPeriod add(GenerationPeriod gp) {
    return GenerationPeriod(
        cost + gp.cost,
        megawattHoursGenerated + gp.megawattHoursGenerated,
        megawattHoursRequired + gp.megawattHoursRequired);
  }
}

abstract class Generator {
  String type();
  GenerationPeriod generate(WeatherPeriod wp, int percentRequired);
  GenerationPeriod total();
}

class GeneratorCarbon implements Generator {
  int operationCost;
  int megawattMax;
  GenerationPeriod _total = GenerationPeriod.zero();

  GeneratorCarbon(this.operationCost, this.megawattMax);

  @override
  String type() {
    return 'carbon';
  }

  @override
  GenerationPeriod generate(WeatherPeriod wp, int percentRequired) {
    var gp = GenerationPeriod(operationCost, megawattMax * 1.0,
        megawattMax * percentRequired / 100.0);
    _total = _total.add(gp);
    return gp;
  }

  @override
  GenerationPeriod total() {
    return _total;
  }
}

class GeneratorSolar implements Generator {
  int operationCost;
  int megawattMax; // generation capacity at 100% sun
  GenerationPeriod _total = GenerationPeriod.zero();

  GeneratorSolar(this.operationCost, this.megawattMax);

  @override
  String type() {
    return 'solar';
  }

  @override
  GenerationPeriod generate(WeatherPeriod wp, int percentRequired) {
    var gp = GenerationPeriod(operationCost, megawattMax * wp.sun / 100,
        megawattMax * percentRequired / 100.0);
    _total = _total.add(gp);
    return gp;
  }

  @override
  GenerationPeriod total() {
    return _total;
  }
}

class GeneratorWind implements Generator {
  int operationCost;
  int megawattMax; // generation capacity at max windspeed
  int maxWind; // maximum windspeed
  int minWind; // minimum windspeed
  GenerationPeriod _total = GenerationPeriod.zero();

  GeneratorWind(
      this.operationCost, this.megawattMax, this.maxWind, this.minWind);

  @override
  String type() {
    return 'wind';
  }

  @override
  GenerationPeriod generate(WeatherPeriod wp, int percentRequired) {
    assert(minWind >= 0);
    assert(maxWind > minWind);
    var required = megawattMax * percentRequired / 100.0;
    var gp = GenerationPeriod(operationCost, 0, required);
    if (wp.wind <= maxWind && wp.wind >= minWind) {
      gp = GenerationPeriod(operationCost,
          megawattMax * (wp.wind - minWind) / (maxWind - minWind), required);
    }
    _total = _total.add(gp);
    return gp;
  }

  @override
  GenerationPeriod total() {
    return _total;
  }
}

GenerationPeriod generate(WeatherPeriod wp, List<Generator> generators) {
  var gp = GenerationPeriod.zero();
  for (var g in generators) {
    gp = gp.add(g.generate(wp, 100 /*TODO*/));
  }
  return gp;
}
