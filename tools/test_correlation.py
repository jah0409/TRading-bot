#!/usr/bin/env python3
"""
test_correlation.py - validate the portfolio-risk formula by simulation.

CCorrelationModel::PortfolioRisk computes

    sqrt( SUM_i SUM_j  r_i r_j rho_ij )

with r signed. That is the standard deviation of the combined outcome when
each position's result is proportional to its own risk and the positions move
together with correlation rho. Getting it wrong would silently mis-size
concentrated exposure, so it is checked against Monte Carlo rather than
trusted from the algebra.

Also demonstrates the property the model exists for: two correlated longs are
close to one doubled bet, while a long/short pair in the same instruments is
nearly flat.

  python3 tools/test_correlation.py
"""
from __future__ import annotations

import numpy as np


def portfolio_risk(signed_risk: np.ndarray, rho: np.ndarray) -> float:
    """Mirror of CCorrelationModel::PortfolioRisk (negatives clamped to 0)."""
    total = float(signed_risk @ rho @ signed_risk)
    return float(np.sqrt(total)) if total > 0 else 0.0


def monte_carlo(signed_risk: np.ndarray, rho: np.ndarray, draws=400_000, seed=0) -> float:
    """Empirical stdev of the combined P/L under a correlated normal shock."""
    g = np.random.default_rng(seed)
    L = np.linalg.cholesky(rho + 1e-12 * np.eye(len(rho)))
    z = g.standard_normal((draws, len(rho))) @ L.T
    return float((z * signed_risk).sum(axis=1).std())


def main():
    print("\n=== portfolio risk: formula vs Monte Carlo ===\n")
    cases = [
        ("two longs, rho=+0.8  (doubled-up bet)", np.array([100.0, 100.0]), 0.8),
        ("two longs, rho=0.0   (independent)", np.array([100.0, 100.0]), 0.0),
        ("long+short, rho=+0.8 (hedge)", np.array([100.0, -100.0]), 0.8),
        ("long+short, rho=-0.8 (doubled via inverse)", np.array([100.0, -100.0]), -0.8),
        ("uneven, rho=+0.5", np.array([150.0, -60.0]), 0.5),
    ]
    worst = 0.0
    print(f"  {'case':<42}{'formula':>10}{'monte carlo':>13}{'diff':>8}")
    print("  " + "-" * 73)
    for name, r, p in cases:
        rho = np.array([[1.0, p], [p, 1.0]])
        f, m = portfolio_risk(r, rho), monte_carlo(r, rho)
        diff = abs(f - m) / max(m, 1e-9)
        worst = max(worst, diff)
        print(f"  {name:<42}{f:>10.2f}{m:>13.2f}{diff:>7.2%}")

    print(f"\n  worst relative error: {worst:.3%}   "
          f"{'OK' if worst < 0.01 else '*** FORMULA WRONG ***'}")

    # three symbols, to exercise the clamp path
    print("\n=== three-symbol sanity ===\n")
    rho3 = np.array([[1.0, 0.8, 0.3], [0.8, 1.0, 0.25], [0.3, 0.25, 1.0]])
    r3 = np.array([100.0, 100.0, 100.0])
    f, m = portfolio_risk(r3, rho3), monte_carlo(r3, rho3)
    print(f"  three correlated longs: formula {f:.2f}  monte carlo {m:.2f}  "
          f"(naive sum would be {r3.sum():.0f})")

    print("\n=== what the cap actually does (basis $10,000, cap 2%) ===\n")
    basis, cap = 10_000.0, 2.0
    for p in (-0.5, 0.0, 0.5, 0.8, 0.95):
        rho = np.array([[1.0, p], [p, 1.0]])
        r = np.array([100.0, 100.0])          # two 1% longs
        pct = portfolio_risk(r, rho) / basis * 100
        print(f"  two 1% LONGS  rho={p:+.2f}  ->  {pct:.2f}%  "
              f"{'BLOCKED' if pct > cap else 'allowed'}")
    for p in (0.8,):
        rho = np.array([[1.0, p], [p, 1.0]])
        r = np.array([100.0, -100.0])
        pct = portfolio_risk(r, rho) / basis * 100
        print(f"  1% long + 1% SHORT rho={p:+.2f}  ->  {pct:.2f}%  "
              f"{'BLOCKED' if pct > cap else 'allowed'}  <- a hedge is not concentration")

    print("\n=== where the cap actually engages ===\n")
    print("  With 2 symbols the cap is a CONCENTRATION limit, not a per-pair one:")
    print("  two 1% longs never breach 2% however correlated (max 2.00%). It bites")
    print("  once you stack positions, which is the intent.\n")
    p = 0.8
    rho = np.array([[1.0, p], [p, 1.0]])
    for n_xau, n_idx in ((1, 1), (2, 1), (2, 2), (3, 2)):
        r = np.array([100.0 * n_xau, 100.0 * n_idx])
        pct = portfolio_risk(r, rho) / basis * 100
        naive = (n_xau + n_idx) * 1.0
        print(f"  {n_xau} x 1% XAU long + {n_idx} x 1% IDX long (rho {p:+.1f})"
              f"  ->  {pct:.2f}%  (naive sum {naive:.0f}%)  "
              f"{'BLOCKED' if pct > cap else 'allowed'}")

    print("\n  Note: this cap is ADDITIONAL. risk.aggregate_stop_cap_pct still")
    print("  counts the plain sum of absolute stops, because correlation")
    print("  describes typical days and stops all gap together on the atypical one.\n")


if __name__ == "__main__":
    main()
