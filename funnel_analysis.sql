-- =====================================================================
-- E-commerce Funnel Analysis  |  SQL version (SQLite dialect)
-- Reproduces the Python notebook: Browse -> Add to Cart -> Checkout -> Purchase
-- PostgreSQL notes are given in comments where the syntax differs.
--
-- Setup (SQLite shell):
--   sqlite3 funnel.db
--   .mode csv
--   .import --skip 1 Funnel_analysis_data.csv raw_events
--   (or create raw_events first with these columns:
--    User_ID, Session_ID, Event, Timestamp, Device, Region, Channel,
--    Product_Category, Revenue, Bounce_Flag)
-- Timestamp must be stored as text 'YYYY-MM-DD HH:MM:SS'.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Clean events: standardise labels, drop exact duplicates and bad rows
--    stage_no gives the funnel order and breaks timestamp ties
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS clean_events;
CREATE VIEW clean_events AS
SELECT DISTINCT
    User_ID, Session_ID, Event, Timestamp,
    Device, Region, Channel, Product_Category,
    CAST(Revenue AS REAL) AS Revenue, Bounce_Flag, stage_no
FROM (
    SELECT
        TRIM(User_ID) AS User_ID, TRIM(Session_ID) AS Session_ID,
        CASE LOWER(TRIM(Event))
            WHEN 'browse'      THEN 'Browse'
            WHEN 'add to cart' THEN 'Add to Cart'
            WHEN 'checkout'    THEN 'Checkout'
            WHEN 'purchase'    THEN 'Purchase'
        END AS Event,
        CASE LOWER(TRIM(Event))
            WHEN 'browse'      THEN 1
            WHEN 'add to cart' THEN 2
            WHEN 'checkout'    THEN 3
            WHEN 'purchase'    THEN 4
        END AS stage_no,
        Timestamp, TRIM(Device) AS Device, TRIM(Region) AS Region,
        TRIM(Channel) AS Channel, TRIM(Product_Category) AS Product_Category,
        COALESCE(Revenue, 0) AS Revenue, TRIM(Bounce_Flag) AS Bounce_Flag
    FROM raw_events
) t
WHERE stage_no IS NOT NULL AND Timestamp IS NOT NULL AND Session_ID IS NOT NULL;


-- ---------------------------------------------------------------------
-- 2. Session table: one row per session
--    Attributes come from the FIRST event (ROW_NUMBER window function)
--    A session "reached" a stage if max_stage >= that stage_no
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS sessions;
CREATE VIEW sessions AS
WITH ordered AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY Session_ID ORDER BY Timestamp, stage_no) AS rn
    FROM clean_events
),
agg AS (
    SELECT
        Session_ID,
        MIN(Timestamp)                                   AS start_ts,
        COUNT(*)                                         AS events,
        COUNT(DISTINCT stage_no)                         AS stages_seen,
        MAX(stage_no)                                    AS max_stage,
        SUM(Revenue)                                     AS revenue,
        MIN(CASE WHEN stage_no = 1 THEN Timestamp END)   AS t_browse,
        MIN(CASE WHEN stage_no = 2 THEN Timestamp END)   AS t_cart,
        MIN(CASE WHEN stage_no = 3 THEN Timestamp END)   AS t_checkout,
        MIN(CASE WHEN stage_no = 4 THEN Timestamp END)   AS t_purchase
    FROM clean_events
    GROUP BY Session_ID
)
SELECT a.*, o.User_ID, o.Device, o.Region, o.Channel, o.Product_Category, o.Bounce_Flag
FROM agg a
JOIN ordered o ON o.Session_ID = a.Session_ID AND o.rn = 1;


-- ---------------------------------------------------------------------
-- 3. Data-quality checks
-- ---------------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM raw_events)                                        AS raw_rows,
    (SELECT COUNT(*) FROM clean_events)                                      AS clean_rows,
    (SELECT COUNT(*) FROM sessions)                                          AS sessions,
    (SELECT COUNT(DISTINCT User_ID) FROM sessions)                           AS users,
    (SELECT COUNT(*) FROM sessions WHERE stages_seen < max_stage)            AS sessions_skipping_a_stage,
    (SELECT COUNT(*) FROM sessions
      WHERE max_stage >= 3 AND LOWER(Bounce_Flag) = 'yes')                   AS bounced_but_reached_checkout,
    (SELECT COUNT(*) FROM sessions
      WHERE max_stage = 4 AND revenue <= 0)                                  AS purchase_sessions_zero_revenue;


-- ---------------------------------------------------------------------
-- 4. Overall funnel with step and overall conversion (LAG / FIRST_VALUE)
-- ---------------------------------------------------------------------
WITH stages AS (
    SELECT 1 AS stage_no, 'Browse' AS stage UNION ALL
    SELECT 2, 'Add to Cart'                 UNION ALL
    SELECT 3, 'Checkout'                    UNION ALL
    SELECT 4, 'Purchase'
),
stage_counts AS (
    SELECT s.stage_no, s.stage, COUNT(se.Session_ID) AS sessions
    FROM stages s
    LEFT JOIN sessions se ON se.max_stage >= s.stage_no
    GROUP BY s.stage_no, s.stage
)
SELECT
    stage,
    sessions,
    ROUND(100.0 * sessions / LAG(sessions) OVER (ORDER BY stage_no), 1)          AS step_conv_pct,
    ROUND(100.0 - 100.0 * sessions / LAG(sessions) OVER (ORDER BY stage_no), 1)  AS drop_off_pct,
    ROUND(100.0 * sessions / FIRST_VALUE(sessions) OVER (ORDER BY stage_no), 1)  AS overall_conv_pct
FROM stage_counts
ORDER BY stage_no;


-- ---------------------------------------------------------------------
-- 5. Funnel by segment (change Device to Channel / Region / Product_Category)
-- ---------------------------------------------------------------------
SELECT
    Device,
    COUNT(*)                                                              AS sessions,
    ROUND(100.0 * SUM(CASE WHEN max_stage >= 2 THEN 1 ELSE 0 END) / COUNT(*), 1)                          AS browse_to_cart_pct,
    ROUND(100.0 * SUM(CASE WHEN max_stage >= 3 THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN max_stage >= 2 THEN 1 ELSE 0 END), 0), 1)                                AS cart_to_checkout_pct,
    ROUND(100.0 * SUM(CASE WHEN max_stage >= 4 THEN 1 ELSE 0 END)
          / NULLIF(SUM(CASE WHEN max_stage >= 3 THEN 1 ELSE 0 END), 0), 1)                                AS checkout_to_purchase_pct,
    ROUND(100.0 * SUM(CASE WHEN max_stage >= 4 THEN 1 ELSE 0 END) / COUNT(*), 1)                          AS overall_pct,
    ROUND(SUM(revenue), 2)                                                AS revenue,
    ROUND(SUM(revenue) / COUNT(*), 2)                                     AS revenue_per_session
FROM sessions
GROUP BY Device
ORDER BY overall_pct DESC;


-- ---------------------------------------------------------------------
-- 6. Time between stages (minutes): average and median
--    PostgreSQL: EXTRACT(EPOCH FROM (t_checkout::timestamp - t_cart::timestamp)) / 60
--    and PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY mins) for the median
-- ---------------------------------------------------------------------
WITH gaps AS (
    SELECT (julianday(t_checkout) - julianday(t_cart)) * 1440 AS mins
    FROM sessions
    WHERE t_cart IS NOT NULL AND t_checkout IS NOT NULL AND t_checkout >= t_cart
),
ranked AS (
    SELECT mins,
           ROW_NUMBER() OVER (ORDER BY mins) AS rn,
           COUNT(*)     OVER ()              AS n
    FROM gaps
)
SELECT ROUND(AVG(mins), 1) AS median_minutes_cart_to_checkout
FROM ranked
WHERE rn IN ((n + 1) / 2, (n + 2) / 2);


-- ---------------------------------------------------------------------
-- 7. Daily trend with 7-day moving average of conversion
-- ---------------------------------------------------------------------
WITH daily AS (
    SELECT
        DATE(start_ts) AS day,
        COUNT(*) AS sessions,
        SUM(CASE WHEN max_stage = 4 THEN 1 ELSE 0 END) AS purchases
    FROM sessions
    GROUP BY DATE(start_ts)
)
SELECT
    day, sessions, purchases,
    ROUND(100.0 * purchases / sessions, 1) AS conv_pct,
    ROUND(100.0 * SUM(purchases) OVER w / SUM(sessions) OVER w, 1) AS conv_pct_7d_avg
FROM daily
WINDOW w AS (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
ORDER BY day;


-- ---------------------------------------------------------------------
-- 8. Conversion by hour of day
--    PostgreSQL: EXTRACT(HOUR FROM start_ts::timestamp)
-- ---------------------------------------------------------------------
SELECT
    CAST(STRFTIME('%H', start_ts) AS INTEGER) AS hour_of_day,
    COUNT(*) AS sessions,
    ROUND(100.0 * SUM(CASE WHEN max_stage = 4 THEN 1 ELSE 0 END) / COUNT(*), 1) AS conv_pct
FROM sessions
GROUP BY hour_of_day
ORDER BY hour_of_day;


-- ---------------------------------------------------------------------
-- 9. Where do non-purchasing sessions stop? (exit stage distribution)
-- ---------------------------------------------------------------------
SELECT
    CASE max_stage WHEN 1 THEN 'Browse' WHEN 2 THEN 'Add to Cart' WHEN 3 THEN 'Checkout' END AS exit_stage,
    COUNT(*) AS sessions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_exits
FROM sessions
WHERE max_stage < 4
GROUP BY max_stage
ORDER BY max_stage;


-- ---------------------------------------------------------------------
-- 10. Revenue by product category (purchase event) and average order value
-- ---------------------------------------------------------------------
SELECT
    Product_Category,
    COUNT(*)                          AS orders,
    ROUND(SUM(Revenue), 2)            AS revenue,
    ROUND(AVG(Revenue), 2)            AS avg_order_value,
    ROUND(100.0 * SUM(Revenue) / SUM(SUM(Revenue)) OVER (), 1) AS revenue_share_pct
FROM clean_events
WHERE stage_no = 4 AND Revenue > 0
GROUP BY Product_Category
ORDER BY revenue DESC;
