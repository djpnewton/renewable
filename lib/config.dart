const String gitSha = 'GIT_SHA_REPLACE';
const String buildDate = 'BUILD_DATE_REPLACE';
const String appVersion = 'VERSION_REPLACE';

// ── Capital financing assumptions ────────────────────────────────────────────
/// Annual interest rate for capital loan (e.g. 0.05 = 5%)
const double loanInterestRate = 0.05;

/// Loan repayment term in years
const int loanTermYears = 20;

// ── Generator capital costs ($ per MW of installed capacity) ─────────────────
/// Carbon (NGCC) capital cost per MW
const int carbonCapitalCostPerMw = 1000000; // ~ $1,000 / kW

/// Solar (PV) capital cost per MW
const int solarCapitalCostPerMw = 1000000; // ~ $1,000 / kW

/// Wind (onshore) capital cost per MW
const int windCapitalCostPerMw = 1400000; // ~ $1,400 / kW

// ── Battery capital cost ($ per MWh of storage capacity) ─────────────────────
/// Battery capital cost per MWh
const int batteryCapitalCostPerMwh = 300000; // ~ $300 / kWh

// ── Generator operating costs ($ per MWh dispatched) ───────────────────────
/// Carbon generator operating cost per MWh dispatched
const int carbonCostPerMwh = 35; // ~ 35 USD per MWh

/// Solar generator operating cost per MWh dispatched
const int solarCostPerMwh = 0;

/// Wind generator operating cost per MWh dispatched
const int windCostPerMwh = 0;

// ── Generator O&M costs (operations & maintenance, $ per MWh capacity, always paid) ──
// values from:
//  - https://www.irena.org/-/media/Files/IRENA/Agency/Publication/2025/Jul/IRENA_TEC_RPGC_in_2024_2025.pdf
//  - https://docs.nrel.gov/docs/fy25osti/91775.pdf
//  - https://pv-maps.com/en/blog/solar-om-costs-per-mw
/// Carbon (NGCC) O&M cost per MWh of capacity
const int carbonOMCostPerMwh = 2; // ~ 15 USD per kW per year

/// Solar (photovoltaic) O&M cost per MWh of capacity
const int solarOMCostPerMwh = 1; // ~ 10 USD per kW per year

/// Wind turbine (onshore) O&M cost per MWh of capacity
const int windOMCostPerMwh = 4; // ~ 40 USD per kW per year

// ── Battery operating cost ───────────────────────────────────────────────────
/// Battery cost per MWh discharged
const int batteryCostPerMwhDischarged = 0;

/// Battery O&M cost per MWh of capacity
const int batteryOMCostPerMwh = 1; // ~ 8 USD per kWh per year

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
