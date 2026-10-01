# Adaptive Hedge Basket

Adaptive Hedge Basket is an Expert Advisor for MetaTrader 5 that manages multiple positions as one basket. It evaluates entries from M1 data and uses the previous candle close relative to an exponential moving average to select the first direction.

## Strategy outline

The first basket position follows the direction of the previous M1 close relative to the configured EMA. The optional startup sequence then adds one BUY and one SELL. Later entries follow the short-term EMA direction.

When BUY and SELL position counts are equal, the EA waits until the previous close moves far enough from the configured SMA. It then resumes entries in the EMA direction.

## Basket management

All positions opened by the EA on the current symbol and Magic Number are managed together. Basket profit trailing starts after the configured account-currency profit is reached. The EA records the highest basket profit and closes the basket after profit returns to the calculated floor.

The trailing distance can adapt to the difference between BUY and SELL position counts. A larger net position can use a tighter distance, subject to the configured minimum multiplier.

When a basket is closed, the EA first attempts to offset matching BUY and SELL positions using Close By. Any remaining net positions are closed normally. If Close By is disabled or unavailable, the Market build falls back to normal closing.

## Main inputs

- Trade volume and Magic Number
- EMA and SMA periods
- Startup sequence switch
- Hedge release distance
- Basket trailing start, fixed distance and percentage
- Net-position trailing strength and minimum multiplier
- Optional basket loss limit
- Maximum position count
- Close retry interval and attempt limit

## Requirements

The strategy uses M1 price and indicator data. A hedging account is required to reproduce the intended simultaneous BUY and SELL behavior. Symbol specifications, contract size, spread, commission and swap can materially affect results.

## Risk notice

This EA can open multiple positions and does not place an individual stop loss on each position. The basket loss limit is disabled when set to zero. Test all settings in the Strategy Tester and on a demo account before considering live use.

Historical test results do not guarantee future performance. Leveraged trading involves a high level of risk and may result in substantial losses.
