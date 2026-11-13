"""UTC calendar periods shared by export scheduling and billing-data readers."""

from datetime import datetime, timedelta, timezone

DEFAULT_HISTORY_MONTHS = 2


def completed_month_bounds(now: datetime, count: int = DEFAULT_HISTORY_MONTHS) -> list[tuple[datetime, datetime]]:
    boundary = now.astimezone(timezone.utc).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    result = []
    for _ in range(count):
        end = boundary - timedelta(seconds=1)
        start = end.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        result.append((start, end))
        boundary = start
    return list(reversed(result))


def recent_closed_runs(
    runs_by_subscription: dict[str, list[dict]], now: datetime, count: int = DEFAULT_HISTORY_MONTHS,
) -> dict[str, list[dict]]:
    allowed = {(f"{start:%Y-%m-%d}", f"{end:%Y-%m-%d}") for start, end in completed_month_bounds(now, count)}
    result: dict[str, list[dict]] = {}
    for subscription_id, runs in runs_by_subscription.items():
        result[subscription_id] = []
        for run in runs:
            properties = run.get("properties") or {}
            period = (str(properties.get("startDate", ""))[:10], str(properties.get("endDate", ""))[:10])
            if properties.get("status") == "Completed" and period in allowed:
                result[subscription_id].append(run)
    return result
