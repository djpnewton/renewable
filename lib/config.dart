const String gitSha = 'GIT_SHA_REPLACE';
const String buildDate = 'BUILD_DATE_REPLACE';

// ── Generator operating costs ($ per MWmax per hour at 100% dispatch) ────────
/// Carbon generator cost per MW of capacity per hour at full output
const int carbonCostPerMwPerHour = 100;

/// Solar fixed operating cost per MW of capacity per hour (weather-dependent output)
const int solarCostPerMwPerHour = 10;

/// Wind fixed operating cost per MW of capacity per hour (weather-dependent output)
const int windCostPerMwPerHour = 8;

// ── Generator maintenance costs ($ per MWmax per hour, always paid) ──────────
/// Carbon generator maintenance cost per MW per hour (paid even when idle)
const int carbonMaintenanceCostPerMwPerHour = 20;

/// Solar panel maintenance cost per MW per hour
const int solarMaintenanceCostPerMwPerHour = 3;

/// Wind turbine maintenance cost per MW per hour
const int windMaintenanceCostPerMwPerHour = 4;

// ── Battery operating cost ───────────────────────────────────────────────────
/// Battery cost per MWh discharged (wear/degradation proxy)
const int batteryCostPerMwhDischarged = 5;

/// Battery maintenance cost per MWh of capacity per hour
const int batteryMaintenanceCostPerMwhPerHour = 2;

// ── Wind turbine operating envelope ──────────────────────────────────────────
/// Wind speed (km/h) below which turbines produce nothing
const int windMinKmh = 15;

/// Wind speed (km/h) above which turbines are shut down (too windy)
const int windMaxKmh = 60;

// ── Demand model ─────────────────────────────────────────────────────────────
/// MW of base demand per 1000 people
const double mwPerThousandPeople = 1.0;

/// Minimum baseline city demand (MW)
const int minCityDemandMw = 100;

/// Additional demand multiplier when temperature ≤ 10 °C or ≥ 30 °C
const double extremeTempDemandMultiplier = 1.2;

/// Time-of-day demand multipliers keyed by hour-of-day (end hour inclusive)
const Map<int, double> timeOfDayMultipliers = {
  5: 0.6, // night
  7: 0.75, // early morning
  10: 1.0, // morning peak
  14: 0.85, // midday lull
  17: 0.9, // afternoon
  21: 1.1, // evening peak
  23: 0.7, // late night
};
