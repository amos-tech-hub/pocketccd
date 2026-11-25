#!/usr/bin/env python3
"""Small, dependency-free PocketCCD revenue sensitivity model."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Scenario:
    name: str
    month_12_mau: int
    conversion: float
    net_revenue_per_payer: float

    @property
    def month_12_net(self) -> float:
        return self.month_12_mau * self.conversion * self.net_revenue_per_payer

    @property
    def twelve_month_net(self) -> float:
        # Sum of a linear monthly ramp from 1/12 to 12/12 of month-12 MAU.
        return self.month_12_net * 6.5


SCENARIOS = (
    Scenario("Conservative", 5_000, 0.01, 3.40),
    Scenario("Base", 25_000, 0.02, 3.40),
    Scenario("Upside", 100_000, 0.03, 4.25),
)

MAU_LEVELS = (5_000, 10_000, 25_000, 50_000, 100_000)
CONVERSIONS = (0.01, 0.02, 0.03, 0.05)
DEFAULT_NET_REVENUE_PER_PAYER = 3.40


def money(value: float) -> str:
    return f"${value:,.0f}"


def main() -> None:
    print("Scenarios")
    for scenario in SCENARIOS:
        print(
            f"{scenario.name:12} "
            f"month-12={money(scenario.month_12_net):>8} "
            f"12-month={money(scenario.twelve_month_net):>9}"
        )

    print("\nSensitivity matrix at $3.40 net revenue per payer")
    print("MAU       " + " ".join(f"{value:.0%}".rjust(8) for value in CONVERSIONS))
    for mau in MAU_LEVELS:
        values = (
            mau * conversion * DEFAULT_NET_REVENUE_PER_PAYER
            for conversion in CONVERSIONS
        )
        print(f"{mau:>7,} " + " ".join(money(value).rjust(8) for value in values))


if __name__ == "__main__":
    main()

