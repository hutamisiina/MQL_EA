#property strict
#property copyright "hutamisiina"
#property version   "1.01"
#property description "Adaptive Hedge Basket - EMA initial direction, adaptive trailing and Close By management"

#include <Trade/Trade.mqh>

CTrade trade;

// =========================
// Inputs
// =========================
input long   InpMagic                = 36291761;
input double InpLots                 = 0.01;

// Basket startup:
// 1st M1: enter in the EMA direction.
// 2nd M1: optionally add one BUY and one SELL to create an initial hedge layer.
input bool   InpUseInitialHedge      = false;

// Direction logic
input int    InpEMA_Period           = 10;
input int    InpSMA_Period           = 7;

// When BuyCount == SellCount, wait until |Close[1]-SMA| >= threshold.
// A distance near 0.8 was used during the original XAUUSD M1 tests.
input double InpHedgeReleaseDistance = 0.80;

// Basket profit trailing.
// Once basket profit reaches TrailStartProfit, do NOT close immediately.
// Instead, remember the peak basket profit and close after a pullback.
//
// Example:
// start=1.0, fixed distance=0.3, percent=20
// peak=1.0 -> floor=1.0 (minimum locked profit)
// peak=1.5 -> floor=1.2
// peak=3.0 -> floor=2.4
//
// The floor never falls below TrailStartProfit once trailing has activated.
input bool   InpUseBasketTrailing     = true;
// Default 1.0 assumes InpLots=0.01. Adjust roughly in proportion to InpLots.
input double InpTrailStartProfit      = 1.0;
// Default 0.3 is tuned for TrailStartProfit=1.0. Re-tune it when changing
// TrailStartProfit (30% of the start profit is the initial reference).
input double InpTrailFixedDistance    = 0.3;
input double InpTrailPercent          = 20.0;

// Net-position adaptive trailing.
// netRatio = abs(BUY_lots - SELL_lots) / total_lots
//
// adjustedTrail = baseTrail * multiplier
// multiplier = max(MinTrailMultiplier,
//                  1 - NetTrailStrength * netRatio)
//
// Examples with strength=0.70:
// netRatio 0.00 -> x1.00
// netRatio 0.30 -> x0.79
// netRatio 0.60 -> x0.58
// netRatio 1.00 -> x0.30, but MinTrailMultiplier limits the minimum.
input bool   InpUseNetPositionTrail   = true;
input double InpNetTrailStrength      = 0.70;
input double InpMinTrailMultiplier    = 0.40;

// Optional legacy fixed TP. Used only when trailing is disabled.
// Set 0 to disable.
input double InpBasketProfitMoney     = 100.0;

// Unknown original loss-exit rule, therefore disabled by default.
// Use a positive number to enable absolute-money stop.
input double InpBasketLossMoney       = 0.0;

// Safety / test controls
input int    InpMaxPositions         = 9999999;
input bool   InpWarnIfChartNotM1     = true;
input bool   InpPrintDebug           = true;

// Close retry protection
input int    InpCloseRetrySeconds     = 2;     // retry interval while basket is closing
input int    InpCloseMaxAttempts      = 0;     // 0 = unlimited

// Basket close method:
// First offset BUY/SELL pairs with Close By.
// Only after one side is fully gone, close the remaining net positions normally.
input bool   InpUseCloseByForHedge    = true;

// =========================
// State
// =========================
datetime g_last_bar_time = 0;
datetime g_basket_start_bar = 0;
int      g_basket_age_bars = 0;

int g_ema_handle = INVALID_HANDLE;
int g_sma_handle = INVALID_HANDLE;

// Persistent basket-close state
bool     g_closing_basket      = false;
datetime g_last_close_attempt  = 0;
int      g_close_attempts      = 0;
string   g_close_reason        = "";

// Basket trailing state
bool   g_trailing_active       = false;
double g_peak_basket_profit    = 0.0;
double g_trailing_floor        = 0.0;

// =========================
// Helpers
// =========================
void Debug(string msg)
{
   if(InpPrintDebug)
      Print("[HypothesisEA] ", msg);
}

bool IsOurPosition()
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   long magic = PositionGetInteger(POSITION_MAGIC);
   return (magic == InpMagic);
}

int CountPositions(ENUM_POSITION_TYPE type)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsOurPosition())
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }

   return count;
}

int CountAllPositions()
{
   return CountPositions(POSITION_TYPE_BUY) +
          CountPositions(POSITION_TYPE_SELL);
}

double BasketProfit()
{
   double total = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsOurPosition())
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }

   return total;
}

bool SymbolSupportsCloseBy()
{
   long order_mode = 0;

   if(!SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE, order_mode))
      return false;

   return ((order_mode & SYMBOL_ORDER_CLOSEBY) == SYMBOL_ORDER_CLOSEBY);
}

bool ValidateOrderVolume(double volume, string &message)
{
   double min_volume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(min_volume <= 0.0 || max_volume <= 0.0 || volume_step <= 0.0)
   {
      message = "Unable to read symbol volume limits.";
      return false;
   }

   if(volume < min_volume || volume > max_volume)
   {
      message = StringFormat(
         "Volume %.8f is outside the allowed range %.8f to %.8f.",
         volume, min_volume, max_volume
      );
      return false;
   }

   double steps = MathRound(volume / volume_step);
   double normalized_volume = steps * volume_step;

   if(MathAbs(normalized_volume - volume) > 0.0000001)
   {
      message = StringFormat(
         "Volume %.8f does not match the symbol volume step %.8f.",
         volume, volume_step
      );
      return false;
   }

   message = "Volume is valid.";
   return true;
}

bool CalculateRequiredMargin(ENUM_ORDER_TYPE order_type,
                             double volume,
                             double &required_margin)
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      Debug("Margin check failed: current tick is unavailable.");
      return false;
   }

   double price = (order_type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   required_margin = 0.0;

   if(price <= 0.0 ||
      !OrderCalcMargin(order_type, _Symbol, volume, price, required_margin))
   {
      Debug("Margin calculation failed. Error=" + (string)GetLastError());
      return false;
   }

   return true;
}

bool HasEnoughMargin(ENUM_ORDER_TYPE order_type, double volume)
{
   double required_margin = 0.0;
   if(!CalculateRequiredMargin(order_type, volume, required_margin))
      return false;

   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(required_margin > free_margin)
   {
      Debug("Not enough free margin. Required=" +
            DoubleToString(required_margin, 2) +
            " free=" + DoubleToString(free_margin, 2));
      return false;
   }

   return true;
}

bool HasEnoughMarginForInitialHedge(double volume)
{
   double buy_margin = 0.0;
   double sell_margin = 0.0;

   if(!CalculateRequiredMargin(ORDER_TYPE_BUY, volume, buy_margin) ||
      !CalculateRequiredMargin(ORDER_TYPE_SELL, volume, sell_margin))
      return false;

   double required_margin = buy_margin + sell_margin;
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(required_margin > free_margin)
   {
      Debug("Initial hedge skipped: not enough free margin. Required=" +
            DoubleToString(required_margin, 2) +
            " free=" + DoubleToString(free_margin, 2));
      return false;
   }

   return true;
}

bool TradeRetcodeExecuted()
{
   uint retcode = trade.ResultRetcode();
   return (retcode == TRADE_RETCODE_DONE ||
           retcode == TRADE_RETCODE_DONE_PARTIAL);
}

bool TradeDealExecuted(bool request_ok)
{
   return (request_ok &&
           TradeRetcodeExecuted() &&
           trade.ResultDeal() != 0);
}

void DebugTradeFailure(string operation)
{
   Debug(operation + " failed: retcode=" +
         (string)trade.ResultRetcode() + " " +
         trade.ResultRetcodeDescription());
}

ulong TrailingStateScopeHash()
{
   string scope = (string)AccountInfoInteger(ACCOUNT_LOGIN) + "|" +
                  (string)InpMagic + "|" + _Symbol;
   ulong hash = 1469598103934665603;

   for(int i = 0; i < StringLen(scope); ++i)
   {
      hash ^= (ulong)StringGetCharacter(scope, i);
      hash *= 1099511628211;
   }

   return hash;
}

string TrailingStateKey(string field)
{
   return "AHB_" + (string)TrailingStateScopeHash() + "_" + field;
}

datetime EarliestOurPositionTime()
{
   datetime earliest = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurPosition())
         continue;

      datetime position_time =
         (datetime)PositionGetInteger(POSITION_TIME);

      if(earliest == 0 || position_time < earliest)
         earliest = position_time;
   }

   return earliest;
}

void ClearPersistentTrailingState()
{
   GlobalVariableDel(TrailingStateKey("active"));
   GlobalVariableDel(TrailingStateKey("peak"));
   GlobalVariableDel(TrailingStateKey("floor"));
   GlobalVariableDel(TrailingStateKey("basket"));
}

void SavePersistentTrailingState()
{
   if(!g_trailing_active || CountAllPositions() == 0)
      return;

   datetime basket_time = EarliestOurPositionTime();
   if(basket_time == 0)
      return;

   GlobalVariableSet(TrailingStateKey("active"), 1.0);
   GlobalVariableSet(TrailingStateKey("peak"), g_peak_basket_profit);
   GlobalVariableSet(TrailingStateKey("floor"), g_trailing_floor);
   GlobalVariableSet(TrailingStateKey("basket"), (double)basket_time);
   GlobalVariablesFlush();
}

bool RestorePersistentTrailingState()
{
   string active_key = TrailingStateKey("active");
   string peak_key = TrailingStateKey("peak");
   string floor_key = TrailingStateKey("floor");
   string basket_key = TrailingStateKey("basket");

   if(!GlobalVariableCheck(active_key) ||
      !GlobalVariableCheck(peak_key) ||
      !GlobalVariableCheck(floor_key) ||
      !GlobalVariableCheck(basket_key))
   {
      ClearPersistentTrailingState();
      return false;
   }

   datetime basket_time = EarliestOurPositionTime();
   datetime saved_basket_time =
      (datetime)GlobalVariableGet(basket_key);

   double peak = GlobalVariableGet(peak_key);
   double floor = GlobalVariableGet(floor_key);

   if(GlobalVariableGet(active_key) < 0.5 ||
      basket_time == 0 ||
      basket_time != saved_basket_time ||
      peak < floor ||
      floor < InpTrailStartProfit)
   {
      ClearPersistentTrailingState();
      return false;
   }

   g_trailing_active = true;
   g_peak_basket_profit = peak;
   g_trailing_floor = floor;
   return true;
}

void CollectOurTickets(ENUM_POSITION_TYPE type, ulong &tickets[])
{
   ArrayResize(tickets, 0);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsOurPosition())
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = ticket;
   }
}

bool CloseNetPositionsNormally()
{
   bool ok = true;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsOurPosition())
         continue;

      bool request_ok = trade.PositionClose(ticket);
      bool executed = request_ok && TradeRetcodeExecuted();

      if(!executed)
      {
         DebugTradeFailure("Normal close ticket=" + (string)ticket);
         ok = false;
      }
      else if(PositionSelectByTicket(ticket))
      {
         Debug("Normal close incomplete ticket=" + (string)ticket +
               ". Position still exists and will be retried.");
         ok = false;
      }
      else
      {
         Debug("Normal close executed ticket=" + (string)ticket);
      }
   }

   return ok;
}

bool CloseAllPositionsOnce()
{
   bool ok = true;

   int buys_before  = CountPositions(POSITION_TYPE_BUY);
   int sells_before = CountPositions(POSITION_TYPE_SELL);

   // 1) First eliminate the hedged portion with Close By.
   if(buys_before > 0 && sells_before > 0)
   {
      if(!InpUseCloseByForHedge || !SymbolSupportsCloseBy())
      {
         Debug("Close By is disabled or unavailable. Falling back to normal close.");
         return CloseNetPositionsNormally();
      }

      ulong buy_tickets[];
      ulong sell_tickets[];

      CollectOurTickets(POSITION_TYPE_BUY, buy_tickets);
      CollectOurTickets(POSITION_TYPE_SELL, sell_tickets);

      int pair_count = MathMin(ArraySize(buy_tickets),
                               ArraySize(sell_tickets));

      for(int i = 0; i < pair_count; ++i)
      {
         ulong buy_ticket  = buy_tickets[i];
         ulong sell_ticket = sell_tickets[i];

         bool request_ok = trade.PositionCloseBy(buy_ticket, sell_ticket);
         bool executed = request_ok && TradeRetcodeExecuted();

         if(!executed)
         {
            DebugTradeFailure("Close By BUY=" + (string)buy_ticket +
                              " SELL=" + (string)sell_ticket);
            ok = false;
         }
         else
         {
            Debug("Close By executed BUY=" + (string)buy_ticket +
                  " SELL=" + (string)sell_ticket +
                  " volume=" + DoubleToString(trade.ResultVolume(), 2));
         }
      }

      // Refresh counts after Close By.
      int buys_after  = CountPositions(POSITION_TYPE_BUY);
      int sells_after = CountPositions(POSITION_TYPE_SELL);

      // If both sides still remain, at least one hedge pair was not
      // eliminated yet. Do NOT close them separately; preserve them for
      // the next Close By retry.
      if(buys_after > 0 && sells_after > 0)
      {
         Debug("Close By phase incomplete. Remaining B=" +
               (string)buys_after + " S=" + (string)sells_after +
               ". Will retry without normal-closing hedge.");
         return false;
      }
   }

   // 2) At this point there should be only one side left.
   //    That is the true net exposure, so close it normally.
   int remaining_buys  = CountPositions(POSITION_TYPE_BUY);
   int remaining_sells = CountPositions(POSITION_TYPE_SELL);

   if(remaining_buys > 0 && remaining_sells > 0)
   {
      Debug("Both sides still exist; skip normal close and retry Close By.");
      return false;
   }

   if(remaining_buys > 0 || remaining_sells > 0)
   {
      if(!CloseNetPositionsNormally())
         ok = false;
   }

   return ok;
}

void StartBasketClosing(string reason)
{
   if(!g_closing_basket)
   {
      g_closing_basket = true;
      g_close_attempts = 0;
      g_last_close_attempt = 0;
      g_close_reason = reason;
      Debug("BASKET CLOSE MODE START: " + reason);
   }
}

void ResetTrailingState()
{
   g_trailing_active = false;
   g_peak_basket_profit = 0.0;
   g_trailing_floor = 0.0;
   ClearPersistentTrailingState();
}

void FinishBasketClosing()
{
   g_closing_basket = false;
   g_close_attempts = 0;
   g_last_close_attempt = 0;
   g_close_reason = "";
   g_basket_start_bar = 0;
   g_basket_age_bars = 0;
   ResetTrailingState();
   Debug("BASKET CLOSE MODE FINISHED");
}

void ProcessBasketClosing()
{
   int remaining = CountAllPositions();

   if(remaining == 0)
   {
      FinishBasketClosing();
      return;
   }

   datetime now = TimeCurrent();

   if(g_last_close_attempt != 0 &&
      (now - g_last_close_attempt) < InpCloseRetrySeconds)
      return;

   if(InpCloseMaxAttempts > 0 &&
      g_close_attempts >= InpCloseMaxAttempts)
   {
      Debug("WARNING: close retry limit reached. Remaining=" +
            (string)remaining + " reason=" + g_close_reason);
      return;
   }

   g_last_close_attempt = now;
   g_close_attempts++;

   Debug("CLOSE RETRY #" + (string)g_close_attempts +
         " remaining=" + (string)remaining +
         " reason=" + g_close_reason);

   CloseAllPositionsOnce();

   if(CountAllPositions() == 0)
      FinishBasketClosing();
}

bool OpenBuy(string reason)
{
   if(CountAllPositions() >= InpMaxPositions)
      return false;

   string volume_message;
   if(!ValidateOrderVolume(InpLots, volume_message))
   {
      Debug("BUY skipped: " + volume_message);
      return false;
   }

   if(!HasEnoughMargin(ORDER_TYPE_BUY, InpLots))
      return false;

   trade.SetExpertMagicNumber(InpMagic);

   bool request_ok = trade.Buy(InpLots, _Symbol, 0.0, 0.0, 0.0, reason);
   bool ok = TradeDealExecuted(request_ok);

   if(!ok)
      DebugTradeFailure("BUY");
   else
      Debug("BUY executed: " + reason +
            " deal=" + (string)trade.ResultDeal() +
            " volume=" + DoubleToString(trade.ResultVolume(), 2));

   return ok;
}

bool OpenSell(string reason)
{
   if(CountAllPositions() >= InpMaxPositions)
      return false;

   string volume_message;
   if(!ValidateOrderVolume(InpLots, volume_message))
   {
      Debug("SELL skipped: " + volume_message);
      return false;
   }

   if(!HasEnoughMargin(ORDER_TYPE_SELL, InpLots))
      return false;

   trade.SetExpertMagicNumber(InpMagic);

   bool request_ok = trade.Sell(InpLots, _Symbol, 0.0, 0.0, 0.0, reason);
   bool ok = TradeDealExecuted(request_ok);

   if(!ok)
      DebugTradeFailure("SELL");
   else
      Debug("SELL executed: " + reason +
            " deal=" + (string)trade.ResultDeal() +
            " volume=" + DoubleToString(trade.ResultVolume(), 2));

   return ok;
}

bool TicketWasPresent(ulong ticket, ulong &tickets[])
{
   for(int i = 0; i < ArraySize(tickets); ++i)
   {
      if(tickets[i] == ticket)
         return true;
   }

   return false;
}

ulong FindNewPositionTicket(ENUM_POSITION_TYPE type, ulong &tickets_before[])
{
   ulong newest_ticket = 0;
   long newest_time_msc = -1;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 ||
         TicketWasPresent(ticket, tickets_before) ||
         !PositionSelectByTicket(ticket) ||
         !IsOurPosition() ||
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      long time_msc = PositionGetInteger(POSITION_TIME_MSC);
      if(time_msc > newest_time_msc)
      {
         newest_time_msc = time_msc;
         newest_ticket = ticket;
      }
   }

   return newest_ticket;
}

bool CloseSinglePositionConfirmed(ulong ticket, string reason)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return true;

   bool request_ok = trade.PositionClose(ticket);
   bool executed = request_ok && TradeRetcodeExecuted();

   if(!executed)
   {
      DebugTradeFailure(reason + " ticket=" + (string)ticket);
      return false;
   }

   if(PositionSelectByTicket(ticket))
   {
      Debug(reason + " incomplete ticket=" + (string)ticket);
      return false;
   }

   Debug(reason + " executed ticket=" + (string)ticket);
   return true;
}

bool OpenInitialHedgeLayer()
{
   int total = CountAllPositions();
   if(total + 2 > InpMaxPositions)
   {
      Debug("Initial hedge skipped: two free position slots are required.");
      return false;
   }

   string volume_message;
   if(!ValidateOrderVolume(InpLots, volume_message))
   {
      Debug("Initial hedge skipped: " + volume_message);
      return false;
   }

   if(!HasEnoughMarginForInitialHedge(InpLots))
      return false;

   ulong buy_tickets_before[];
   ulong sell_tickets_before[];
   CollectOurTickets(POSITION_TYPE_BUY, buy_tickets_before);
   CollectOurTickets(POSITION_TYPE_SELL, sell_tickets_before);

   if(!OpenBuy("HYP_SECOND_BUY"))
      return false;

   ulong new_buy_ticket =
      FindNewPositionTicket(POSITION_TYPE_BUY, buy_tickets_before);
   double buy_volume = trade.ResultVolume();

   if(new_buy_ticket == 0 ||
      MathAbs(buy_volume - InpLots) > 0.0000001)
   {
      Debug("Initial hedge BUY was not fully opened. Rolling it back.");
      bool rollback_ok =
         (new_buy_ticket != 0 &&
          CloseSinglePositionConfirmed(new_buy_ticket,
                                       "Initial hedge BUY rollback"));

      if(!rollback_ok)
         StartBasketClosing("INITIAL HEDGE BUY ROLLBACK FAILED");

      return false;
   }

   if(!OpenSell("HYP_SECOND_SELL"))
   {
      Debug("Initial hedge SELL failed. Rolling back BUY.");
      if(!CloseSinglePositionConfirmed(new_buy_ticket,
                                       "Initial hedge BUY rollback"))
         StartBasketClosing("INITIAL HEDGE BUY ROLLBACK FAILED");

      return false;
   }

   ulong new_sell_ticket =
      FindNewPositionTicket(POSITION_TYPE_SELL, sell_tickets_before);
   double sell_volume = trade.ResultVolume();

   if(new_sell_ticket == 0 ||
      MathAbs(sell_volume - InpLots) > 0.0000001)
   {
      Debug("Initial hedge SELL was not fully opened. Rolling back both legs.");
      bool sell_rollback_ok =
         (new_sell_ticket != 0 &&
          CloseSinglePositionConfirmed(new_sell_ticket,
                                       "Initial hedge SELL rollback"));
      bool buy_rollback_ok =
         CloseSinglePositionConfirmed(new_buy_ticket,
                                      "Initial hedge BUY rollback");

      if(!sell_rollback_ok || !buy_rollback_ok)
         StartBasketClosing("INITIAL HEDGE ROLLBACK FAILED");

      return false;
   }

   Debug("Initial hedge layer completed.");
   return true;
}

bool ReadPreviousIndicators(double &close1, double &ema1, double &sma1)
{
   close1 = iClose(_Symbol, PERIOD_M1, 1);
   if(close1 == 0.0)
      return false;

   double ema_buf[1];
   double sma_buf[1];

   if(CopyBuffer(g_ema_handle, 0, 1, 1, ema_buf) != 1)
      return false;

   if(CopyBuffer(g_sma_handle, 0, 1, 1, sma_buf) != 1)
      return false;

   ema1 = ema_buf[0];
   sma1 = sma_buf[0];

   return true;
}

int DirectionFromEMA(double close1, double ema1)
{
   if(close1 > ema1)
      return 1;

   if(close1 < ema1)
      return -1;

   return 0;
}

bool IsNewM1Bar()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);

   if(t == 0)
      return false;

   if(t == g_last_bar_time)
      return false;

   g_last_bar_time = t;
   return true;
}

void StartNewBasket()
{
   double close1, ema1, sma1;

   if(!ReadPreviousIndicators(close1, ema1, sma1))
   {
      Debug("Start basket skipped: indicator read failed");
      return;
   }

   int direction = DirectionFromEMA(close1, ema1);

   if(direction > 0)
   {
      if(OpenBuy("HYP_START_EMA_BUY"))
      {
         g_basket_start_bar = g_last_bar_time;
         g_basket_age_bars = 1;
      }
   }
   else if(direction < 0)
   {
      if(OpenSell("HYP_START_EMA_SELL"))
      {
         g_basket_start_bar = g_last_bar_time;
         g_basket_age_bars = 1;
      }
   }
   else
   {
      Debug("Start basket skipped: Close[1] == EMA");
   }
}

void ProcessBasket()
{
   int buys  = CountPositions(POSITION_TYPE_BUY);
   int sells = CountPositions(POSITION_TYPE_SELL);
   int total = buys + sells;

   if(total == 0)
   {
      StartNewBasket();
      return;
   }

   g_basket_age_bars++;

   // Optional initial hedge layer:
   // on the second minute, add one BUY and one SELL.
   if(InpUseInitialHedge && g_basket_age_bars == 2)
   {
      OpenInitialHedgeLayer();
      return;
   }

   double close1, ema1, sma1;
   if(!ReadPreviousIndicators(close1, ema1, sma1))
   {
      Debug("Indicator read failed");
      return;
   }

   int direction = DirectionFromEMA(close1, ema1);

   // If fully hedged, stay idle until short-term movement becomes large enough.
   if(buys == sells)
   {
      double deviation = close1 - sma1;

      Debug(
         "FULL_HEDGE B=" + (string)buys +
         " S=" + (string)sells +
         " Close1=" + DoubleToString(close1, _Digits) +
         " SMA=" + DoubleToString(sma1, _Digits) +
         " dev=" + DoubleToString(deviation, 2)
      );

      if(MathAbs(deviation) < InpHedgeReleaseDistance)
      {
         Debug("FULL_HEDGE -> WAIT");
         return;
      }

      // For the release direction, observed data was consistent with
      // short-term MA side. Use EMA10 direction here.
      if(direction > 0)
         OpenBuy("HYP_HEDGE_RELEASE_BUY");
      else if(direction < 0)
         OpenSell("HYP_HEDGE_RELEASE_SELL");

      return;
   }

   // If net exposure exists, observed EA usually added one position per M1 bar
   // in the short-term trend direction.
   if(direction > 0)
      OpenBuy("HYP_TREND_BUY");
   else if(direction < 0)
      OpenSell("HYP_TREND_SELL");
}

double SumPositionVolume(ENUM_POSITION_TYPE type)
{
   double volume = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(!IsOurPosition())
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      volume += PositionGetDouble(POSITION_VOLUME);
   }

   return volume;
}

double CurrentNetPositionRatio()
{
   double buy_volume  = SumPositionVolume(POSITION_TYPE_BUY);
   double sell_volume = SumPositionVolume(POSITION_TYPE_SELL);
   double total_volume = buy_volume + sell_volume;

   if(total_volume <= 0.0)
      return 0.0;

   return MathAbs(buy_volume - sell_volume) / total_volume;
}

double CalculateTrailingDistance(double peak_profit)
{
   double fixed_distance = MathMax(0.0, InpTrailFixedDistance);
   double percent_distance = 0.0;

   if(InpTrailPercent > 0.0)
      percent_distance = peak_profit * InpTrailPercent / 100.0;

   double base_distance = MathMax(fixed_distance, percent_distance);

   if(!InpUseNetPositionTrail)
      return base_distance;

   double net_ratio = CurrentNetPositionRatio();

   double strength = MathMax(0.0, InpNetTrailStrength);
   double min_mult = MathMax(0.0, MathMin(1.0, InpMinTrailMultiplier));

   double multiplier = 1.0 - strength * net_ratio;
   multiplier = MathMax(min_mult, MathMin(1.0, multiplier));

   return base_distance * multiplier;
}

bool CheckBasketTrailing(double pnl)
{
   if(!InpUseBasketTrailing || InpTrailStartProfit <= 0.0)
      return false;

   if(!g_trailing_active)
   {
      if(pnl < InpTrailStartProfit)
         return false;

      g_trailing_active = true;
      g_peak_basket_profit = pnl;

      double distance = CalculateTrailingDistance(g_peak_basket_profit);

      g_trailing_floor =
         MathMax(InpTrailStartProfit,
                 g_peak_basket_profit - distance);

      Debug("TRAIL START pnl=" + DoubleToString(pnl, 2) +
            " peak=" + DoubleToString(g_peak_basket_profit, 2) +
            " floor=" + DoubleToString(g_trailing_floor, 2) +
            " netRatio=" + DoubleToString(CurrentNetPositionRatio(), 3) +
            " trailDist=" + DoubleToString(distance, 2));

      SavePersistentTrailingState();

      return false;
   }

   if(pnl > g_peak_basket_profit)
   {
      g_peak_basket_profit = pnl;

      double distance = CalculateTrailingDistance(g_peak_basket_profit);

      g_trailing_floor =
         MathMax(InpTrailStartProfit,
                 g_peak_basket_profit - distance);

      Debug("TRAIL UPDATE peak=" +
            DoubleToString(g_peak_basket_profit, 2) +
            " floor=" + DoubleToString(g_trailing_floor, 2) +
            " netRatio=" + DoubleToString(CurrentNetPositionRatio(), 3) +
            " trailDist=" + DoubleToString(distance, 2));

      SavePersistentTrailingState();
   }

   if(pnl <= g_trailing_floor)
   {
      Debug("TRAIL HIT pnl=" + DoubleToString(pnl, 2) +
            " peak=" + DoubleToString(g_peak_basket_profit, 2) +
            " floor=" + DoubleToString(g_trailing_floor, 2));
      return true;
   }

   return false;
}

// =========================
// MT5 events
// =========================
int OnInit()
{
   if(InpLots <= 0.0 ||
      InpEMA_Period <= 0 ||
      InpSMA_Period <= 0 ||
      InpHedgeReleaseDistance < 0.0 ||
      InpMaxPositions <= 0 ||
      InpCloseRetrySeconds < 0 ||
      InpCloseMaxAttempts < 0)
   {
      Print("Invalid input parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpWarnIfChartNotM1 && _Period != PERIOD_M1)
      Print("NOTICE: This EA always calculates entries from M1 data.");

   // This strategy requires independent BUY and SELL positions.
   long margin_mode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(margin_mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("This EA requires an MT5 hedging account. Initialization stopped.");
      return INIT_FAILED;
   }

   g_ema_handle = iMA(_Symbol, PERIOD_M1, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_sma_handle = iMA(_Symbol, PERIOD_M1, InpSMA_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(g_ema_handle == INVALID_HANDLE || g_sma_handle == INVALID_HANDLE)
   {
      Print("Failed to create MA handles.");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_last_bar_time = iTime(_Symbol, PERIOD_M1, 0);

   // If tester/terminal/VPS restarts with an existing basket, continue it.
   // Prefer the persisted historical peak/floor. If no valid saved state is
   // available, start from the current PnL only when it is already above the
   // configured activation threshold.
   if(CountAllPositions() > 0)
   {
      g_basket_age_bars = 3;

      double pnl = BasketProfit();

      if(InpUseBasketTrailing && InpTrailStartProfit > 0.0)
      {
         if(RestorePersistentTrailingState())
         {
            Debug("Trailing state restored after restart. pnl=" +
                  DoubleToString(pnl, 2) +
                  " peak=" + DoubleToString(g_peak_basket_profit, 2) +
                  " floor=" + DoubleToString(g_trailing_floor, 2));
         }
         else if(pnl >= InpTrailStartProfit)
         {
            g_trailing_active = true;
            g_peak_basket_profit = pnl;

            double distance = CalculateTrailingDistance(g_peak_basket_profit);
            g_trailing_floor =
               MathMax(InpTrailStartProfit,
                       g_peak_basket_profit - distance);

            SavePersistentTrailingState();

            Debug("Trailing state initialized from current PnL after restart. pnl=" +
                  DoubleToString(pnl, 2) +
                  " floor=" + DoubleToString(g_trailing_floor, 2));
         }
      }
      else
      {
         ClearPersistentTrailingState();
      }
   }
   else
   {
      ClearPersistentTrailingState();
   }

   Debug("Initialized");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");

   if(g_trailing_active && CountAllPositions() > 0)
      SavePersistentTrailingState();

   if(g_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_handle);

   if(g_sma_handle != INVALID_HANDLE)
      IndicatorRelease(g_sma_handle);
}

void OnTick()
{
   // Once a basket close has started, never open new positions until every
   // position belonging to this EA has disappeared.
   if(g_closing_basket)
   {
      ProcessBasketClosing();
      return;
   }

   int total = CountAllPositions();

   if(total == 0)
   {
      ResetTrailingState();
   }
   else
   {
      double pnl = BasketProfit();

      // Hard basket loss stop remains independent of profit trailing.
      if(InpBasketLossMoney > 0.0 && pnl <= -InpBasketLossMoney)
      {
         StartBasketClosing("SL pnl=" + DoubleToString(pnl, 2));
         ProcessBasketClosing();
         return;
      }

      if(InpUseBasketTrailing)
      {
         if(CheckBasketTrailing(pnl))
         {
            StartBasketClosing(
               "TRAIL pnl=" + DoubleToString(pnl, 2) +
               " peak=" + DoubleToString(g_peak_basket_profit, 2) +
               " floor=" + DoubleToString(g_trailing_floor, 2)
            );
            ProcessBasketClosing();
            return;
         }
      }
      else
      {
         // Legacy v0.3 fixed basket TP.
         if(InpBasketProfitMoney > 0.0 &&
            pnl >= InpBasketProfitMoney)
         {
            StartBasketClosing("TP pnl=" + DoubleToString(pnl, 2));
            ProcessBasketClosing();
            return;
         }
      }

      if(InpPrintDebug)
      {
         Comment(
            "Basket PnL: ", DoubleToString(pnl, 2),
            "\nTrailing: ", (g_trailing_active ? "ON" : "OFF"),
            "\nPeak: ", DoubleToString(g_peak_basket_profit, 2),
            "\nFloor: ", DoubleToString(g_trailing_floor, 2),
            "\nNetRatio: ", DoubleToString(CurrentNetPositionRatio(), 3),
            "\nB=", CountPositions(POSITION_TYPE_BUY),
            " S=", CountPositions(POSITION_TYPE_SELL)
         );
      }
   }

   // Entries are evaluated once per new M1 bar.
   if(!IsNewM1Bar())
      return;

   ProcessBasket();
}
