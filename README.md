# E-commerce Funnel Analysis (Python + SQL)

Where do shoppers drop out between **Browse → Add to Cart → Checkout → Purchase**, which segments leak the most, are the differences statistically real, and what is fixing them worth?

Dataset: 21,663 events, 10,000 sessions, 1 Oct to 31 Oct 2025.

| # | Finding |
|---|---------|
| 1 | Overall conversion from browse to purchase is **10.8%** (1,080 of 10,000 sessions). |
| 2 | The biggest leak is **Checkout → Purchase**: **69.4%** of sessions that reach checkout do not buy (2,444 sessions). Cart → Checkout loses 50.1% and Browse → Cart loses 29.4%. |
| 3 | At the checkout step, Mobile (31.4%), Desktop (31.3%) and Tablet (29.3%) are statistically indistinguishable (best vs worst: p = 0.27). With about 1,150 sessions per device, only gaps of roughly 5.4 points or more are detectable. |
| 4 | Across 12 chi-square tests (4 dimensions × 3 steps, Bonferroni-corrected) **no segment effect is significant**. The leak looks funnel-wide, not specific to a device, channel, region or category. |
| 5 | Raising Checkout → Purchase by 5 points would add about 176 orders and **about 192K in revenue (+16.3%)** at the current average order value of 1,089. |
| 6 | **Data issue:** `Bounce_Flag` is "No" for exactly the sessions that purchased and "Yes" for all others (100% match), so it measures non-conversion, not bounces. |

## Resume bullets

- Analysed 21.6K e-commerce events (10K sessions) in Python and SQL to build a Browse → Cart → Checkout → Purchase funnel; identified checkout-to-purchase as the largest leak (69% drop-off, 10.8% overall conversion).
- Tested 12 segment comparisons with chi-square and Bonferroni correction plus a power analysis, showing no device, channel, region or category effect was detectable (minimum detectable gap about 5 points), which redirected the recommendation to funnel-wide fixes.
- Audited data quality and found `Bounce_Flag` duplicated the non-purchase flag and session attributes changed mid-session; documented assumptions and reconciled Python and SQL results exactly.
- Estimated revenue impact: a 5-point checkout improvement is worth about 16% more revenue.

![Funnel](images/01_funnel.png)
![Step conversion by segment](images/02_step_conversion_by_segment.png)

## Approach

1. **Data-quality audit** of nulls, duplicates, event labels, timestamps, within-session attribute changes, revenue consistency and bounce-flag consistency.
2. **Cleaning and features:** standardised labels, removed exact duplicates, sorted events with stage order as the tie-breaker, derived date, weekday, hour, ISO week and event sequence.
3. **Session-level table.** A session has *reached* a stage if its deepest event is that stage or later, so a skipped step does not break the funnel.
4. **Funnel and segment analysis** by device, channel, region and product category.
5. **Time analysis:** hour, weekday, weekly trend, and minutes between stages.
6. **Statistical testing:** chi-square with Cramér's V per dimension and step, Bonferroni correction for 12 tests, and a two-proportion z-test with a 95% confidence interval for the best vs worst device.
7. **Revenue impact simulation:** extra purchases and revenue if the biggest leak improved by 1, 2, 5 or 10 points.
8. **SQL reproduction** with CTEs, window functions (`LAG`, `FIRST_VALUE`, `ROW_NUMBER`, moving average) in `funnel_analysis.sql`. Results were checked against the notebook.

## Assumptions and data caveats

- Session attributes (device, channel, region, category) can change between events of the same session. **The first event of each session is used** for segmentation.
- Device, channel and region change between events in 56% to 60% of sessions, so the data is almost certainly synthetic or merged from several sources.
- `Bounce_Flag` mirrors "did not purchase" in every session, so bounce analysis uses a behavioural definition (single-event session, 29.4% of sessions) instead.
- Time between stages is always 1 to 5 minutes, which looks generated, so no timing conclusions are drawn.
- Each user has one session, so repeat-purchase and retention analysis are out of scope.
- The data is observational. Segment differences show association, not causation.

## Repository structure

```
├── Funnel_Analysis.ipynb      # full analysis
├── funnel_analysis.sql        # SQL version (SQLite dialect, PostgreSQL notes inline)
├── Funnel_analysis_data.csv   # raw data (add your file here)
├── requirements.txt
├── images/                    # charts saved by the notebook
└── outputs/                   # CSVs for Power BI / Tableau + executive_summary.txt
```

## How to run

```bash
python -m venv .venv && source .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install -r requirements.txt
jupyter notebook Funnel_Analysis.ipynb                 # Run > Run All Cells
```

SQL: `sqlite3 funnel.db`, then `.mode csv`, `.import --skip 1 Funnel_analysis_data.csv raw_events`, then run `funnel_analysis.sql`.

## Skills demonstrated

Python (pandas, NumPy, SciPy), SQL (CTEs, window functions), data cleaning and validation, funnel and cohort-style segmentation, hypothesis testing and multiple-comparison correction, data visualisation (Matplotlib, Seaborn, Plotly), business impact estimation.

## Next steps

- Power BI / Tableau dashboard built from `outputs/*.csv` (funnel chart, device and channel filters).
- Repeat the analysis on a real dataset (for example REES46 e-commerce behaviour data).
- Propose an A/B test for the checkout step.
