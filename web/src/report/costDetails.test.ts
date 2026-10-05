import { describe, expect, it } from 'vitest';
import { comparisonDate, dailySubscriptionCosts, defaultCostWindow, isMonthToDate, monthToDateWindow, previousCostWindow } from './costDetails';
import type { CostDetailRow, CostDetailSummary } from './models';

describe('month-to-date cost windows', () => {
  const dates = Array.from({ length: 34 }, (_, index) => new Date(Date.UTC(2026, 8, 1 + index)).toISOString().slice(0, 10));
  const details = (partialPeriod?: string | null, rows: CostDetailRow[] = []): CostDetailSummary => ({ status: 'complete', statusMessage: '', costBasis: '', granularity: 'daily', dates, rows, partialPeriod });

  it('opens on the open month to date only when the report marks it', () => {
    const monthToDate = { startDate: '2026-10-01', endDate: '2026-10-04', monthToDate: true };
    expect(monthToDateWindow(details('2026-10'))).toEqual(monthToDate);
    expect(defaultCostWindow(details('2026-10'), dates)).toEqual(monthToDate);
    // Older snapshots, and history whose newest month is not the open one, keep the last 30 days.
    for (const partialPeriod of [undefined, null, '2026-09', 'October']) {
      expect(monthToDateWindow(details(partialPeriod))).toBeNull();
      expect(defaultCostWindow(details(partialPeriod), dates)).toEqual({ startDate: '2026-09-05', endDate: '2026-10-04' });
    }
  });

  it('compares a month to date with the same days of the previous month', () => {
    const window = { startDate: '2026-10-01', endDate: '2026-10-04', monthToDate: true };
    expect(isMonthToDate(window)).toBe(true);
    expect(isMonthToDate({ ...window, startDate: '2026-10-02' })).toBe(false);
    expect(previousCostWindow(window)).toEqual({ startDate: '2026-09-01', endDate: '2026-09-04' });
    expect(comparisonDate(window, 3)).toBe('2026-09-04');
    expect(previousCostWindow({ startDate: '2026-01-01', endDate: '2026-01-05', monthToDate: true })).toEqual({ startDate: '2025-12-01', endDate: '2025-12-05' });
    // Days beyond the previous month's length have no counterpart.
    const march = { startDate: '2026-03-01', endDate: '2026-03-30', monthToDate: true };
    expect(previousCostWindow(march)).toEqual({ startDate: '2026-02-01', endDate: '2026-02-28' });
    expect(comparisonDate(march, 27)).toBe('2026-02-28');
    expect(comparisonDate(march, 28)).toBe('');
    // A rolling range that merely starts on the 1st still compares with the days just before it.
    expect(isMonthToDate({ startDate: '2026-09-01', endDate: '2026-09-07' })).toBe(false);
    expect(previousCostWindow({ startDate: '2026-09-01', endDate: '2026-09-07' })).toEqual({ startDate: '2026-08-25', endDate: '2026-08-31' });
  });

  it('pairs each day of a month to date with the same day of the previous month', () => {
    const row: CostDetailRow = {
      detailId: 'a', subscriptionId: 'sub-1', subscriptionName: 'Sub', resourceId: '/subscriptions/sub-1/x', resourceName: 'x', resourceType: 'x/y',
      resourceGroup: 'group', serviceName: 'Svc', region: 'eastus', tags: {}, tagAttributionSource: '', dailyCosts: { '2026-09-02': 5, '2026-10-02': 8 },
    };
    const days = dailySubscriptionCosts(details('2026-10', [row]), { startDate: '2026-10-01', endDate: '2026-10-04', monthToDate: true })[0].days;
    expect(days[1]).toMatchObject({ date: '2026-10-02', previousDate: '2026-09-02', current: 8, previous: 5 });
  });
});
