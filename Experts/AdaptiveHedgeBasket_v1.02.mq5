#property strict
#property copyright "hutamisiina"
#property version   "1.02"
#property description "Adaptive Breakout Basket - add only when price breaks recent M1 highs or lows"

#include <Trade/Trade.mqh>

CTrade trade;

// =========================
// Inputs
// =========================
input long   InpMagic                = 36291761;
input double InpLots                 = 0.01;

// Price-breakout entry logic.
// The live Bid is compared with the preceding N fully closed M1 bars.
// Break above their highest high -> BUY. Break below their lowest low -> SELL.
// No position is added merely because another minute has elapsed.
input int    InpBreakoutLookbackBars      = 3;
input double InpBreakoutBufferPrice       = 0.0;
// Require this distance from the latest same-side entry before adding again.
// Price-unit input avoids a 10x difference between 2- and 3-digit gold quotes.
input double InpMinEntryDistancePrice     = 0.80;

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
// Default 1.0 assumes InpLots=0.01. Set 0 to disable.
input double InpBasketProfitMoney     = 1.0;

// Unknown original loss-exit rule, therefore disabled by default.
// Use a positive number to enable absolute-money stop.
input double InpBasketLossMoney       = 0.0;

// Basket loss controls.
// These stops close the entire basket only while its floating PnL is negative.
// Holding time is measured from the oldest open position managed by this EA.
input bool   InpUseHoldingTimeStop    = true;
input int    InpMaxHoldingMinutes     = 17;
input bool   InpUsePositionCountStop = false;
input int    InpPositionCountStop     = 100;

// Safety / test controls
input int    InpMaxPositions         = 9999999;
// Block new entries from Friday 23:59 JST through Sunday 23:59 JST.
// Existing positions continue to be managed and closed as usual.
input bool   InpUseWeekendEntryGuard = true;
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
      Print("[BreakoutBasket] ", msg);
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

long BasketHoldingSeconds()
{
   datetime earliest = EarliestOurPositionTime();
   datetime now = TimeCurrent();

   if(earliest == 0 || now <= earliest)
      return 0;

   return (long)(now - earliest);
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

datetime CurrentJstTime()
{
   // JST is fixed at UTC+9 and does not observe daylight saving time.
   return TimeGMT() + 9 * 60 * 60;
}

bool IsWeekendEntryBlocked()
{
   if(!InpUseWeekendEntryGuard)
      return false;

   MqlDateTime jst;
   if(!TimeToStruct(CurrentJstTime(), jst))
   {
      Debug("Weekend guard blocked entry: unable to read JST time.");
      return true;
   }

   // MqlDateTime day_of_week: 0=Sunday, 5=Friday, 6=Saturday.
   if(jst.day_of_week == 6 || jst.day_of_week == 0)
      return true;

   if(jst.day_of_week == 5 &&
      (jst.hour > 23 || (jst.hour == 23 && jst.min >= 59)))
      return true;

   return false;
}

bool OpenBuy(string reason)
{
   if(IsWeekendEntryBlocked())
   {
      Debug("BUY skipped by weekend guard. JST=" +
            TimeToString(CurrentJstTime(), TIME_DATE | TIME_MINUTES));
      return false;
   }

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
   if(IsWeekendEntryBlocked())
   {
      Debug("SELL skipped by weekend guard. JST=" +
            TimeToString(CurrentJstTime(), TIME_DATE | TIME_MINUTES));
      return false;
   }

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

bool ReadBreakoutLevels(double &previous_high, double &previous_low)
{
   previous_high = 0.0;
   previous_low = 0.0;

   int bars_needed = InpBreakoutLookbackBars;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   // Start at shift 1 so the still-forming M1 candle never changes the range.
   if(CopyRates(_Symbol, PERIOD_M1, 1, bars_needed, rates) != bars_needed)
   {
      Debug("Breakout levels skipped: insufficient M1 history.");
      return false;
   }

   previous_high = rates[0].high;
   previous_low = rates[0].low;

   for(int i = 1; i < bars_needed; ++i)
   {
      previous_high = MathMax(previous_high, rates[i].high);
      previous_low = MathMin(previous_low, rates[i].low);
   }

   return true;
}

bool LatestSameSideEntryPrice(ENUM_POSITION_TYPE type, double &price)
{
   price = 0.0;
   long latest_time_msc = -1;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket) || !IsOurPosition())
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      long time_msc = PositionGetInteger(POSITION_TIME_MSC);
      if(time_msc > latest_time_msc)
      {
         latest_time_msc = time_msc;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return (latest_time_msc >= 0);
}

bool EntryDistanceIsEnough(ENUM_POSITION_TYPE type, double signal_price)
{
   if(InpMinEntryDistancePrice <= 0.0)
      return true;

   double latest_price = 0.0;
   if(!LatestSameSideEntryPrice(type, latest_price))
      return true;

   double required_distance = InpMinEntryDistancePrice;
   double actual_distance =
      (type == POSITION_TYPE_BUY) ?
      (signal_price - latest_price) :
      (latest_price - signal_price);

   if(actual_distance + (_Point * 0.1) >= required_distance)
      return true;

   Debug("Breakout entry skipped: same-side distance=" +
         DoubleToString(actual_distance, _Digits) +
         " required=" + DoubleToString(required_distance, _Digits));
   return false;
}

void ProcessBasket()
{
   double previous_high = 0.0;
   double previous_low = 0.0;

   if(!ReadBreakoutLevels(previous_high, previous_low))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   double buffer = InpBreakoutBufferPrice;
   bool high_break = (tick.bid > previous_high + buffer);
   bool low_break = (tick.bid < previous_low - buffer);

   if(high_break == low_break)
      return;

   bool basket_was_empty = (CountAllPositions() == 0);
   bool opened = false;

   if(high_break &&
      EntryDistanceIsEnough(POSITION_TYPE_BUY, tick.ask))
   {
      opened = OpenBuy(basket_was_empty ?
                       "HYP_START_HIGH_BREAK_BUY" :
                       "HYP_HIGH_BREAK_BUY");
   }
   else if(low_break &&
           EntryDistanceIsEnough(POSITION_TYPE_SELL, tick.bid))
   {
      opened = OpenSell(basket_was_empty ?
                        "HYP_START_LOW_BREAK_SELL" :
                        "HYP_LOW_BREAK_SELL");
   }

   if(!opened)
      return;

   Debug((high_break ? "HIGH BREAK BUY" : "LOW BREAK SELL") +
         " bid=" + DoubleToString(tick.bid, _Digits) +
         " previousHigh=" + DoubleToString(previous_high, _Digits) +
         " previousLow=" + DoubleToString(previous_low, _Digits));
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
      InpBreakoutLookbackBars < 1 ||
      InpBreakoutBufferPrice < 0.0 ||
      InpMinEntryDistancePrice < 0.0 ||
      InpMaxPositions <= 0 ||
      (InpUseHoldingTimeStop && InpMaxHoldingMinutes <= 0) ||
      (InpUsePositionCountStop && InpPositionCountStop <= 0) ||
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

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);

   // If tester/terminal/VPS restarts with an existing basket, continue it.
   // Prefer the persisted historical peak/floor. If no valid saved state is
   // available, start from the current PnL only when it is already above the
   // configured activation threshold.
   if(CountAllPositions() > 0)
   {
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

      // Time-based stop: close a losing basket after the oldest position has
      // been held for the configured number of minutes.
      long holding_seconds = BasketHoldingSeconds();
      long holding_limit_seconds = (long)InpMaxHoldingMinutes * 60;

      if(InpUseHoldingTimeStop &&
         pnl < 0.0 &&
         holding_seconds >= holding_limit_seconds)
      {
         StartBasketClosing(
            "TIME STOP held=" + (string)holding_seconds +
            "s limit=" + (string)holding_limit_seconds +
            "s pnl=" + DoubleToString(pnl, 2)
         );
         ProcessBasketClosing();
         return;
      }

      // Position-count stop: close a losing basket when its number of open
      // positions reaches the configured threshold.
      if(InpUsePositionCountStop &&
         pnl < 0.0 &&
         total >= InpPositionCountStop)
      {
         StartBasketClosing(
            "POSITION COUNT STOP positions=" + (string)total +
            " limit=" + (string)InpPositionCountStop +
            " pnl=" + DoubleToString(pnl, 2)
         );
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
            "\nHeld: ", (string)holding_seconds, " sec",
            "\nB=", CountPositions(POSITION_TYPE_BUY),
            " S=", CountPositions(POSITION_TYPE_SELL)
         );
      }
   }

   // Entry timing is price-driven. The closed M1 range supplies the breakout
   // levels, while the minimum same-side distance prevents tick-by-tick spam.
   ProcessBasket();
}
