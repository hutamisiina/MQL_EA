# Changelog

## 1.01 - 2026-10-01

- Renamed the current EA to `AdaptiveHedgeBasket_v1.01.mq5`.
- Changed adaptive exposure calculations from position counts to actual BUY and SELL lot volumes.
- Added validation of trade-server return codes and executed deal IDs.
- Added combined margin checks and rollback protection for the initial BUY/SELL hedge layer, with full-basket close retries if rollback itself fails.
- Persisted the active trailing peak and floor across terminal or VPS restarts.
- Stopped initialization on non-hedging accounts.
- Kept normal-close fallback when Close By is disabled or unavailable.
- Changed the default initial hedge setting to disabled.
- Changed the default trailing start/fixed distance to 1.0/0.3 and documented lot-based tuning.
- Changed the default maximum position count to 9,999,999.

## 0.70 - 2026-10-01

- Changed the first basket entry from a fixed BUY to the direction of the previous M1 close relative to EMA 10.
- Enabled the startup BUY and SELL sequence by default.
- Restored the basket trailing defaults to a start profit of 100 and fixed distance of 30 account-currency units.
- Limited the default maximum position count to 100.

## 0.60 - 2026-10-01

- Added Close By processing for hedged BUY and SELL pairs.
- Added net-exposure adaptive basket trailing.
- Added persistent close retries.
