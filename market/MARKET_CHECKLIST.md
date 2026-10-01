# MQL5 Market submission checklist

Prepared against the MQL5 Market rules and publication guidance checked on 2026-10-01.

## Prepared in this repository

- Product name candidate: `Adaptive Hedge Basket`
- Market source candidate: `source/AdaptiveHedgeBasket.mq5`
- English product description: `descriptions/PRODUCT_DESCRIPTION_EN.md`
- Japanese product description: `descriptions/PRODUCT_DESCRIPTION_JA.md`
- Logo files: `assets/logo-200.png`, `assets/logo-140.png`, `assets/logo-60.png`
- Version property set to `1.00` in the Market source candidate
- Input names, runtime messages and product copy written in English
- No DLL, WebRequest, external licensing or affiliate link inside the EA
- Order-volume and available-margin checks added before opening positions
- Non-M1 charts now produce a notice instead of an initialization failure; calculations continue to use M1 data
- Normal-close fallback added when Close By is disabled or unavailable

## Required before submission

- [ ] Confirm the final product name.
- [ ] Choose the sale price. Paid Market products currently have a minimum price of USD 30.
- [ ] Choose the number of activations between 5 and 20.
- [ ] Complete MQL5 Seller registration and identity verification in English.
- [ ] Compile `AdaptiveHedgeBasket.mq5` in the latest MetaEditor and confirm zero errors and zero warnings.
- [ ] Produce the final EX5. Only the compiled EX5 is uploaded as the Market product.
- [ ] Run tests on a MetaQuotes-Demo account using multiple symbols, timeframes and small deposits.
- [ ] Confirm operation on both hedging and netting validation environments. The intended strategy behavior requires hedging, so netting-account behavior remains a review item.
- [ ] Test invalid lot sizes, insufficient margin, disabled trading, market closure and unavailable Close By.
- [ ] Test basket closing after partial trade-operation failures.
- [ ] Decide and document safe default values for `InpBasketLossMoney` and `InpMaxPositions`.
- [ ] Capture English Strategy Tester screenshots after tests pass.
- [ ] Prepare at least one screenshot with one side between 720 and 1920 pixels, no larger than 2 MB. Up to 12 screenshots can be uploaded.
- [ ] Clearly label backtest results as historical tests, not live trading.
- [ ] Upload the EX5 and resolve every automatic-validation report before publication.

## Marketplace copy rules

- Do not promise, guarantee or imply profit.
- Do not call the product the best, safest or most profitable.
- Do not present backtests as live results.
- Do not include external URLs, broker links, affiliate links, messenger links, ads, emojis or special promotional symbols.
- Product support must use MQL5 comments or the MQL5 messaging system.
- Do not publish separate products that only change symbols, timeframes or input presets.

The Exness affiliate link in the public GitHub README must not be copied into the MQL5 Market description or embedded in the EA. Market rules prohibit third-party links and broker affiliate advertising in products.

## Source visibility decision

The GitHub repository is currently public. Publishing the Market source candidate to the public repository makes the source code freely downloadable even if the compiled EX5 is sold through MQL5 Market. Before commercial launch, decide whether to make the repository private or keep only non-commercial documentation in the public repository.

Changing a GitHub repository from public to private does not remove copies that may already have been cloned or cached.
