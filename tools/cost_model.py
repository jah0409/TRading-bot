#!/usr/bin/env python3
"""
cost_model.py - what a trade actually costs on XAUUSD.

The supplied data has no bid/ask and no ticks, so every number here is an
ASSUMPTION, not a measurement. They are stated explicitly and kept pessimistic:
a backtest that flatters the fill is worse than no backtest.

Defaults are for a typical prop-firm gold feed. Override them with your own
broker's numbers - and if you ever record real spread, replace this module
with the measurement.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np


@dataclass
class CostModel:
    # price units (USD per oz). 0.25 = 25 "points" on a 2-digit gold feed.
    spread: float = 0.28
    #: spread multiplier during the London/NY overlap (tighter) and dead zone
    spread_overlap_mult: float = 0.8
    spread_dead_mult: float = 1.8
    #: spread blows out around scheduled news
    spread_news_mult: float = 4.0
    #: adverse price movement between decision and fill
    slippage_entry: float = 0.10
    #: stops slip further than entries - they fill into a moving market
    slippage_stop: float = 0.25
    #: limit/target fills do not slip in your favour, but they do not slip against you either
    slippage_target: float = 0.0
    #: round-turn commission in account currency per 1.0 lot (100 oz)
    commission_per_lot: float = 7.0
    #: contract size, oz per lot
    contract_size: float = 100.0
    #: bars of delay between signal and fill (0 = next bar open, the default)
    execution_delay_bars: int = 0

    def spread_at(self, session: np.ndarray | None = None,
                  news: np.ndarray | None = None, n: int = 1) -> np.ndarray:
        """Per-bar spread, widened for dead hours and news."""
        s = np.full(n, self.spread, dtype=float)
        if session is not None:
            s = np.where(session == "OVERLAP", s * self.spread_overlap_mult, s)
            s = np.where(session == "DEAD", s * self.spread_dead_mult, s)
        if news is not None:
            s = np.where(news, s * self.spread_news_mult, s)
        return s

    def entry_cost(self, spread: np.ndarray | float) -> np.ndarray | float:
        """Price units paid crossing the spread, plus entry slippage."""
        return spread + self.slippage_entry

    def commission_in_r(self, risk_price: float, lots: float = 0.01) -> float:
        """Commission expressed in R.

        R is the stop distance in price. A round turn costs
        commission_per_lot * lots, and the position risks
        risk_price * contract_size * lots - so the lot size cancels and the
        cost in R depends only on how wide the stop is. A tight stop pays a
        much larger fraction of its risk in commission, which is exactly the
        effect a fixed per-trade cost number hides.
        """
        if risk_price <= 0:
            return 0.0
        return self.commission_per_lot / (risk_price * self.contract_size)

    def describe(self) -> str:
        return (f"spread {self.spread:.2f} (overlap x{self.spread_overlap_mult}, "
                f"dead x{self.spread_dead_mult}, news x{self.spread_news_mult}), "
                f"slip entry {self.slippage_entry:.2f} / stop {self.slippage_stop:.2f}, "
                f"commission ${self.commission_per_lot:.2f}/lot round turn")


#: A deliberately harsh model, for checking an edge is not a rounding artefact.
PESSIMISTIC = CostModel(spread=0.45, slippage_entry=0.20, slippage_stop=0.45,
                        commission_per_lot=10.0)
#: Roughly a good ECN account.
OPTIMISTIC = CostModel(spread=0.18, slippage_entry=0.05, slippage_stop=0.12,
                       commission_per_lot=6.0)
