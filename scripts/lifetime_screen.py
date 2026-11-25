#!/usr/bin/env python3
"""PocketCCD lifetime-unlock screen: install-driven model, not MAU-driven.

The existing revenue_model.py assumes a monthly-equivalent per payer, which
flatters a one-time-purchase product. A lifetime unlock earns its full net
price once, so cumulative payers (not MAU) drive the 12-month number.

Run: python3 scripts/lifetime_screen.py
"""

from dataclasses import dataclass

APPLE_CUT = 0.15          # Small Business Program
PRICE = 9.99              # Launch price (competitor lifetime cluster $9.99-$19.99)
NET_PER_PAYER = PRICE * (1 - APPLE_CUT)


@dataclass(frozen=True)
class Scenario:
    name: str
    installs_12m: int
    conversion: float   # install -> payer within the year
    probability: float  # honest prior for a solo developer with no audience

    @property
    def payers(self) -> float:
        return self.installs_12m * self.conversion

    @property
    def revenue(self) -> float:
        return self.payers * NET_PER_PAYER


SCENARIOS = (
    Scenario("Bear", 15_000, 0.008, 0.48),
    Scenario("Base", 50_000, 0.012, 0.40),
    Scenario("Bull", 200_000, 0.018, 0.12),
)

# Post-launch-year steady state: organic trickle installs per month.
TRICKLE_INSTALLS = (1_000, 3_000, 8_000)


def money(v: float) -> str:
    return f"${v:,.0f}"


def main() -> None:
    print(f"Net per payer (${PRICE:.2f} at {APPLE_CUT:.0%} commission): ${NET_PER_PAYER:.2f}\n")

    print(f"{'Scenario':10}{'Installs':>10}{'Conv':>8}{'Payers':>9}{'12m net':>10}{'P(y)':>7}")
    ev = 0.0
    for s in SCENARIOS:
        ev += s.probability * s.revenue
        print(
            f"{s.name:10}{s.installs_12m:>10,}{s.conversion:>8.1%}"
            f"{s.payers:>9,.0f}{money(s.revenue):>10}{s.probability:>7.0%}"
        )
    print(f"\nExpected 12-month revenue: {money(ev)}")

    print("\nSteady-state monthly net after year 1 (organic trickle):")
    for installs in TRICKLE_INSTALLS:
        for conv in (0.008, 0.012, 0.018):
            print(
                f"  {installs:>6,} installs/mo x {conv:.1%} x ${NET_PER_PAYER:.2f}"
                f" = {money(installs * conv * NET_PER_PAYER)}/mo"
            )

    print("\nBreak-even on build time (2 weeks solo at $0 opportunity cost): n/a")
    print("Threshold check: cumulative >= $10,000 and/or month-12 >= $1,500")
    for s in SCENARIOS:
        monthly = s.installs_12m / 12 * s.conversion * NET_PER_PAYER
        print(
            f"  {s.name:6} 12m={money(s.revenue):>8}  month-12~{money(monthly):>7}"
            f"  -> {'PASS' if s.revenue >= 10_000 or monthly >= 1_500 else 'FAIL'}"
        )


if __name__ == "__main__":
    main()
