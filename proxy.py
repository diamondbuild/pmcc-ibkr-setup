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

    async def ensure_connected(self) -> None:
        if self.ib.isConnected():
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


# ---------------------------------------------------- Spot price
@app.get("/spot/{symbol}", dependencies=[Depends(require_token)])
async def spot(symbol: str):
    await gateway.ensure_connected()
    contract = Stock(symbol.upper(), "SMART", "USD")
    await gateway.ib.qualifyContractsAsync(contract)
    ticker = gateway.ib.reqMktData(contract, "", False, False)
    # Give IBKR a moment to populate
    for _ in range(20):
        await asyncio.sleep(0.1)
        if ticker.last or ticker.close or ticker.marketPrice():
            break
    price = ticker.last or ticker.close or ticker.marketPrice()
    gateway.ib.cancelMktData(contract)
    return {"symbol": symbol.upper(), "price": float(price) if price else None}


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
@app.get("/positions", dependencies=[Depends(require_token)])
async def positions():
    await gateway.ensure_connected()
    pos = gateway.ib.positions()
    return [
        {
            "account": p.account,
            "symbol": p.contract.symbol,
            "sec_type": p.contract.secType,
            "right": getattr(p.contract, "right", None),
            "strike": getattr(p.contract, "strike", None),
            "expiry": getattr(p.contract, "lastTradeDateOrContractMonth", None),
            "position": float(p.position),
            "avg_cost": float(p.avgCost),
        }
        for p in pos
    ]


@app.get("/account", dependencies=[Depends(require_token)])
async def account():
    await gateway.ensure_connected()
    summary = gateway.ib.accountSummary()
    return [
        {
            "account": s.account,
            "tag": s.tag,
            "value": s.value,
            "currency": s.currency,
        }
        for s in summary
        if s.tag
        in {
            "NetLiquidation",
            "TotalCashValue",
            "BuyingPower",
            "AvailableFunds",
            "GrossPositionValue",
        }
    ]
