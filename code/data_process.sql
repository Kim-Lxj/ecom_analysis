/* =============================================================================
   多平台电商存量经营分析 —— 多表关联与核心指标 SQL 脚本
   数据源：data/ 目录下 9 张业务 CSV（SQLite 内存库，表名与文件名一致）
   方言：  SQLite 3.30+（CTE、窗口函数 LAG / FIRST_VALUE / NTILE / ROW_NUMBER / CUME_DIST）
   约定：
     1. order 为 SQL 保留字，脚本中订单表一律写作 "order"；
     2. 有效订单口径：order_status = '已完成'，GMV = 有效订单 total_amount 之和；
     3. order 表的 order_status / payment_method / shipping_method 存的是字典
        「中文名」，与字典表 name 列关联；platform 存编码，与 platform.code 关联；
     4. shipping_method 字典中 local / same_city 两个 code 同名「同城配送」，
        关联前先按 name 去重（MIN(code)），避免一对多 JOIN 造成金额翻倍；
     5. 统计快照日：2026-12-31（数据中最晚业务时间为 2026-12-28）。
   执行方式：脚本按 -- [[SECTION: 名称]] 切分；setup 段建临时视图，其余每段
             输出一张指标结果表，由 analysis_pipeline.ipynb 逐段读取落盘。
   ============================================================================= */


-- [[SECTION: setup]]
-- 目标：搭建三个可复用的「宽表」临时视图，统一后续所有指标的关联口径

-- 1) 订单宽表：订单主表 + 平台/订单状态/支付方式/配送方式 4 张字典表 + 用户维度
CREATE TEMP VIEW IF NOT EXISTS v_order_enriched AS
WITH ship_dict AS (   -- 配送方式字典按中文名去重，避免「同城配送」重名导致行数放大
    SELECT name, MIN(code) AS code
    FROM shipping_method
    GROUP BY name
),
pay_dict AS (         -- 支付方式字典（名称本身唯一，同样做一次去重保险）
    SELECT name, MIN(code) AS code
    FROM payment_method
    GROUP BY name
)
SELECT
    o.order_id,
    o.global_user_id,
    o.platform                       AS platform_code,     -- 平台编码
    pl.name                          AS platform_name,     -- 平台中文名
    o.order_time,
    o.payment_time,
    o.payment_method,
    pay_dict.code                    AS payment_method_code,
    o.shipping_method,
    ship_dict.code                   AS shipping_method_code,
    o.order_status,
    os.code                          AS status_code,       -- 状态编码（completed 等）
    o.total_amount,
    o.discount_amount,
    o.shipping_fee,
    o.tax_amount,
    o.promotion_id,
    o.coupon_code,
    u.gender,
    u.age,
    u.city,
    u.user_level,
    date(u.registration_date)        AS reg_date           -- 注册日期（date 型）
FROM "order" o
LEFT JOIN platform pl        ON o.platform = pl.code                 -- 平台：编码关联
LEFT JOIN order_status os    ON o.order_status = os.name             -- 状态：中文名关联
LEFT JOIN pay_dict           ON o.payment_method = pay_dict.name     -- 支付：中文名关联
LEFT JOIN ship_dict          ON o.shipping_method = ship_dict.name   -- 配送：中文名关联
LEFT JOIN "user" u           ON o.global_user_id = u.global_user_id; -- 补用户维度

-- 2) 订单明细宽表：明细 + 订单宽表 + 商品维度（品类/标价/库存状态）
CREATE TEMP VIEW IF NOT EXISTS v_item_wide AS
SELECT
    oi.order_item_id,
    oi.order_id,
    oi.global_product_id,
    oi.quantity,
    oi.unit_price,
    oi.item_total,
    e.platform_code,
    e.platform_name,
    e.order_time,
    e.order_status,
    e.status_code,
    e.total_amount,
    e.user_level,
    e.age,
    e.city,
    e.gender,
    p.category,                       -- 一级品类
    p.subcategory,
    p.price          AS list_price,   -- 商品标价
    p.brand,
    p.stock_status
FROM order_item oi
JOIN v_order_enriched e ON oi.order_id = e.order_id
LEFT JOIN product p     ON oi.global_product_id = p.global_product_id;

-- 3) 行为宽表：用户行为 + 平台字典 + 用户维度 + 商品维度（漏斗与 EDA 用）
CREATE TEMP VIEW IF NOT EXISTS v_behavior_wide AS
SELECT
    b.behavior_id,
    b.global_user_id,
    b.global_product_id,
    b.platform,
    b.session_id,
    b.behavior_type,
    b.behavior_time,
    b.duration_seconds,
    b.device_type,
    pl.name            AS platform_name,
    u.gender,
    u.age,
    u.city,
    u.user_level,
    date(u.registration_date) AS reg_date,
    p.category,
    p.price            AS list_price,
    p.stock_status
FROM user_behavior b
LEFT JOIN platform pl ON b.platform = pl.code
LEFT JOIN "user" u    ON b.global_user_id = u.global_user_id
LEFT JOIN product p   ON b.global_product_id = p.global_product_id;

-- 4) RFM 基础视图：仅含「有已完成订单」的用户；R/F/M + NTILE(4) 打分
--    NTILE(4) 按 ORDER BY 的顺序把用户依次放入 1~4 桶：希望「价值越高分越高」，
--    因此价值「越小越差」的指标升序排（最差在第 1 桶=1 分，最优在第 4 桶=4 分）。
--    R：距今天数越小越优 → 按 r_days 降序，天数最大的得 1 分、最近消费的得 4 分；
--    F：频次越高越优 → 按 f_cnt 升序，频次最高的得 4 分；
--    M：金额越高越优 → 按 m_amt 升序，金额最高的得 4 分；
--    并列时以 global_user_id 兜底排序，保证结果可复现。
CREATE TEMP VIEW IF NOT EXISTS v_rfm AS
WITH base AS (
    SELECT
        global_user_id,
        CAST(julianday('2026-12-31') - julianday(MAX(order_time)) AS INT) AS r_days, -- 最近消费距今天数
        COUNT(DISTINCT order_id)        AS f_cnt,   -- 有效订单频次
        ROUND(SUM(total_amount), 2)     AS m_amt    -- 累计有效消费金额
    FROM v_order_enriched
    WHERE order_status = '已完成'
    GROUP BY global_user_id
)
SELECT
    global_user_id,
    r_days,
    f_cnt,
    m_amt,
    NTILE(4) OVER (ORDER BY r_days DESC, global_user_id)                    AS r_score,
    NTILE(4) OVER (ORDER BY f_cnt ASC, m_amt ASC, global_user_id)           AS f_score,
    NTILE(4) OVER (ORDER BY m_amt ASC, f_cnt ASC, global_user_id)           AS m_score
FROM base;

-- 5) RFM 四类用户分层视图（规则互斥且穷尽，详见指标字典）
CREATE TEMP VIEW IF NOT EXISTS v_rfm_seg AS
SELECT
    global_user_id, r_days, f_cnt, m_amt, r_score, f_score, m_score,
    CASE
        WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3            THEN '高价值用户'
        WHEN r_score <= 2 AND (f_score >= 3 OR m_score >= 3)           THEN '流失预警用户'
        WHEN r_score >= 3                                               THEN '潜力用户'
        ELSE                                                                 '低价值用户'
    END AS segment
FROM v_rfm;


-- [[SECTION: dq_fk]]
-- 目标：外键完整性 SQL 复核（与 pandas 结果互证），统计子表在主表匹配不上的孤儿记录数
SELECT 'user_behavior->user'    AS relation_name, COUNT(*) AS orphan_rows
FROM user_behavior b LEFT JOIN "user"  u ON b.global_user_id    = u.global_user_id
WHERE u.global_user_id IS NULL
UNION ALL
SELECT 'user_behavior->product', COUNT(*)
FROM user_behavior b LEFT JOIN product p ON b.global_product_id = p.global_product_id
WHERE p.global_product_id IS NULL
UNION ALL
SELECT 'order->user', COUNT(*)
FROM "order" o LEFT JOIN "user" u ON o.global_user_id = u.global_user_id
WHERE u.global_user_id IS NULL
UNION ALL
SELECT 'order_item->order', COUNT(*)
FROM order_item i LEFT JOIN "order" o ON i.order_id = o.order_id
WHERE o.order_id IS NULL
UNION ALL
SELECT 'order_item->product', COUNT(*)
FROM order_item i LEFT JOIN product p ON i.global_product_id = p.global_product_id
WHERE p.global_product_id IS NULL;


-- [[SECTION: dq_business]]
-- 目标：订单/明细业务规则异常 SQL 复核（负数金额、支付早于下单、下单早于注册）
SELECT
    SUM(CASE WHEN total_amount < 0 THEN 1 ELSE 0 END)                                   AS neg_total_cnt,        -- 订单金额为负
    SUM(CASE WHEN discount_amount < 0 THEN 1 ELSE 0 END)                                AS neg_discount_cnt,     -- 优惠金额为负
    SUM(CASE WHEN payment_time < order_time THEN 1 ELSE 0 END)                          AS pay_before_order_cnt, -- 支付早于下单
    SUM(CASE WHEN date(order_time) < reg_date THEN 1 ELSE 0 END)                        AS order_before_reg_cnt, -- 下单早于注册（时序异常）
    ROUND(100.0 * SUM(CASE WHEN date(order_time) < reg_date THEN 1 ELSE 0 END) / COUNT(*), 2) AS order_before_reg_pct
FROM v_order_enriched;


-- [[SECTION: dq_item]]
-- 目标：订单明细表金额/数量异常 SQL 复核，并验证 item_total = quantity * unit_price
SELECT
    SUM(CASE WHEN quantity <= 0 THEN 1 ELSE 0 END)                          AS qty_le_zero_cnt,
    SUM(CASE WHEN item_total < 0 THEN 1 ELSE 0 END)                         AS neg_item_total_cnt,
    SUM(CASE WHEN ABS(quantity * unit_price - item_total) > 0.02 THEN 1 ELSE 0 END) AS amount_mismatch_cnt, -- 行小计不等于数量乘单价
    ROUND(MAX(ABS(quantity * unit_price - item_total)), 2)                  AS max_mismatch_amt
FROM order_item;


-- [[SECTION: dq_session]]
-- 目标：会话粒度异常检测（同会话出现多个用户 = 串号；用户×商品粒度下单早于浏览）
-- 实现：用 ROW_NUMBER() 取每个「用户×商品」时间最早的一条浏览/下单记录
--       （替代 MIN() 聚合写法，等价于「按时间排序取第一条」，且可在同一 CTE 内保留其他列）
WITH browse_first AS (
    SELECT global_user_id, global_product_id, behavior_time,
           ROW_NUMBER() OVER (PARTITION BY global_user_id, global_product_id
                              ORDER BY behavior_time, behavior_id) AS rn
    FROM user_behavior
    WHERE behavior_type = '浏览'
),
order_first AS (
    SELECT global_user_id, global_product_id, behavior_time,
           ROW_NUMBER() OVER (PARTITION BY global_user_id, global_product_id
                              ORDER BY behavior_time, behavior_id) AS rn
    FROM user_behavior
    WHERE behavior_type = '下单'
)
SELECT
    (SELECT COUNT(*) FROM (
        SELECT session_id FROM user_behavior
        GROUP BY session_id HAVING COUNT(DISTINCT global_user_id) > 1))     AS multiuser_session_cnt,  -- 串号会话数
    (SELECT COUNT(*)
     FROM browse_first br
     JOIN order_first od
       ON br.global_user_id = od.global_user_id
      AND br.global_product_id = od.global_product_id
     WHERE br.rn = 1 AND od.rn = 1
       AND od.behavior_time < br.behavior_time)                            AS pair_inversion_cnt;    -- 下单早于浏览的用户×商品对数


-- [[SECTION: pareto_cumulative]]
-- 阶段2-③ 帕累托**累计贡献曲线**（用户 + SKU 两个口径），用 CUME_DIST() 计算分位
--   说明：头部 20% 的「切分」定义仍由 pareto_user / pareto_sku 分段的 NTILE(5) 给出；
--         本段用 CUME_DIST() 输出 10%~100% 十个累计节点的人数与贡献占比，用于累计贡献曲线与查表。
--         两者不可混用：NTILE 会把余数分配给前面的桶，CUME_DIST<=0.2 的「名次分位」
--         与 NTILE 第 1 桶在人数上可能相差 1（本数据 1,643 用户下为 328 vs 329）。
WITH u AS (
    SELECT m_amt AS amount,
           CUME_DIST() OVER (ORDER BY m_amt DESC, global_user_id) AS cd
    FROM v_rfm
),
sk AS (
    SELECT global_product_id, SUM(item_total) AS amount
    FROM v_item_wide WHERE order_status = '已完成'
    GROUP BY global_product_id
),
s AS (
    SELECT amount,
           CUME_DIST() OVER (ORDER BY amount DESC, global_product_id) AS cd
    FROM sk
),
cuts(cut_pct) AS (VALUES (10),(20),(30),(40),(50),(60),(70),(80),(90),(100))
SELECT '用户' AS scope, cut_pct,
       (SELECT COUNT(*) FROM u  WHERE u.cd  <= cut_pct / 100.0)                                   AS entity_cnt,
       ROUND(100.0 * (SELECT COUNT(*) FROM u WHERE u.cd <= cut_pct / 100.0)
             / (SELECT COUNT(*) FROM u), 2)                                                       AS entity_pct,
       ROUND(100.0 * (SELECT SUM(amount) FROM u WHERE u.cd <= cut_pct / 100.0)
             / (SELECT SUM(amount) FROM u), 2)                                                    AS gmv_pct_cum
FROM cuts
UNION ALL
SELECT 'SKU', cut_pct,
       (SELECT COUNT(*) FROM s  WHERE s.cd  <= cut_pct / 100.0),
       ROUND(100.0 * (SELECT COUNT(*) FROM s WHERE s.cd <= cut_pct / 100.0)
             / (SELECT COUNT(*) FROM s), 2),
       ROUND(100.0 * (SELECT SUM(amount) FROM s WHERE s.cd <= cut_pct / 100.0)
             / (SELECT SUM(amount) FROM s), 2)
FROM cuts
ORDER BY scope, cut_pct;


-- [[SECTION: dq_dict]]
-- 目标：业务表编码合法性校验（平台编码、状态/支付/配送中文名是否都能在字典表命中）
SELECT
    SUM(CASE WHEN pl.code IS NULL THEN 1 ELSE 0 END) AS illegal_platform_cnt,
    SUM(CASE WHEN os.code IS NULL THEN 1 ELSE 0 END) AS illegal_status_cnt,
    SUM(CASE WHEN pm.code IS NULL THEN 1 ELSE 0 END) AS illegal_paymethod_cnt,
    SUM(CASE WHEN sm.code IS NULL THEN 1 ELSE 0 END) AS illegal_shipmethod_cnt
FROM "order" o
LEFT JOIN platform pl                        ON o.platform = pl.code
LEFT JOIN order_status os                    ON o.order_status = os.name
LEFT JOIN (SELECT name, MIN(code) AS code FROM payment_method  GROUP BY name) pm ON o.payment_method = pm.name
LEFT JOIN (SELECT name, MIN(code) AS code FROM shipping_method GROUP BY name) sm ON o.shipping_method = sm.name;


-- [[SECTION: core_metrics]]
-- 指标①：全网 + 分平台 GMV / 有效订单量 / 下单用户数 / 客单价（有效订单=已完成）
WITH base AS (
    SELECT platform_code, platform_name, order_id, global_user_id, total_amount
    FROM v_order_enriched
    WHERE order_status = '已完成'
)
SELECT 'ALL' AS platform_code, '全网' AS platform_name,
       ROUND(SUM(total_amount), 2)              AS gmv,
       COUNT(DISTINCT order_id)                 AS valid_orders,
       COUNT(DISTINCT global_user_id)           AS buyer_users,
       ROUND(SUM(total_amount) * 1.0 / COUNT(DISTINCT order_id), 2) AS aov
FROM base
UNION ALL
SELECT platform_code, MAX(platform_name),
       ROUND(SUM(total_amount), 2),
       COUNT(DISTINCT order_id),
       COUNT(DISTINCT global_user_id),
       ROUND(SUM(total_amount) * 1.0 / COUNT(DISTINCT order_id), 2)
FROM base
GROUP BY platform_code
ORDER BY gmv DESC;


-- [[SECTION: funnel_overall]]
-- 指标②：全网 浏览→加购→下单→支付 漏斗（各环节去重用户数、相邻环节转化率、相对首环节累计转化率）
WITH f AS (
    SELECT behavior_type AS stage, COUNT(DISTINCT global_user_id) AS user_cnt
    FROM v_behavior_wide
    WHERE behavior_type IN ('浏览', '加购', '下单', '支付')
    GROUP BY behavior_type
),
t AS (   -- 加排序号，保证漏斗按业务顺序而非字母序
    SELECT stage, user_cnt,
           CASE stage WHEN '浏览' THEN 1 WHEN '加购' THEN 2 WHEN '下单' THEN 3 ELSE 4 END AS ord
    FROM f
)
SELECT stage, user_cnt,
       ROUND(100.0 * user_cnt / NULLIF(LAG(user_cnt) OVER (ORDER BY ord), 0), 2) AS stage_conv_pct,
       ROUND(100.0 * user_cnt / FIRST_VALUE(user_cnt) OVER (ORDER BY ord
                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING), 2)  AS total_conv_pct
FROM t
ORDER BY ord;


-- [[SECTION: funnel_platform]]
-- 指标②：分平台漏斗（窗口函数按平台分区计算相邻环节转化率）
WITH f AS (
    SELECT platform AS platform_code, platform_name, behavior_type AS stage,
           COUNT(DISTINCT global_user_id) AS user_cnt
    FROM v_behavior_wide
    WHERE behavior_type IN ('浏览', '加购', '下单', '支付')
    GROUP BY platform, platform_name, behavior_type
),
t AS (
    SELECT platform_code, platform_name, stage, user_cnt,
           CASE stage WHEN '浏览' THEN 1 WHEN '加购' THEN 2 WHEN '下单' THEN 3 ELSE 4 END AS ord
    FROM f
)
SELECT platform_code, platform_name, stage, user_cnt,
       ROUND(100.0 * user_cnt /
             NULLIF(LAG(user_cnt) OVER (PARTITION BY platform_code ORDER BY ord), 0), 2) AS stage_conv_pct,
       ROUND(100.0 * user_cnt /
             FIRST_VALUE(user_cnt) OVER (PARTITION BY platform_code ORDER BY ord
                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING), 2) AS total_conv_pct
FROM t
ORDER BY platform_code, ord;


-- [[SECTION: level_metrics]]
-- 指标③：会员等级维度的有效订单量、GMV、GMV 占比、购买用户数与客单价
WITH g AS (
    SELECT user_level,
           COUNT(DISTINCT order_id)       AS valid_orders,
           COUNT(DISTINCT global_user_id) AS buyer_users,
           ROUND(SUM(total_amount), 2)    AS gmv
    FROM v_order_enriched
    WHERE order_status = '已完成'
    GROUP BY user_level
)
SELECT user_level, valid_orders, buyer_users, gmv,
       ROUND(100.0 * gmv / SUM(gmv) OVER (), 2)                          AS gmv_pct,
       ROUND(100.0 * valid_orders / SUM(valid_orders) OVER (), 2)       AS order_pct,
       ROUND(gmv * 1.0 / valid_orders, 2)                                AS aov
FROM g
ORDER BY gmv DESC;


-- [[SECTION: category_sales]]
-- 指标④：一级品类销售额（有效订单明细 item_total 口径）、订单量、动销 SKU 数
SELECT category,
       ROUND(SUM(item_total), 2)              AS gmv,
       COUNT(DISTINCT order_id)               AS valid_orders,
       COUNT(DISTINCT global_product_id)      AS sold_sku_cnt
FROM v_item_wide
WHERE order_status = '已完成'
GROUP BY category
ORDER BY gmv DESC;


-- [[SECTION: monthly_gmv]]
-- 月度 GMV 趋势（仅已完成订单）：月 GMV、有效订单量、购买用户数、客单价
SELECT strftime('%Y-%m', order_time) AS month_id,
       ROUND(SUM(total_amount), 2)        AS gmv,
       COUNT(DISTINCT order_id)           AS valid_orders,
       COUNT(DISTINCT global_user_id)     AS buyer_users,
       ROUND(SUM(total_amount) * 1.0 / COUNT(DISTINCT order_id), 2) AS aov
FROM v_order_enriched
WHERE order_status = '已完成'
GROUP BY month_id
ORDER BY month_id;


-- [[SECTION: cohort_retention]]
-- 阶段2-① Cohort 同期群：注册月份为首购批次，统计注册后 30/60/90 天内
--           仍有「已完成订单」的用户占比（offset 天数 = 下单日 - 注册日，取 1~N 天）
--           complete_N 标识该批次窗口是否完整（参照快照日 2026-12-31）
WITH u0 AS (
    SELECT global_user_id,
           date(registration_date)                          AS reg,
           strftime('%Y-%m', registration_date)             AS cohort_month
    FROM "user"
),
ret AS (   -- 以用户为粒度标记三个窗口是否回访
    SELECT u0.global_user_id, u0.cohort_month,
           SUM(CASE WHEN CAST(julianday(e.order_time) - julianday(u0.reg) AS INT) BETWEEN 1 AND 30 THEN 1 ELSE 0 END) AS h30,
           SUM(CASE WHEN CAST(julianday(e.order_time) - julianday(u0.reg) AS INT) BETWEEN 1 AND 60 THEN 1 ELSE 0 END) AS h60,
           SUM(CASE WHEN CAST(julianday(e.order_time) - julianday(u0.reg) AS INT) BETWEEN 1 AND 90 THEN 1 ELSE 0 END) AS h90
    FROM u0
    LEFT JOIN v_order_enriched e
           ON u0.global_user_id = e.global_user_id
          AND e.order_status = '已完成'
    GROUP BY u0.global_user_id, u0.cohort_month
),
agg AS (
    SELECT cohort_month,
           COUNT(*)                                                AS cohort_size,
           SUM(CASE WHEN h30 > 0 THEN 1 ELSE 0 END)                 AS retained_30d,
           SUM(CASE WHEN h60 > 0 THEN 1 ELSE 0 END)                 AS retained_60d,
           SUM(CASE WHEN h90 > 0 THEN 1 ELSE 0 END)                 AS retained_90d,
           date(cohort_month || '-01', '+1 month', '-1 day')        AS cohort_month_end
    FROM ret
    GROUP BY cohort_month
)
SELECT cohort_month, cohort_size, retained_30d, retained_60d, retained_90d,
       ROUND(100.0 * retained_30d / cohort_size, 2) AS retention_30d_pct,
       ROUND(100.0 * retained_60d / cohort_size, 2) AS retention_60d_pct,
       ROUND(100.0 * retained_90d / cohort_size, 2) AS retention_90d_pct,
       CASE WHEN julianday('2026-12-31') - julianday(cohort_month_end) >= 30 THEN 1 ELSE 0 END AS complete_30d,
       CASE WHEN julianday('2026-12-31') - julianday(cohort_month_end) >= 60 THEN 1 ELSE 0 END AS complete_60d,
       CASE WHEN julianday('2026-12-31') - julianday(cohort_month_end) >= 90 THEN 1 ELSE 0 END AS complete_90d
FROM agg
ORDER BY cohort_month;


-- [[SECTION: rfm_summary]]
-- 阶段2-② RFM 分层汇总：四类用户人数、在有效消费用户中的占比、GMV 贡献占比、人均消费
WITH seg AS (
    SELECT segment,
           COUNT(*)                                   AS users,
           ROUND(SUM(m_amt), 2)                       AS gmv,
           ROUND(AVG(r_days), 1)                      AS avg_r_days,
           ROUND(AVG(f_cnt), 2)                       AS avg_f_cnt,
           ROUND(AVG(m_amt), 2)                       AS avg_m_amt
    FROM v_rfm_seg
    GROUP BY segment
)
SELECT segment, users,
       ROUND(100.0 * users / SUM(users) OVER (), 2)  AS user_pct,
       gmv,
       ROUND(100.0 * gmv / SUM(gmv) OVER (), 2)      AS gmv_pct,
       avg_r_days, avg_f_cnt, avg_m_amt
FROM seg
ORDER BY gmv DESC;


-- [[SECTION: rfm_detail]]
-- RFM 明细（用户粒度），供 EDA 与 PowerBI 用户页使用
SELECT global_user_id, r_days, f_cnt, ROUND(m_amt, 2) AS m_amt,
       r_score, f_score, m_score, segment
FROM v_rfm_seg
ORDER BY m_amt DESC;


-- [[SECTION: pareto_user]]
-- 阶段2-③ 帕累托：按 M 降序 NTILE(5)，第 1 组即头部 20% 用户，计算其 GMV 占比
WITH t AS (
    SELECT m_amt,
           NTILE(5) OVER (ORDER BY m_amt DESC, global_user_id) AS bucket,
           SUM(m_amt) OVER ()                                  AS total_gmv
    FROM v_rfm
)
SELECT COUNT(*)                              AS top_user_cnt,
       ROUND(100.0 * SUM(m_amt) / MAX(total_gmv), 2) AS top20_gmv_pct,
       ROUND(MAX(total_gmv), 2)              AS total_gmv
FROM t
WHERE bucket = 1;


-- [[SECTION: pareto_sku]]
-- 阶段2-③ 帕累托：按 SKU 有效销售额降序 NTILE(5)，头部 20% SKU 的 GMV 占比
WITH sku AS (
    SELECT global_product_id, ROUND(SUM(item_total), 2) AS sku_gmv
    FROM v_item_wide
    WHERE order_status = '已完成'
    GROUP BY global_product_id
),
t AS (
    SELECT sku_gmv,
           NTILE(5) OVER (ORDER BY sku_gmv DESC, global_product_id) AS bucket,
           SUM(sku_gmv) OVER ()                                    AS total_gmv
    FROM sku
)
SELECT COUNT(*)                                   AS top_sku_cnt,
       ROUND(100.0 * SUM(sku_gmv) / MAX(total_gmv), 2) AS top20_gmv_pct,
       ROUND(MAX(total_gmv), 2)                   AS total_gmv
FROM t
WHERE bucket = 1;


-- [[SECTION: product_label]]
-- 阶段2-④ 商品分层：以观察窗口内有效销售额为判据
--   滞销 SKU = 窗口内零成交；爆品 SKU = 动销 SKU 中 GMV 前 20%（NTILE(5) 第 1 桶，且库存为有货）
--   其余为动销 SKU
WITH s AS (   -- 商品粒度销量汇总（LEFT JOIN 保留零成交 SKU）
    SELECT p.global_product_id,
           MAX(p.category)      AS category,
           MAX(p.brand)         AS brand,
           MAX(p.price)         AS list_price,
           MAX(p.stock_status)  AS stock_status,
           COALESCE(SUM(CASE WHEN e.order_status = '已完成' THEN oi.quantity END), 0)    AS sales_qty,
           COALESCE(ROUND(SUM(CASE WHEN e.order_status = '已完成' THEN oi.item_total END), 2), 0) AS sales_gmv
    FROM product p
    LEFT JOIN order_item oi      ON p.global_product_id = oi.global_product_id
    LEFT JOIN v_order_enriched e ON oi.order_id = e.order_id
    GROUP BY p.global_product_id
),
r AS (
    SELECT *,
           NTILE(5) OVER (
               PARTITION BY CASE WHEN sales_gmv > 0 THEN 1 ELSE 0 END
               ORDER BY sales_gmv DESC, global_product_id) AS sales_bucket
    FROM s
)
SELECT global_product_id, category, brand, list_price, stock_status,
       sales_qty, sales_gmv,
       CASE WHEN sales_gmv = 0 THEN '滞销SKU'
            WHEN sales_bucket = 1 AND stock_status = '有货' THEN '爆品SKU'
            ELSE '动销SKU'
       END AS sku_label
FROM r
ORDER BY sales_gmv DESC;


-- [[SECTION: product_label_summary]]
-- 商品分层结果汇总：爆品/动销/滞销 SKU 数、占比与各自贡献 GMV
WITH s AS (
    SELECT p.global_product_id,
           COALESCE(SUM(CASE WHEN e.order_status = '已完成' THEN oi.item_total END), 0) AS sales_gmv
    FROM product p
    LEFT JOIN order_item oi      ON p.global_product_id = oi.global_product_id
    LEFT JOIN v_order_enriched e ON oi.order_id = e.order_id
    GROUP BY p.global_product_id
),
r AS (
    SELECT global_product_id, sales_gmv,
           NTILE(5) OVER (PARTITION BY CASE WHEN sales_gmv > 0 THEN 1 ELSE 0 END
                          ORDER BY sales_gmv DESC, global_product_id) AS sales_bucket
    FROM s
),
lb AS (
    SELECT CASE WHEN sales_gmv = 0 THEN '滞销SKU'
                WHEN sales_bucket = 1 THEN '爆品SKU'
                ELSE '动销SKU' END AS sku_label,
           sales_gmv
    FROM r
)
SELECT sku_label,
       COUNT(*) AS sku_cnt,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS sku_pct,
       ROUND(SUM(sales_gmv), 2) AS gmv,
       ROUND(100.0 * SUM(sales_gmv) / SUM(SUM(sales_gmv)) OVER (), 2) AS gmv_pct
FROM lb
GROUP BY sku_label
ORDER BY gmv DESC;


-- [[SECTION: category_funnel]]
-- 阶段2-④ 各一级品类 浏览→下单 去重用户转化率（基于行为宽表，同品类用户集合匹配）
WITH br AS (   -- 各品类发生浏览的去重用户
    SELECT DISTINCT category, global_user_id
    FROM v_behavior_wide WHERE behavior_type = '浏览' AND category IS NOT NULL
),
od AS (        -- 各品类发生下单的去重用户
    SELECT DISTINCT category, global_user_id
    FROM v_behavior_wide WHERE behavior_type = '下单' AND category IS NOT NULL
)
SELECT br.category,
       COUNT(DISTINCT br.global_user_id) AS browse_users,
       COUNT(DISTINCT od.global_user_id) AS order_users,
       ROUND(100.0 * COUNT(DISTINCT od.global_user_id) / COUNT(DISTINCT br.global_user_id), 2) AS browse_to_order_pct
FROM br
LEFT JOIN od ON br.category = od.category AND br.global_user_id = od.global_user_id
GROUP BY br.category
ORDER BY browse_to_order_pct DESC;


-- [[SECTION: platform_level_compare]]
-- 阶段2-⑤ 平台 × 会员等级多维对比：注册用户、有效购买用户、购买转化率、有效订单、GMV、客单价
SELECT u.platform AS platform_code,
       u.user_level,
       COUNT(DISTINCT u.global_user_id) AS register_users,
       COUNT(DISTINCT e.global_user_id) AS buyer_users,
       ROUND(100.0 * COUNT(DISTINCT e.global_user_id) / COUNT(DISTINCT u.global_user_id), 2) AS buyer_conv_pct,
       COUNT(DISTINCT e.order_id)       AS valid_orders,
       ROUND(SUM(e.total_amount), 2)    AS gmv,
       ROUND(SUM(e.total_amount) * 1.0 / NULLIF(COUNT(DISTINCT e.order_id), 0), 2) AS aov
FROM "user" u
LEFT JOIN (SELECT * FROM v_order_enriched WHERE order_status = '已完成') e
       ON u.global_user_id = e.global_user_id AND u.platform = e.platform_code
GROUP BY u.platform, u.user_level
ORDER BY u.platform, gmv DESC;
