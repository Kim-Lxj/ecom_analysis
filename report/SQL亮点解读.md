# SQL 亮点解读 —— 多平台电商经营分析

> 用途：SQL 实现说明。本文档从 `code/data_process.sql`（609 行 / 22 个 SECTION）中精选 5 段最能体现 SQL 水平的代码，每段给出**业务问题 → 代码 → 逐行讲解 → 真实结果数字 → 一句话总结**，便于评审快速定位实现细节。

---

## 0. 先记住这几个「地基」事实（30 秒速览）

- 数据源：9 张业务表（订单、订单明细、用户、商品、用户行为、平台、订单状态、支付/配送字典），SQLite 内存库，执行 `code/data_process.sql` 产出 `output/metrics/` 下 **21 张指标结果表**（该目录共 54 张 CSV，其余为 pandas 生成的 EDA、增强口径与扩展专题结果）。
- 核心口径：有效订单 = 订单状态为「已完成」；GMV = 有效订单金额之和。
- 地基工程：脚本开头用 5 个**临时视图**（订单宽表 / 订单明细宽表 / 行为宽表 + RFM 打分视图 / RFM 分层视图）统一了所有指标的关联口径，避免 9 张业务表反复 JOIN 出错。
- 结果（全网核心指标）：GMV **569.2 万**、有效订单 **2,216 单**、购买用户 **1,643 人**、客单价 **2,568.63 元**；分平台：淘宝 232.3 万 / 抖音 175.3 万 / 京东 161.6 万。

```sql
-- 订单宽表视图（节选）：5 张字典/维度表一次关联，后续所有指标复用
CREATE TEMP VIEW IF NOT EXISTS v_order_enriched AS
WITH ship_dict AS (
    SELECT name, MIN(code) AS code FROM shipping_method GROUP BY name  -- 字典去重防 JOIN 翻倍
)
SELECT o.order_id, o.platform AS platform_code, pl.name AS platform_name,
       o.order_status, os.code AS status_code, o.total_amount, ...
FROM "order" o
LEFT JOIN platform pl       ON o.platform = pl.code
LEFT JOIN order_status os   ON o.order_status = os.name
LEFT JOIN "user" u          ON o.global_user_id = u.global_user_id;
```

---

## 1. 亮点一：RFM 用户分层 —— NTILE(4) 窗口打分 + CASE 分层规则

**业务问题**：1,643 个购买用户怎么分层运营？谁值得重点维护、谁在流失边缘？

**代码位置**：`data_process.sql` L125-L156（v_rfm 打分视图 + v_rfm_seg 分层视图）+ L443-L463（rfm_summary 汇总段），输出 `rfm_summary.csv`

```sql
-- ① 打分：R/F/M 三个维度各用 NTILE(4) 打成 1~4 分
--    NTILE(4) 把排好序的用户依次分进 4 个桶：桶号 1~4 就是 1~4 分
--    注意方向：R（越近越好）按天数降序排，天数最大的得 1 分；F/M 越优越排在后面得 4 分
CREATE TEMP VIEW IF NOT EXISTS v_rfm AS
WITH base AS (
    SELECT global_user_id,
           CAST(julianday('2026-12-31') - julianday(MAX(order_time)) AS INT) AS r_days,
           COUNT(DISTINCT order_id)  AS f_cnt,
           ROUND(SUM(total_amount), 2) AS m_amt
    FROM v_order_enriched WHERE order_status = '已完成'
    GROUP BY global_user_id
)
SELECT global_user_id, r_days, f_cnt, m_amt,
       NTILE(4) OVER (ORDER BY r_days DESC, global_user_id)          AS r_score,
       NTILE(4) OVER (ORDER BY f_cnt ASC, m_amt ASC, global_user_id) AS f_score,
       NTILE(4) OVER (ORDER BY m_amt ASC, f_cnt ASC, global_user_id) AS m_score
FROM base;

-- ② 分层：规则互斥且穷尽（每个用户恰好归入一类）
SELECT global_user_id, ...,
    CASE WHEN r_score >= 3 AND f_score >= 3 AND m_score >= 3 THEN '高价值用户'
         WHEN r_score <= 2 AND (f_score >= 3 OR m_score >= 3)      THEN '流失预警用户'
         WHEN r_score >= 3                                          THEN '潜力用户'
         ELSE '低价值用户' END AS segment
FROM v_rfm;

-- ③ 汇总（节选）：人数占比 + GMV 贡献占比（窗口求和）
SELECT segment, users,
       ROUND(100.0 * users / SUM(users) OVER (), 2) AS user_pct,
       ROUND(100.0 * gmv   / SUM(gmv)   OVER (), 2) AS gmv_pct
FROM seg ORDER BY gmv DESC;
```

**真实结果**：

| 分层 | 人数 | 占比 | GMV 贡献 | GMV 占比 | 人均消费 |
|---|---|---|---|---|---|
| 高价值用户 | 434 | 26.42% | 264.6 万 | **46.48%** | 6,096 元 |
| 流失预警用户 | 380 | 23.13% | 170.8 万 | 30.01% | 4,495 元 |
| 低价值用户 | 442 | 26.90% | 69.6 万 | 12.23% | 1,575 元 |
| 潜力用户 | 387 | 23.55% | 64.2 万 | 11.28% | 1,658.5 元 |

**一句话总结**：用 NTILE(4) 对 R/F/M 三个维度窗口打分，再用互斥 CASE 规则把用户分成四类——结论是 **26% 的高价值用户贡献了 46% 的 GMV，且流失预警用户占 23%、贡献 30% 的 GMV，是挽回优先级最高的群体**。

**可被追问的点**（提前准备）：
- 为什么并列时要加 `global_user_id` 兜底排序？→ 保证结果可复现，可答"确定性排序"。
- 为什么 R 要降序、F/M 要升序？→ NTILE 按 ORDER BY 顺序分桶，想让"越优的拿 4 分"，就把最差排最前、最优排最后。

---

## 2. 亮点二：分平台转化漏斗 —— LAG + FIRST_VALUE 窗口函数

**业务问题**：浏览→加购→下单→支付，每个平台哪一步流失最严重？

**代码位置**：`data_process.sql` L333-L356，输出 `funnel_platform.csv`

```sql
WITH f AS (
    SELECT platform AS platform_code, platform_name, behavior_type AS stage,
           COUNT(DISTINCT global_user_id) AS user_cnt
    FROM v_behavior_wide
    WHERE behavior_type IN ('浏览', '加购', '下单', '支付')
    GROUP BY platform, platform_name, behavior_type
),
t AS (
    SELECT *, CASE stage WHEN '浏览' THEN 1 WHEN '加购' THEN 2 WHEN '下单' THEN 3 ELSE 4 END AS ord
    FROM f
)
SELECT platform_code, platform_name, stage, user_cnt,
       -- 相邻环节转化率：上一环节人数用 LAG 取
       ROUND(100.0 * user_cnt / NULLIF(LAG(user_cnt) OVER (PARTITION BY platform_code ORDER BY ord), 0), 2) AS stage_conv_pct,
       -- 相对首环节累计转化率：首环节人数用 FIRST_VALUE + 全窗口范围取
       ROUND(100.0 * user_cnt / FIRST_VALUE(user_cnt) OVER (PARTITION BY platform_code ORDER BY ord
                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING), 2) AS total_conv_pct
FROM t ORDER BY platform_code, ord;
```

**真实结果**：

| 平台 | 浏览 | 加购 | 下单 | 支付 | 浏览→支付总转化 |
|---|---|---|---|---|---|
| 京东 | 742 | 703（94.74%） | 661（94.03%） | 617（93.34%） | **83.15%** |
| 淘宝 | 845 | 747（88.40%） | 622（83.27%） | 538（86.50%） | 63.67% |
| 抖音 | 1,124 | 918（81.67%） | 670（72.98%） | 579（86.42%） | 51.51% |

**一句话总结**：用 LAG() 算相邻环节转化率、FIRST_VALUE() 算相对首环节的累计转化率，并用 PARTITION BY 实现分平台计算——结论是 **抖音流量最大但转化链路最短（51.5%），最大流失发生在"加购→下单"（-8.7pp）；京东用户少但转化极稳（83.2%）**，运营策略应区别对待。

**可被追问的点**：
- `NULLIF(x, 0)` 为什么？→ 首环节 LAG 为空/除零保护，避免报错。
- 为什么加 `ord` 排序号而不直接按 stage 字母序？→ 保证漏斗按业务顺序（浏览→加购→下单→支付）而非字母序。

---

## 3. 亮点三：Cohort 同期群留存 —— 时间窗口 + SUM(CASE) 回访标记

**业务问题**：每月注册的新用户，30/60/90 天后还有多少人在继续下单？哪个月的拉新质量最好？

**代码位置**：`data_process.sql` L401-L442，输出 `cohort_retention.csv`

```sql
WITH u0 AS (
    SELECT global_user_id, date(registration_date) AS reg,
           strftime('%Y-%m', registration_date) AS cohort_month
    FROM "user"
),
ret AS (  -- 用户粒度：三个窗口内是否有回访（LEFT JOIN 保留没回来的用户）
    SELECT u0.global_user_id, u0.cohort_month,
           SUM(CASE WHEN CAST(julianday(e.order_time) - julianday(u0.reg) AS INT) BETWEEN 1 AND 30 THEN 1 ELSE 0 END) AS h30,
           SUM(CASE WHEN CAST(julianday(e.order_time) - julianday(u0.reg) AS INT) BETWEEN 1 AND 60 THEN 1 ELSE 0 END) AS h60,
           SUM(CASE WHEN CAST(julianday(e.order_time) - julianday(u0.reg) AS INT) BETWEEN 1 AND 90 THEN 1 ELSE 0 END) AS h90
    FROM u0
    LEFT JOIN v_order_enriched e ON u0.global_user_id = e.global_user_id AND e.order_status = '已完成'
    GROUP BY u0.global_user_id, u0.cohort_month
)
SELECT cohort_month, COUNT(*) AS cohort_size,
       ROUND(100.0 * SUM(CASE WHEN h30 > 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS retention_30d_pct,
       -- ... 60d / 90d 同理
       CASE WHEN julianday('2026-12-31') - julianday(cohort_month_end) >= 90 THEN 1 ELSE 0 END AS complete_90d
FROM ret GROUP BY cohort_month ORDER BY cohort_month;
```

**真实结果**（部分批次）：

| 注册批次 | 人数 | 30 日留存 | 60 日留存 | 90 日留存 |
|---|---|---|---|---|
| 2025-01 | 198 | 0.51% | 3.03% | 5.05% |
| 2026-04 | 243 | 2.88% | 5.76% | 7.00% |
| **2026-08** | **231** | **3.90%** | **6.06%** | **7.36%** |

**一句话总结**：以注册月份为同期群，用 julianday 算下单日距注册日的天数、按 30/60/90 天窗口用 SUM(CASE) 标记回访，并加 complete_N 字段标记窗口是否完整（避免未满 90 天的批次被误判）——2026-08 批次是 21 个完整批次里 30/60/90 天留存最高的一批（3.90% / 6.06% / 7.36%），但 **90 天留存序列并不单调上升（5.05 → … → 7.36 → 3.64）**，整体没有随批次改善的趋势，因此不能推断「拉新或产品改进有效」；结论只取「复购极弱」这一方向，且受 50.01% 订单早于注册日期的时序异常影响，报告 2.1 节对该结论标为中置信度。

**可被追问的点**：
- 为什么用 LEFT JOIN？→ 没回来的用户也要保留，否则留存率被高估。
- `complete_90d` 有什么用？→ 快照日 2026-12-31，最近三个月批次窗口未满，直接比 90 日留存会不公平，完整标记用于排除。

---

## 4. 亮点四：帕累托 80/20 头部贡献 —— CUME_DIST 累计分布

**业务问题**：GMV 是不是集中在少数头部用户 / 头部 SKU 上？"二八定律"成不成立？

**代码位置**：`data_process.sql` L234-L273，输出 `pareto_cumulative.csv`

```sql
WITH u AS (
    SELECT m_amt AS amount, CUME_DIST() OVER (ORDER BY m_amt DESC, global_user_id) AS cd
    FROM v_rfm
),
cuts(cut_pct) AS (VALUES (10),(20),(30),(40),(50),(60),(70),(80),(90),(100))  -- 造 10 个分位节点
SELECT '用户' AS scope, cut_pct,
       (SELECT COUNT(*) FROM u WHERE u.cd <= cut_pct / 100.0)                 AS entity_cnt,
       ROUND(100.0 * (SELECT SUM(amount) FROM u WHERE u.cd <= cut_pct / 100.0)
             / (SELECT SUM(amount) FROM u), 2)                                 AS gmv_pct_cum
FROM cuts
UNION ALL
-- ... SKU 口径同理（按 SKU 销售额排序）
ORDER BY scope, cut_pct;
```

**真实结果**（节选）：

| 分位 | 用户口径：累计人数占比 | 用户口径：GMV 累计占比 | SKU 口径：GMV 累计占比 |
|---|---|---|---|
| 头部 10% | 9.98% | 28.57% | 29.03% |
| **头部 20%** | **19.96%** | **43.32%** | **47.55%** |
| 头部 50% | 49.97% | 77.11% | 80.96% |

**一句话总结**：用 CUME_DIST() 算名次分位、造 10 个分位节点做累计贡献曲线——结论是 **约 20% 的用户贡献 43% 的 GMV、20% 的 SKU 贡献 48% 的 GMV、50% 的 SKU 贡献 81% 的 GMV，头部集中度低于经典 80/20**；商品侧长尾明显：1,255 个零有效成交 SKU 中有 358 个全窗口从未被下单，可优先进入清仓/下架评估（报告 2.3、2.4 节）。

**可被追问的点**：
- `CUME_DIST` 和 `NTILE` 的区别？→ CUME_DIST 是名次分位（<= 某名次的占比），NTILE 是等深分桶；两者人数可能差 1（1,643 用户下头部 20% 是 328 vs 329），代码注释里专门写了这一点，体现严谨。

---

## 5. 亮点五：爆品 / 滞销 SKU 分层 —— NTILE + 窗口总和

**业务问题**：几千个 SKU 里哪些是爆品、哪些是滞销？爆品贡献了多少 GMV？

**代码位置**：`data_process.sql` L487-L507（pareto_sku 头部 20% 占比）+ L508-L541（product_label 分层明细），输出 `pareto_sku.csv` / `product_label.csv`

```sql
-- ① 头部 20% SKU 贡献占比
WITH sku AS (
    SELECT global_product_id, ROUND(SUM(item_total), 2) AS sku_gmv
    FROM v_item_wide WHERE order_status = '已完成'
    GROUP BY global_product_id
),
t AS (
    SELECT sku_gmv,
           NTILE(5) OVER (ORDER BY sku_gmv DESC, global_product_id) AS bucket,  -- 第 1 桶 = 头部 20%
           SUM(sku_gmv) OVER () AS total_gmv
    FROM sku
)
SELECT COUNT(*) AS top_sku_cnt, ROUND(100.0 * SUM(sku_gmv) / MAX(total_gmv), 2) AS top20_gmv_pct
FROM t WHERE bucket = 1;

-- ② SKU 分层：零成交=滞销；动销中头部 20% 且有货=爆品
WITH s AS (
    SELECT p.global_product_id, MAX(p.stock_status) AS stock_status,
           COALESCE(SUM(CASE WHEN e.order_status = '已完成' THEN oi.item_total END), 0) AS sales_gmv
    FROM product p
    LEFT JOIN order_item oi      ON p.global_product_id = oi.global_product_id
    LEFT JOIN v_order_enriched e ON oi.order_id = e.order_id
    GROUP BY p.global_product_id
),
r AS (
    SELECT *, NTILE(5) OVER (PARTITION BY CASE WHEN sales_gmv > 0 THEN 1 ELSE 0 END
                              ORDER BY sales_gmv DESC, global_product_id) AS sales_bucket
    FROM s
)
SELECT ..., CASE WHEN sales_gmv = 0 THEN '滞销SKU'
                 WHEN sales_bucket = 1 AND stock_status = '有货' THEN '爆品SKU'
                 ELSE '动销SKU' END AS sku_label
FROM r ORDER BY sales_gmv DESC;
```

**真实结果**：头部 **409 个 SKU（20%）贡献 47.63% 的 GMV**（全盘总 GMV 569.2 万）；动销 1,634 / 滞销 1,255 / 爆品 409 个 SKU。

**一句话总结**：用 NTILE(5) 把 SKU 按销售额等深分桶取头部 20%，LEFT JOIN + COALESCE 保留零成交 SKU 识别滞销，再用 PARTITION BY 在动销/滞销两组内分别分桶——结论是 **爆品仅 409 个就扛起近一半 GMV，滞销 1,255 个 SKU 占用货架和库存，是选品和库存优化的直接抓手**。

**可被追问的点**：
- 为什么 `PARTITION BY CASE WHEN sales_gmv > 0`？→ 让动销和滞销各自独立分桶，避免滞销把爆品挤出不公平。
- 为什么滞销用 LEFT JOIN 而不是直接查有订单的？→ 零成交的 SKU 在订单表里根本没有记录，必须从商品表出发 LEFT JOIN。

---

## 6. 三技能闭环（三件工具怎么串成一个故事）

1. **SQL（取数与分析）**：`code/data_process.sql` 一条脚本产出 21 张结果表（漏斗 / RFM / Cohort / 帕累托 / 商品分层……），全部落盘到 `output/metrics/`。
2. **Power BI（可视化）**：导入 15 张结果 CSV 建模，搭三页看板——经营总览（KPI + 月度趋势 + 平台结构）、转化漏斗（分平台转化率）、用户与商品运营（RFM 环形 + Cohort 矩阵 + 品类/SKU 分层）。
3. **Excel（第三方复算）**：`cross_check.xlsx` + `excel_cross_check.md` 在 Excel 内用旧版兼容公式（SUMIFS / COUNTIFS / VLOOKUP / SUMPRODUCT + 辅助列）独立重建 SQL 与 pandas 已算过的 9 项核心指标，计算值缓存后与两方逐项一致，形成 SQL ↔ pandas ↔ Excel 三方口径闭环。

> 一句话故事线：「我用 SQL 把 9 张原始表清洗、建模，产出 21 张结果表、覆盖 31 个指标口径；Power BI 把结论做成三页看板并留下 .pbix 源文件；Excel 独立复算核心指标做三方对账——三样工具是一个可复现的闭环。」

---

## 7. 延伸追问与速答

| 追问 | 速答 |
|---|---|
| 为什么用窗口函数而不是 GROUP BY 算转化率？ | 窗口函数能在不丢失明细行的前提下同时拿到"本环节人数"和"上一环节人数"，一个查询出结果，避免多次自连接 |
| 除零怎么处理？ | NULLIF(x, 0)，分母为 0 返回 NULL，不报错 |
| 数据量很大怎么办？ | 先建宽表视图统一口径（本项目做法）；必要时分区、索引、只取需要的列 |
| 怎么保证结果可信？ | ① 口径在脚本开头注释写死；② 外键/业务规则/金额一致性三套 DQ 复核段；③ 与 Python 双算交叉验证（见 excel_cross_check.md） |
| RFM 为什么用 4 分制？ | 等深分桶（NTILE(4)）每桶人数均匀，避免阈值主观；也便于 CASE 规则组合 |
