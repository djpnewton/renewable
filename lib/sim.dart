import 'dart:math';

import 'cities.dart';
import 'config.dart';

String niceTime(int hour) {
  assert(hour >= 0 && hour <= 23);
  if (hour == 0) return '12 am';
  if (hour <= 11) return '$hour am';
  if (hour == 12) return '12 pm';
  return '${hour - 12} pm';
}

class WeatherPeriod {
  // one hour of weather
  int hour; // hour of day 0 -> 23
  int temp; // degrees C
  int sun; // percentage
  int wind; // km/h
  WeatherPeriod(this.hour, this.temp, this.sun, this.wind);

  String time() {
    return niceTime(hour);
  }

  int energyDemand(City c) {
    // Time-of-day demand profile
    final double timeMultiplier;
    if (hour <= 5) {
      timeMultiplier = 0.6; // night — low demand
    } else if (hour <= 7) {
      timeMultiplier = 0.75; // early morning ramp
    } else if (hour <= 10) {
      timeMultiplier = 1.0; // morning peak
    } else if (hour <= 14) {
      timeMultiplier = 0.85; // midday lull
    } else if (hour <= 17) {
      timeMultiplier = 0.9; // afternoon
    } else if (hour <= 21) {
      timeMultiplier = 1.1; // evening peak
    } else {
      timeMultiplier = 0.7; // late night
    }
    final double tempMultiplier = (temp > 10 && temp < 30) ? 1.0 : 1.2;
    return (c.baseEnergyRequirement() * timeMultiplier * tempMultiplier)
        .round();
  }

  factory WeatherPeriod.sim(
      int hour, int tempHigh, int tempLow, int sunAvg, int windAvg) {
    var rnd = Random();
    var temp = hour / 12.0 * (tempHigh - tempLow) + tempLow;
    if (hour > 12) {
      temp = tempHigh - ((hour - 12) / 12.0 * (tempHigh - tempLow));
    }
    var sun = sunAvg - 20 + rnd.nextInt(40);
    if (sun < 0) sun = 0;
    if (sun > 100) sun = 100;
    if (hour < 7 || hour > 18) {
      sun = 0;
    }
    var wind = windAvg - 20 + rnd.nextInt(40);
    if (wind < 0) wind = 0;
    if (wind > 100) wind = 100;
    return WeatherPeriod(hour, temp.round(), sun, wind);
  }
}

class Weather24h {
  late int tempHigh;
  late int tempLow;
  late int sunAvg;
  late int windAvg;
  late List<WeatherPeriod> periods;

  Weather24h() {
    var rnd = Random();
    tempHigh = rnd.nextInt(30) + 10; // temp high degrees centigrade
    tempLow = tempHigh - 10; // temp low degrees centigrade
    sunAvg = rnd.nextInt(70) + 30; // sun percentage average
    windAvg = rnd.nextInt(101); // wind speed average >= 0, <= 100

    periods = [];
    for (var i = 0; i <= 23; i++) {
      periods.add(WeatherPeriod.sim(i, tempHigh, tempLow, sunAvg, windAvg));
    }
  }

  /// Private bare constructor – does NOT initialise the late fields.
  Weather24h._();

  /// Creates a deterministic 24-hour weather period for testing/inspection.
  /// Every hour has the same [temp] (°C), [sun] (0–100 %), and [wind] (km/h).
  factory Weather24h.fixed({int temp = 20, int sun = 0, int wind = 0}) {
    final w = Weather24h._();
    w.tempHigh = temp;
    w.tempLow = temp;
    w.sunAvg = sun;
    w.windAvg = wind;
    w.periods = List.generate(24, (h) => WeatherPeriod(h, temp, sun, wind));
    return w;
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
  int get megawattMax;
  int get capitalCost;
  String type();
  GenerationPeriod generate(WeatherPeriod wp, double percentRequired);
  GenerationPeriod total();
  void reset();
}

class GeneratorCarbon implements Generator {
  @override
  int megawattMax;
  GenerationPeriod _total = GenerationPeriod.zero();

  GeneratorCarbon(this.megawattMax);

  int get _costPerHour => (carbonCostPerMwh * megawattMax);
  int get _omCostPerHour => carbonOMCostPerMwh * megawattMax;
  @override
  int get capitalCost => carbonCapitalCostPerMw * megawattMax;

  @override
  String type() {
    return 'carbon';
  }

  @override
  GenerationPeriod generate(WeatherPeriod wp, double percentRequired) {
    var generated = megawattMax * percentRequired / 100.0;
    var gp = GenerationPeriod(
        (_costPerHour * percentRequired / 100).round() + _omCostPerHour,
        generated,
        generated);
    _total = _total.add(gp);
    return gp;
  }

  @override
  GenerationPeriod total() => _total;

  @override
  void reset() => _total = GenerationPeriod.zero();
}

class GeneratorSolar implements Generator {
  @override
  int megawattMax; // generation capacity at 100% sun
  GenerationPeriod _total = GenerationPeriod.zero();

  GeneratorSolar(this.megawattMax);

  int get _costPerHour => solarCostPerMwh * megawattMax;
  int get _omCostPerHour => solarOMCostPerMwh * megawattMax;
  @override
  int get capitalCost => solarCapitalCostPerMw * megawattMax;

  @override
  String type() {
    return 'solar';
  }

  @override
  GenerationPeriod generate(WeatherPeriod wp, double percentRequired) {
    var gp = GenerationPeriod(_costPerHour + _omCostPerHour,
        megawattMax * wp.sun / 100, megawattMax * percentRequired / 100.0);
    _total = _total.add(gp);
    return gp;
  }

  @override
  GenerationPeriod total() => _total;

  @override
  void reset() => _total = GenerationPeriod.zero();
}

class GeneratorWind implements Generator {
  @override
  int megawattMax; // generation capacity at max windspeed
  int maxWind; // maximum windspeed (km/h)
  int minWind; // minimum windspeed (km/h)
  GenerationPeriod _total = GenerationPeriod.zero();

  GeneratorWind(this.megawattMax,
      {this.maxWind = windMaxKmh, this.minWind = windMinKmh});

  int get _costPerHour => windCostPerMwh * megawattMax;
  int get _omCostPerHour => windOMCostPerMwh * megawattMax;
  @override
  int get capitalCost => windCapitalCostPerMw * megawattMax;

  @override
  String type() {
    return 'wind';
  }

  @override
  GenerationPeriod generate(WeatherPeriod wp, double percentRequired) {
    assert(minWind >= 0);
    assert(maxWind > minWind);
    var required = megawattMax * percentRequired / 100.0;
    final totalCost = _costPerHour + _omCostPerHour;
    var gp = GenerationPeriod(totalCost, 0, required);
    if (wp.wind <= maxWind && wp.wind >= minWind) {
      gp = GenerationPeriod(totalCost,
          megawattMax * (wp.wind - minWind) / (maxWind - minWind), required);
    }
    _total = _total.add(gp);
    return gp;
  }

  @override
  GenerationPeriod total() => _total;

  @override
  void reset() => _total = GenerationPeriod.zero();
}

class Battery {
  double capacityMWh;
  double maxPowerMW;
  double chargeMWh;
  int totalCost;

  Battery(this.capacityMWh, this.maxPowerMW)
      : chargeMWh = 0,
        totalCost = 0;

  int get omCostPerHour => (capacityMWh * batteryOMCostPerMwh).round();
  int get capitalCost => (capacityMWh * batteryCapitalCostPerMwh).round();

  /// Returns MWh actually discharged (positive value).
  double discharge(double neededMWh) {
    var available = [neededMWh, maxPowerMW, chargeMWh].reduce(min);
    if (available < 0) available = 0;
    chargeMWh -= available;
    totalCost += (available * batteryCostPerMwhDischarged).round();
    return available;
  }

  /// Returns MWh actually charged (positive value).
  double charge(double availableMWh) {
    var canCharge =
        [availableMWh, maxPowerMW, capacityMWh - chargeMWh].reduce(min);
    if (canCharge < 0) canCharge = 0;
    chargeMWh += canCharge;
    return canCharge;
  }

  void reset() {
    chargeMWh = 0;
    totalCost = 0;
  }
}

class SimSummary {
  final double totalDemandMWh;
  final double totalProducedMWh;
  final double shortfallMWh; // sum of hours where produced < demand
  final double surplusMWh; // sum of hours where produced > demand
  final double renewableMWh; // solar + wind
  final double carbonMWh;
  final double batteryMWh; // net discharged from battery
  final double batteryChargedMWh; // total charged into battery
  final int totalCost;
  final int totalCapitalCost;

  SimSummary({
    required this.totalDemandMWh,
    required this.totalProducedMWh,
    required this.shortfallMWh,
    required this.surplusMWh,
    required this.renewableMWh,
    required this.carbonMWh,
    required this.batteryMWh,
    required this.batteryChargedMWh,
    required this.totalCost,
    required this.totalCapitalCost,
  });

  /// Daily loan repayment using an annuity formula (principal = totalCapitalCost).
  double get dailyLoanRepayment {
    const r = loanInterestRate;
    const n = loanTermYears;
    if (totalCapitalCost == 0) return 0;
    final annualPayment =
        totalCapitalCost * r * pow(1 + r, n) / (pow(1 + r, n) - 1);
    return annualPayment / 365;
  }

  double get renewablePercent =>
      totalProducedMWh > 0 ? renewableMWh / totalProducedMWh * 100 : 0;
  double get carbonPercent =>
      totalProducedMWh > 0 ? carbonMWh / totalProducedMWh * 100 : 0;
  double get batteryPercent =>
      totalProducedMWh > 0 ? batteryMWh / totalProducedMWh * 100 : 0;
}
