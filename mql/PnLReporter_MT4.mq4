//+------------------------------------------------------------------+
//|                                          PnLReporter_MT4.mq4      |
//|  Pushes a live account/position/symbol snapshot to the P&L       |
//|  dashboard backend via WebRequest() every                        |
//|  InpReportIntervalSeconds.                                       |
//|                                                                    |
//|  SETUP:                                                           |
//|  1. Tools > Options > Expert Advisors > Allow WebRequest for      |
//|     listed URL. Add the base URL only (no /api/report path).     |
//|  2. Set InpAccountId to something unique per terminal.            |
//|  3. Set InpApiKey to match PNL_API_KEY on the server.             |
//+------------------------------------------------------------------+
#property strict

input string InpApiUrl              = "https://YOUR-APP-NAME.up.railway.app/api/report";
input string InpApiKey              = "changeme123";
input string InpAccountId           = "";     // leave blank to auto-use account number
input string InpAccountLabel        = "";     // friendly name shown on dashboard
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
   g_accountId = (InpAccountId == "") ? IntegerToString(AccountNumber()) : InpAccountId;
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
   string dateStr = TimeToString(TimeCurrent(), TIME_DATE);
   StringReplace(dateStr, ".", "");
   return "PNLDASH_" + g_accountId + "_" + suffix + "_" + dateStr;
}

double GetOrInitDayStartBalance()
{
   string key = TodayKey("DAYSTART");
   if(GlobalVariableCheck(key)) return GlobalVariableGet(key);
   double bal = AccountBalance();
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
void SendReport()
{
   double balance      = AccountBalance();
   double equity       = AccountEquity();
   double margin       = AccountMargin();
   double marginFree    = AccountFreeMargin();
   double marginLevel  = (margin > 0) ? (equity / margin * 100.0) : 0.0;
   double marginUsedPct = (equity > 0) ? (margin / equity * 100.0) : 0.0;
   double floatingPnl  = equity - balance;
   int    leverage     = AccountLeverage();
   string currency     = AccountCurrency();
   string broker       = AccountCompany();
   string label        = (InpAccountLabel == "") ? g_accountId : InpAccountLabel;

   double dayStartBalance = GetOrInitDayStartBalance();
   double dayPnl          = equity - dayStartBalance;
   double peakEquity      = UpdatePeakEquity(equity);
   double drawdownPct     = (peakEquity > 0) ? ((peakEquity - equity) / peakEquity * 100.0) : 0.0;

   SymbolAgg aggs[];
   int total = OrdersTotal();

   string positionsJson = "[";
   int included = 0;
   for(int i = 0; i < total; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue; // skip pending orders

      string sym         = OrderSymbol();
      double vol           = OrderLots();
      double rawProfit      = OrderProfit();
      double swap           = OrderSwap();
      double commission     = OrderCommission();
      double totalProfit    = rawProfit + swap + commission;
      double openPrice       = OrderOpenPrice();
      double currentPrice    = (OrderType() == OP_BUY) ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
      double sl              = OrderStopLoss();
      double tp              = OrderTakeProfit();
      int    durationMin     = (int)((TimeCurrent() - OrderOpenTime()) / 60);
      string typeStr          = (OrderType() == OP_BUY) ? "BUY" : "SELL";

      if(included > 0) positionsJson += ",";
      positionsJson += "{";
      positionsJson += "\"symbol\":\"" + JsonEsc(sym) + "\",";
      positionsJson += "\"type\":\"" + typeStr + "\",";
      positionsJson += "\"volume\":" + DoubleToString(vol, 2) + ",";
      positionsJson += "\"profit\":" + DoubleToString(totalProfit, 2) + ",";
      positionsJson += "\"open_price\":" + DoubleToString(openPrice, Digits) + ",";
      positionsJson += "\"current_price\":" + DoubleToString(currentPrice, Digits) + ",";
      positionsJson += "\"sl\":" + DoubleToString(sl, Digits) + ",";
      positionsJson += "\"tp\":" + DoubleToString(tp, Digits) + ",";
      positionsJson += "\"swap\":" + DoubleToString(swap, 2) + ",";
      positionsJson += "\"duration_min\":" + IntegerToString(durationMin);
      positionsJson += "}";
      included++;

      if(InpSendSymbolBreakdown)
      {
         int idx = FindOrAddSymbol(aggs, sym);
         aggs[idx].leg_count++;
         aggs[idx].entry_weighted_sum += openPrice * vol;
         aggs[idx].volume_sum         += vol;
         aggs[idx].open_profit        += rawProfit;
         aggs[idx].open_swap          += swap;
         aggs[idx].closed_commission  += commission; // MT4 charges commission at open, safe to count now
      }
   }
   positionsJson += "]";
   if(!InpSendPositions){ positionsJson = "[]"; }

   string symbolsJson = "[]";
   if(InpSendSymbolBreakdown)
   {
      // add today's already-closed trades (realized profit/swap/commission) per symbol
      datetime dayStart = StrToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 00:00");
      int histTotal = OrdersHistoryTotal();
      for(int i = 0; i < histTotal; i++)
      {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         if(OrderCloseTime() < dayStart) continue; // only trades closed today

         string sym = OrderSymbol();
         int idx = FindOrAddSymbol(aggs, sym);
         aggs[idx].closed_profit     += OrderProfit();
         aggs[idx].closed_swap       += OrderSwap();
         aggs[idx].closed_commission += OrderCommission();
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
            symbolsJson += "\"avg_entry\":" + DoubleToString(avgEntry, Digits) + ",";
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
   json += "\"platform\":\"MT4\",";
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
   json += "\"open_positions\":" + IntegerToString(included) + ",";
   json += "\"positions\":" + positionsJson + ",";
   json += "\"symbols\":" + symbolsJson + ",";
   json += "\"server_time\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\"";
   json += "}";

   string headers = "Content-Type: application/json\r\n";
   char postData[];
   int len = StringToCharArray(json, postData) - 1;
   ArrayResize(postData, len);

   char result[];
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
      Print("PnLReporter: server responded with HTTP ", res);
   }
}
//+------------------------------------------------------------------+
