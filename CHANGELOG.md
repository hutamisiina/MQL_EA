# Changelog

## 0.70 - 2026-10-01

- Changed the first basket entry from a fixed BUY to the direction of the previous M1 close relative to EMA 10.
- Enabled the startup BUY and SELL sequence by default.
- Restored the basket trailing defaults to a start profit of 100 and fixed distance of 30 account-currency units.
- Limited the default maximum position count to 100.

## 0.60 - 2026-10-01

- Added Close By processing for hedged BUY and SELL pairs.
- Added net-exposure adaptive basket trailing.
- Added persistent close retries.
