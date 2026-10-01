# MQL5 Market submission values

Use these values when creating the product in the MQL5 Market control panel.

## Common

| Field | Value |
|---|---|
| Platform | MetaTrader 5 |
| Program type | Expert Advisor |
| Product name | Adaptive Hedge Basket |
| Version | 1.00 |
| Distribution | Paid rental |
| Unlimited purchase | Off |
| 1-month rental | On — USD 49 |
| 3-month rental | Off |
| 6-month rental | Off |
| 12-month rental | Off |
| Activations | 5 |

The Market service handles expiration and license protection. Do not add custom expiration, payment or license checks to the EA.

## Files

| Purpose | Repository file |
|---|---|
| Source to compile | `source/AdaptiveHedgeBasket.mq5` |
| Product file to upload | `AdaptiveHedgeBasket.ex5` after compilation |
| English description | `descriptions/PRODUCT_DESCRIPTION_EN.md` |
| Japanese description | `descriptions/PRODUCT_DESCRIPTION_JA.md` |
| 200 x 200 logo | `assets/logo-200.png` |
| 140 x 140 logo | `assets/logo-140.png` |
| 60 x 60 logo | `assets/logo-60.png` |

## Options to select

- Use the Expert Advisor category that best matches automated trading.
- Do not add an Exness link, broker name, affiliate message or external support URL.
- Provide support through the MQL5 product comments and MQL5 messages.
- Do not state expected daily or monthly profit in the product title or description.
- Label every backtest screenshot as a historical test.

## Pending owner actions

1. Complete MQL5 Seller registration and identity verification.
2. Compile the source with the latest MetaEditor with zero errors and zero warnings.
3. Complete the test matrix in `MARKET_CHECKLIST.md`.
4. Create English screenshots from verified Strategy Tester results.
5. Create the product at `https://www.mql5.com/en/market/new_product/mt5`.
6. Enter the values above, upload descriptions, logos and screenshots.
7. Upload the compiled EX5 in the Versions section.
8. Review the automatic validation report and correct every error before publishing.
