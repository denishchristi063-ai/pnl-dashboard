//+------------------------------------------------------------------+
//|                                          PnLReporter_MT5.mq5      |
//|  Pushes a live account/position/symbol snapshot to the P&L       |
//|  dashboard backend via WebRequest() every                        |
//|  InpReportIntervalSeconds.                                       |
//|                                                                    |
//|  SETUP:                                                           |
//|  1. Tools > Options > Expert Advisors > Allow WebRequest for      |
//|     listed URL. Add the base URL only (no /api/report path).     |
//|  2. Set InpAccountId to something unique per terminal, e.g.       |
//|     "MT5-Live-01" or the actual account login number.             |
//|  3. Set InpApiKey to match PNL_API_KEY on the server.             |
//|                                                                    |
//|  NOTE on commission accuracy: MT5 does not expose commission on   |
//|  a live open position directly (it's recorded on the deal that   |
//|  opened it). Closed-trade commission/swap/profit for TODAY is    |
//|  pulled from history deals and is accurate. Commission on a      |
//|  position that's still open is only counted once it closes (or   |
//|  if it was opened earlier today, its entry commission is picked  |
//|  up via today's history). Positions opened on a previous day and |
//|  still open won't have their original entry commission reflected|
//|  in "today's" figures — this is a MT5 data-model limitation, not |
//|  a bug.                                                            |
//+------------------------------------------------------------------+
#property strict

input string InpApiUrl              = "https://YOUR-APP-NAME.up.railway.app/api/report";
input string InpApiKey              = "changeme123";
input string InpAccountId           = "";     // leave blank to auto-use account login number
input string InpAccountLabel        = "";     // friendly name shown on dashboard, e.g. "Gold Martingale"
input int    InpReportIntervalSeconds = 3;
input bool   InpSendPositions       = true;
input bool   InpSendSymbolBreakdown = true;

string g_accountId;

struct SymbolAgg
{
   string symbol;
   int    leg_count;
   double entry_weighted_sum;
   double volume_sum;
   double open_profit;
   double open_swap;
   double closed_profit;
   double closed_swap;
   double closed_commission;
};

//+------------------------------------------------------------------+
int OnInit()
{
   g_accountId = (InpAccountId == "") ? IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) : InpAccountId;
   EventSetTimer(InpReportIntervalSeconds);
   SendReport();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   SendReport();
}

//+------------------------------------------------------------------+
string JsonEsc(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
}

//+------------------------------------------------------------------+
//| Persistent (survives restart) day-start balance & peak equity,   |
//| keyed per account per calendar day via terminal GlobalVariables. |
//+------------------------------------------------------------------+
string TodayKey(string suffix)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = StringFormat("%04d%02d%02d", dt.year, dt.mon, dt.day);
   return "PNLDASH_" + g_accountId + "_" + suffix + "_" + dateStr;
}

double GetOrInitDayStartBalance()
{
   string key = TodayKey("DAYSTART");
   if(GlobalVariableCheck(key)) return GlobalVariableGet(key);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   GlobalVariableSet(key, bal);
   return bal;
}

double UpdatePeakEquity(double currentEquity)
{
   string key = TodayKey("PEAK");
   double peak = currentEquity;
   if(GlobalVariableCheck(key)) peak = MathMax(GlobalVariableGet(key), currentEquity);
   GlobalVariableSet(key, peak);
   return peak;
}

//+------------------------------------------------------------------+
//| Find or add a symbol slot in the aggregation array                |
//+------------------------------------------------------------------+
int FindOrAddSymbol(SymbolAgg &arr[], string sym)
{
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i].symbol == sym) return i;

   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].symbol             = sym;
   arr[n].leg_count          = 0;
   arr[n].entry_weighted_sum = 0;
   arr[n].volume_sum         = 0;
   arr[n].open_profit        = 0;
   arr[n].open_swap          = 0;
   arr[n].closed_profit      = 0;
   arr[n].closed_swap        = 0;
   arr[n].closed_commission  = 0;
   return n;
}

//+------------------------------------------------------------------+
//| Build JSON payload and POST it                                    |
//+------------------------------------------------------------------+
void SendReport()
{
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin      = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginFree   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double floatingPnl = equity - balance;
   int    leverage    = (int)AccountInfoInteger(ACCOUNT_LEVERAGE);
   double marginUsedPct = (equity > 0) ? (margin / equity * 100.0) : 0.0;
   string currency    = AccountInfoString(ACCOUNT_CURRENCY);
   string broker      = AccountInfoString(ACCOUNT_COMPANY);
   string label       = (InpAccountLabel == "") ? g_accountId : InpAccountLabel;

   double dayStartBalance = GetOrInitDayStartBalance();
   double dayPnl          = equity - dayStartBalance;
   double peakEquity      = UpdatePeakEquity(equity);
   double drawdownPct     = (peakEquity > 0) ? ((peakEquity - equity) / peakEquity * 100.0) : 0.0;

   int total = PositionsTotal();
   SymbolAgg aggs[];

   string positionsJson = "[]";
   if(InpSendPositions && total > 0)
   {
      positionsJson = "[";
      int included = 0;
      for(int i = 0; i < total; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         string symbol     = PositionGetString(POSITION_SYMBOL);
         double vol         = PositionGetDouble(POSITION_VOLUME);
         double profit       = PositionGetDouble(POSITION_PROFIT);
         double openPrice     = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice  = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl            = PositionGetDouble(POSITION_SL);
         double tp            = PositionGetDouble(POSITION_TP);
         double swap          = PositionGetDouble(POSITION_SWAP);
         datetime openTime   = (datetime)PositionGetInteger(POSITION_TIME);
         int durationMin      = (int)((TimeCurrent() - openTime) / 60);
         long   type         = PositionGetInteger(POSITION_TYPE);
         string typeStr       = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";

         if(included > 0) positionsJson += ",";
         positionsJson += "{";
         positionsJson += "\"symbol\":\"" + JsonEsc(symbol) + "\",";
         positionsJson += "\"type\":\"" + typeStr + "\",";
         positionsJson += "\"volume\":" + DoubleToString(vol, 2) + ",";
         positionsJson += "\"profit\":" + DoubleToString(profit, 2) + ",";
         positionsJson += "\"open_price\":" + DoubleToString(openPrice, _Digits) + ",";
         positionsJson += "\"current_price\":" + DoubleToString(currentPrice, _Digits) + ",";
         positionsJson += "\"sl\":" + DoubleToString(sl, _Digits) + ",";
         positionsJson += "\"tp\":" + DoubleToString(tp, _Digits) + ",";
         positionsJson += "\"swap\":" + DoubleToString(swap, 2) + ",";
         positionsJson += "\"duration_min\":" + IntegerToString(durationMin);
         positionsJson += "}";
         included++;

         if(InpSendSymbolBreakdown)
         {
            int idx = FindOrAddSymbol(aggs, symbol);
            aggs[idx].leg_count++;
            aggs[idx].entry_weighted_sum += openPrice * vol;
            aggs[idx].volume_sum         += vol;
            aggs[idx].open_profit        += profit;
            aggs[idx].open_swap          += swap;
         }
      }
      positionsJson += "]";
   }

   string symbolsJson = "[]";
   if(InpSendSymbolBreakdown)
   {
      // pull today's closed deals (realized profit/swap/commission) grouped by symbol
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime dayStart = StructToTime(dt);

      if(HistorySelect(dayStart, TimeCurrent()))
      {
         int dealsTotal = HistoryDealsTotal();
         for(int i = 0; i < dealsTotal; i++)
         {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket == 0) continue;
            string sym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
            if(sym == "") continue; // skip balance/credit/non-trade deals

            double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
            double swap        = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
            double commission  = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

            int idx = FindOrAddSymbol(aggs, sym);
            aggs[idx].closed_profit     += profit;
            aggs[idx].closed_swap       += swap;
            aggs[idx].closed_commission += commission;
         }
      }

      int n = ArraySize(aggs);
      if(n > 0)
      {
         symbolsJson = "[";
         for(int i = 0; i < n; i++)
         {
            double avgEntry = (aggs[i].volume_sum > 0) ? (aggs[i].entry_weighted_sum / aggs[i].volume_sum) : 0;
            double netTotal = aggs[i].open_profit + aggs[i].open_swap
                             + aggs[i].closed_profit + aggs[i].closed_swap + aggs[i].closed_commission;

            if(i > 0) symbolsJson += ",";
            symbolsJson += "{";
            symbolsJson += "\"symbol\":\"" + JsonEsc(aggs[i].symbol) + "\",";
            symbolsJson += "\"leg_count\":" + IntegerToString(aggs[i].leg_count) + ",";
            symbolsJson += "\"avg_entry\":" + DoubleToString(avgEntry, _Digits) + ",";
            symbolsJson += "\"open_profit\":" + DoubleToString(aggs[i].open_profit, 2) + ",";
            symbolsJson += "\"open_swap\":" + DoubleToString(aggs[i].open_swap, 2) + ",";
            symbolsJson += "\"closed_profit\":" + DoubleToString(aggs[i].closed_profit, 2) + ",";
            symbolsJson += "\"closed_swap\":" + DoubleToString(aggs[i].closed_swap, 2) + ",";
            symbolsJson += "\"closed_commission\":" + DoubleToString(aggs[i].closed_commission, 2) + ",";
            symbolsJson += "\"net_total\":" + DoubleToString(netTotal, 2);
            symbolsJson += "}";
         }
         symbolsJson += "]";
      }
   }

   string json = "{";
   json += "\"api_key\":\"" + JsonEsc(InpApiKey) + "\",";
   json += "\"account_id\":\"" + JsonEsc(g_accountId) + "\",";
   json += "\"label\":\"" + JsonEsc(label) + "\",";
   json += "\"platform\":\"MT5\",";
   json += "\"broker\":\"" + JsonEsc(broker) + "\",";
   json += "\"currency\":\"" + JsonEsc(currency) + "\",";
   json += "\"balance\":" + DoubleToString(balance, 2) + ",";
   json += "\"equity\":" + DoubleToString(equity, 2) + ",";
   json += "\"floating_pnl\":" + DoubleToString(floatingPnl, 2) + ",";
   json += "\"margin\":" + DoubleToString(margin, 2) + ",";
   json += "\"margin_free\":" + DoubleToString(marginFree, 2) + ",";
   json += "\"margin_level\":" + DoubleToString(marginLevel, 2) + ",";
   json += "\"margin_used_pct\":" + DoubleToString(marginUsedPct, 2) + ",";
   json += "\"leverage\":" + IntegerToString(leverage) + ",";
   json += "\"day_pnl\":" + DoubleToString(dayPnl, 2) + ",";
   json += "\"drawdown_pct\":" + DoubleToString(drawdownPct, 2) + ",";
   json += "\"open_positions\":" + IntegerToString(total) + ",";
   json += "\"positions\":" + positionsJson + ",";
   json += "\"symbols\":" + symbolsJson + ",";
   json += "\"server_time\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\"";
   json += "}";

   uchar postData[];
   int len = StringToCharArray(json, postData, 0, StringLen(json));
   ArrayResize(postData, len);

   string headers = "Content-Type: application/json\r\n";
   uchar result[];
   string resultHeaders;

   int res = WebRequest("POST", InpApiUrl, headers, 5000, postData, result, resultHeaders);

   if(res == -1)
   {
      int err = GetLastError();
      if(err == 4060)
         Print("PnLReporter: WebRequest not allowed. Add URL to Tools>Options>Expert Advisors whitelist: ", InpApiUrl);
      else
         Print("PnLReporter: WebRequest failed, error ", err);
   }
   else if(res != 200)
   {
      Print("PnLReporter: server responded with HTTP ", res, " -> ", CharArrayToString(result));
   }
}
//+------------------------------------------------------------------+
