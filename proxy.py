"""PMCC Radar IBKR proxy — FastAPI service.

Runs on the VPS. Holds a persistent connection to IB Gateway and exposes
clean REST endpoints for the Streamlit app.

Auth: shared secret in the X-PMCC-Token header.
Gateway: connects to IB Gateway on localhost:4002 (paper) or :4001 (live).
"""
from __future__ import annotations

import asyncio
import logging
import math
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from ib_insync import IB, Stock, Option, util

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("pmcc-proxy")

PMCC_TOKEN = os.environ.get("PMCC_PROXY_TOKEN", "")
IB_HOST = os.environ.get("IB_HOST", "127.0.0.1")
IB_PORT = int(os.environ.get("IB_PORT", "4002"))
IB_CLIENT_ID = int(os.environ.get("IB_CLIENT_ID", "17"))

# Cache chain lookups briefly to avoid hammering IBKR on repeated requests.
_CHAIN_CACHE: dict[str, tuple[float, Any]] = {}
CHAIN_TTL = 60  # seconds


# ---------------------------------------------------- Gateway connection manager
class GatewayClient:
    """Wraps ib_insync.IB with lazy connect + reconnect."""

    def __init__(self):
        self.ib = IB()
        self._connecting = False
        self._market_data_type_set = False

    async def ensure_connected(self) -> None:
        if self.ib.isConnected():
            # Make sure delayed-frozen mode is enabled even on warm connections
            if not self._market_data_type_set:
                try:
                    # 3 = DELAYED, 4 = DELAYED_FROZEN. Use 4 so we always get last
                    # known price even after hours / without a live subscription.
                    self.ib.reqMarketDataType(4)
                    self._market_data_type_set = True
                except Exception as e:
                    log.warning(f"reqMarketDataType failed: {e}")
            return
        if self._connecting:
            # Another request is mid-connect; wait a bit
            for _ in range(40):
                await asyncio.sleep(0.25)
                if self.ib.isConnected():
                    return
        self._connecting = True
        try:
            log.info(f"Connecting to IB Gateway at {IB_HOST}:{IB_PORT} clientId={IB_CLIENT_ID}")
            await self.ib.connectAsync(IB_HOST, IB_PORT, clientId=IB_CLIENT_ID, timeout=15)
            log.info("Connected.")
        finally:
            self._connecting = False

    async def disconnect(self):
        if self.ib.isConnected():
            self.ib.disconnect()


gateway = GatewayClient()


# ---------------------------------------------------- FastAPI lifespan
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Try to connect at startup — but if Gateway isn't up yet, don't crash.
    try:
        await gateway.ensure_connected()
    except Exception as e:
        log.warning(f"Initial Gateway connect failed (will retry on demand): {e}")
    yield
    await gateway.disconnect()


app = FastAPI(title="PMCC Proxy", version="1.0.0", lifespan=lifespan)


# ---------------------------------------------------- Auth dependency
async def require_token(x_pmcc_token: str = Header(default="")):
    if not PMCC_TOKEN:
        raise HTTPException(500, "Proxy not configured with token")
    if x_pmcc_token != PMCC_TOKEN:
        raise HTTPException(401, "Invalid token")


# ---------------------------------------------------- Health (no auth)
@app.get("/health")
async def health():
    return {
        "ok": True,
        "gateway_connected": gateway.ib.isConnected(),
        "server_time": datetime.now(timezone.utc).isoformat(),
    }


def _clean(x):
    """Convert NaN/Inf to None so JSON serialization doesn't crash."""
    try:
        xf = float(x)
    except (TypeError, ValueError):
        return None
    if math.isnan(xf) or math.isinf(xf):
        return None
    return xf


def _pick_price(ticker):
    """Pick the best non-NaN price from a ticker (incl. delayed fields)."""
    # Live fields first, then delayed (prefixed), then close
    candidates = [
        getattr(ticker, "last", None),
        getattr(ticker, "marketPrice", lambda: None)() if callable(getattr(ticker, "marketPrice", None)) else None,
        getattr(ticker, "delayedLast", None),
        getattr(ticker, "close", None),
        getattr(ticker, "delayedClose", None),
        # Mid of bid/ask as last resort
        ((ticker.bid + ticker.ask) / 2) if getattr(ticker, "bid", None) and getattr(ticker, "ask", None) else None,
        ((getattr(ticker, "delayedBid", 0) or 0) + (getattr(ticker, "delayedAsk", 0) or 0)) / 2 or None,
    ]
    for c in candidates:
        v = _clean(c)
        if v is not None and v > 0:
            return v
    return None


# ---------------------------------------------------- Spot price
@app.get("/spot/{symbol}", dependencies=[Depends(require_token)])
async def spot(symbol: str):
    await gateway.ensure_connected()
    contract = Stock(symbol.upper(), "SMART", "USD")
    await gateway.ib.qualifyContractsAsync(contract)
    ticker = gateway.ib.reqMktData(contract, "", False, False)
    # Give IBKR a moment to populate (delayed data can take 2-3s to arrive)
    price = None
    for _ in range(40):
        await asyncio.sleep(0.1)
        price = _pick_price(ticker)
        if price:
            break
    gateway.ib.cancelMktData(contract)
    return {
        "symbol": symbol.upper(),
        "price": price,
        "bid": _clean(getattr(ticker, "bid", None)) or _clean(getattr(ticker, "delayedBid", None)),
        "ask": _clean(getattr(ticker, "ask", None)) or _clean(getattr(ticker, "delayedAsk", None)),
        "close": _clean(getattr(ticker, "close", None)) or _clean(getattr(ticker, "delayedClose", None)),
        "delayed": price is not None and not _clean(getattr(ticker, "last", None)),
    }


# ---------------------------------------------------- Options chain
@app.get("/chain/{symbol}", dependencies=[Depends(require_token)])
async def chain(
    symbol: str,
    expiry: Optional[str] = Query(None, description="YYYYMMDD or YYYY-MM-DD"),
):
    """Get option chain for a given expiry. If no expiry given, return list of expiries."""
    await gateway.ensure_connected()
    sym = symbol.upper()

    # Cache key
    ck = f"{sym}:{expiry or 'list'}"
    now = time.time()
    if ck in _CHAIN_CACHE and now - _CHAIN_CACHE[ck][0] < CHAIN_TTL:
        return _CHAIN_CACHE[ck][1]

    stock = Stock(sym, "SMART", "USD")
    await gateway.ib.qualifyContractsAsync(stock)

    # Get all option params for the underlying
    chains = await gateway.ib.reqSecDefOptParamsAsync(
        stock.symbol, "", stock.secType, stock.conId
    )
    if not chains:
        raise HTTPException(404, f"No option chain for {sym}")

    # Prefer SMART / CBOE2 exchange (most liquid)
    preferred = next((c for c in chains if c.exchange == "SMART"), chains[0])
    expirations = sorted(preferred.expirations)

    if not expiry:
        result = {
            "symbol": sym,
            "expirations": expirations,
            "strikes_count": len(preferred.strikes),
        }
        _CHAIN_CACHE[ck] = (now, result)
        return result

    # Normalize expiry format
    exp_norm = expiry.replace("-", "")
    if exp_norm not in expirations:
        raise HTTPException(404, f"Expiry {expiry} not listed for {sym}")

    # Request all call strikes for this expiry
    strikes = sorted(preferred.strikes)
    contracts = [
        Option(sym, exp_norm, k, "C", "SMART", tradingClass=preferred.tradingClass)
        for k in strikes
    ]
    # Qualify in batches to avoid overload
    qualified = []
    for i in range(0, len(contracts), 50):
        batch = contracts[i : i + 50]
        q = await gateway.ib.qualifyContractsAsync(*batch)
        qualified.extend([c for c in q if c.conId])

    if not qualified:
        raise HTTPException(404, f"Could not qualify any contracts for {sym} {expiry}")

    # Pull market data with greeks
    tickers = []
    for c in qualified:
        tk = gateway.ib.reqMktData(c, "106", False, False)  # 106 = ImpliedVolatility
        tickers.append((c, tk))

    # Wait for data to populate
    await asyncio.sleep(2.5)

    rows = []
    for c, tk in tickers:
        mg = tk.modelGreeks
        rows.append({
            "strike": c.strike,
            "expiry": c.lastTradeDateOrContractMonth,
            "right": c.right,
            "bid": float(tk.bid) if tk.bid and not math.isnan(tk.bid) else None,
            "ask": float(tk.ask) if tk.ask and not math.isnan(tk.ask) else None,
            "last": float(tk.last) if tk.last and not math.isnan(tk.last) else None,
            "volume": int(tk.volume) if tk.volume and not math.isnan(tk.volume) else 0,
            "open_interest": (
                int(tk.callOpenInterest) if tk.callOpenInterest and not math.isnan(tk.callOpenInterest) else 0
            ),
            "iv": float(mg.impliedVol) if mg and mg.impliedVol and not math.isnan(mg.impliedVol) else None,
            "delta": float(mg.delta) if mg and mg.delta and not math.isnan(mg.delta) else None,
            "gamma": float(mg.gamma) if mg and mg.gamma and not math.isnan(mg.gamma) else None,
            "theta": float(mg.theta) if mg and mg.theta and not math.isnan(mg.theta) else None,
            "vega": float(mg.vega) if mg and mg.vega and not math.isnan(mg.vega) else None,
        })

    # Cancel all the mkt data subs to free bandwidth
    for c, _ in tickers:
        gateway.ib.cancelMktData(c)

    result = {"symbol": sym, "expiry": exp_norm, "rows": rows}
    _CHAIN_CACHE[ck] = (now, result)
    return result


# ---------------------------------------------------- Portfolio
def _f(x, default=0.0):
    """Safe float conversion."""
    try:
        if x is None:
            return default
        v = float(x)
        if math.isnan(v) or math.isinf(v):
            return default
        return v
    except (TypeError, ValueError):
        return default


@app.get("/positions", dependencies=[Depends(require_token)])
async def positions():
    await gateway.ensure_connected()
    # Use reqPositionsAsync to avoid "event loop is already running" error
    # under uvicorn/uvloop. The sync gateway.ib.positions() calls
    # loop.run_until_complete on the already-running event loop.
    try:
        pos = await gateway.ib.reqPositionsAsync()
    except AttributeError:
        # Fallback: positions() is cache-only and doesn't hit the event loop
        # when positions are already subscribed.
        pos = gateway.ib.positions()

    # Also fetch portfolio items for market price / unrealized P/L (per-account)
    portfolio_by_conid: dict[int, Any] = {}
    try:
        accounts = gateway.ib.managedAccounts()
        for acct_code in accounts:
            for item in gateway.ib.portfolio(acct_code):
                portfolio_by_conid[item.contract.conId] = item
    except Exception as e:
        log.warning(f"portfolio() lookup failed: {e}")

    rows = []
    for p in pos:
        pf = portfolio_by_conid.get(p.contract.conId)
        rows.append({
            "account": p.account,
            "symbol": p.contract.symbol,
            "sec_type": p.contract.secType,
            "right": getattr(p.contract, "right", None) or None,
            "strike": _f(getattr(p.contract, "strike", None)) or None,
            "expiry": getattr(p.contract, "lastTradeDateOrContractMonth", None) or None,
            "position": _f(p.position),
            "avg_cost": _f(p.avgCost),
            "market_price": _f(getattr(pf, "marketPrice", 0)) if pf else 0.0,
            "market_value": _f(getattr(pf, "marketValue", 0)) if pf else 0.0,
            "unrealized_pnl": _f(getattr(pf, "unrealizedPNL", 0)) if pf else 0.0,
        })
    return {"positions": rows}


@app.get("/account", dependencies=[Depends(require_token)])
async def account():
    await gateway.ensure_connected()
    # Use accountSummaryAsync to avoid "event loop is already running"
    try:
        summary = await gateway.ib.accountSummaryAsync()
    except AttributeError:
        # Older ib_insync versions — fall back to reqAccountSummaryAsync
        try:
            summary = await gateway.ib.reqAccountSummaryAsync()
        except AttributeError:
            summary = gateway.ib.accountSummary()

    def pick(tag: str) -> float:
        for s in summary:
            if s.tag == tag:
                return _f(s.value)
        return 0.0

    return {
        "net_liquidation": pick("NetLiquidation"),
        "buying_power": pick("BuyingPower"),
        "total_cash": pick("TotalCashValue"),
        "available_funds": pick("AvailableFunds"),
        "gross_position_value": pick("GrossPositionValue"),
        "realized_pnl": pick("RealizedPnL"),
        "unrealized_pnl": pick("UnrealizedPnL"),
        "raw": [
            {"account": s.account, "tag": s.tag, "value": s.value, "currency": s.currency}
            for s in summary
        ],
    }
