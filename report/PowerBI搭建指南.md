# PowerBI 三页看板搭建指南

> 数据源：`output/bi/` 下 15 张 UTF-8 BOM 编码 CSV（`fct_*` 事实表 13 张 + `dim_*` 维度表 2 张），由 `code/analysis_pipeline.ipynb` 模块 24/24B/24C/24D 自动导出。
> 导入方式：PowerBI Desktop →「获取数据 → 文件夹/文本」→ 全部选中导入；编码自动识别为 UTF-8，无需转码。
> **本看板已在 Power BI Desktop 中实际搭建完成**：页面截图见 `../bi_screenshots/`（bi_01_经营总览 / bi_02_转化漏斗 / bi_03_用户商品运营），源文件 `../bi_screenshots/多平台电商经营看板.pbix`（Power BI Desktop 可直接打开，查看数据模型与全部视觉对象）。以下步骤即当时的搭建过程，可据此复现。

---

## 1. 数据表清单与字段

### 事实表（13 张）

| 文件 | 粒度 | 关键字段 |
|---|---|---|
| fct_platform_metrics.csv | 平台（含全网 ALL 行） | platform_code、platform_name、gmv、valid_orders、buyer_users、aov |
| fct_monthly_gmv.csv | 月份（24 行） | month_id（文本 yyyy-MM）、gmv、valid_orders、buyer_users、aov |
| fct_funnel.csv | 平台 × 漏斗环节（4 平台 × 4 环节） | platform_code、platform_name、stage、user_cnt、stage_conv_pct、total_conv_pct |
| fct_rfm_summary.csv | RFM 分层（4 行） | segment、users、user_pct、gmv、gmv_pct、avg_r_days、avg_f_cnt、avg_m_amt |
| fct_category_sales.csv | 一级品类（8 行） | category、gmv、valid_orders、sold_sku_cnt |
| fct_category_funnel.csv | 一级品类（8 行） | category、browse_users、order_users、browse_to_order_pct |
| fct_sku_label_summary.csv | SKU 分层（3 行） | sku_label、sku_cnt、sku_pct、gmv、gmv_pct |
| fct_cohort_retention.csv | 注册批次（24 行） | cohort_month、cohort_size、retained_30/60/90d、retention_30/60/90d_pct、complete_30/60/90d |
| fct_platform_level.csv | 平台 × 会员等级（12 行） | platform_code、user_level、register_users、buyer_users、buyer_conv_pct、valid_orders、gmv、aov |
| fct_level_metrics.csv | 会员等级（4 行） | user_level、valid_orders、buyer_users、gmv、gmv_pct、order_pct、aov |
| fct_order_status.csv | 平台 × 订单状态（20 行，含全网） | platform_code、platform_name、order_status、status_code、order_cnt、status_pct（扩展专题一，全量订单口径） |
| fct_promo_summary.csv | 平台 × 促销类型（20 行，含全网） | platform_code、platform_name、promotion_id、order_cnt、order_pct、avg_amount、avg_discount、avg_depth_pct、completed_cnt、completed_gmv、completion_pct（扩展专题二） |
| fct_category_pair.csv | 品类对（28 行） | category_a、category_b、pair_orders、support_pct、confidence_ab_pct、confidence_ba_pct、lift（扩展专题三） |

### 维度表（2 张，明细表）

| 文件 | 粒度 | 关键字段 | 用途 |
|---|---|---|---|
| dim_user_rfm.csv | 用户（1,643 行） | global_user_id、r_days、f_cnt、m_amt、r_score、f_score、m_score、segment | 用户页 RFM 明细钻取、自定义分桶 |
| dim_sku_label.csv | SKU（3,298 行） | global_product_id、category、brand、list_price、stock_status、sales_qty、sales_gmv、sku_label | 滞销 SKU 清单、爆品 TOP 榜、品类/品牌下钻 |

## 2. 数据模型关系

在「模型」视图建立以下关系（多对一，单向筛选）：

| 多端事实表.外键 | 一端 | 关系 |
|---|---|---|
| dim_user_rfm.segment | fct_rfm_summary.segment | 多对一（分层汇总↔用户明细；如不做跨表联动也可只保留两张表独立使用） |
| dim_sku_label.sku_label | fct_sku_label_summary.sku_label | 多对一 |
| dim_sku_label.category | fct_category_sales.category | 多对一 |
| dim_sku_label.category | fct_category_funnel.category | 多对一（PowerBI 同列多关系需一条置为非活动，用 `USERELATIONSHIP` 激活；或不建该条，品类页两张表分别放图即可） |
| fct_funnel.platform_code | fct_platform_metrics.platform_code | 多对一（注意 fct_funnel 含 ALL 行，平台切片时筛 platform_code ≠ ALL） |
| fct_platform_level.platform_code | fct_platform_metrics.platform_code | 多对一 |
| fct_monthly_gmv.month_id | （新建日期表）Date[Month] | 多对一 |

**建议新建日期表**：`Date = CALENDAR(DATE(2025,1,1), DATE(2026,12,31))`，加年/季度/月列，供页面 1 的年月切片器统一筛选 fct_monthly_gmv（month_id 与 Date[年-月] 关联）。

**注意事项**：
- 平台编码统一用 `platform_code`（taobao/jd/douyin），显示名用 `platform_name`；平台维度不建议物理建表，直接用 fct_platform_metrics 的两列即可。
- 漏斗表 stage 列是中文环节名（浏览/加购/下单/支付），排序可用计算列 `stage_ord = SWITCH([stage],"浏览",1,"加购",2,"下单",3,"支付",4)` 并「按列排序」。
- Cohort 2026-10 起批次窗口不完整（complete_60d/90d=0），做均值卡或解读时加视觉级筛选 complete_90d = 1。

## 3. 页面 1【经营总览】

**切片器**：Date 表的年、月；fct_platform_metrics.platform_name（多选）。

| 区域 | 可视化类型 | 数据字段/度量 |
|---|---|---|
| 顶部 5 张 KPI 卡片 | 卡片（Card） | GMV = `SUM(fct_platform_metrics[gmv])`（筛选 platform_code=ALL 或平台切片后取非 ALL 行求和）；有效订单 = SUM(valid_orders)；客单价 = GMV/有效订单；购买用户 = SUM(buyer_users)；高价值+流失预警 GMV 占比 = `CALCULATE(SUM(fct_rfm_summary[gmv_pct]), fct_rfm_summary[segment] IN {"高价值用户","流失预警用户"})` |
| 主图 | 折线图（可双轴加柱） | X：Date 月份；Y：fct_monthly_gmv[gmv] 求和、[valid_orders] 求和（次轴） |
| 右侧 | 环形图 | 图例 fct_platform_metrics.platform_name（筛 platform_code≠ALL）；值 gmv |
| 辅助（可选） | 条形图 | fct_level_metrics：user_level × gmv_pct |

## 4. 页面 2【转化漏斗分析】

**切片器**：平台（platform_name），默认不选=全网。

| 区域 | 可视化类型 | 数据字段/度量 |
|---|---|---|
| 左上 | 漏斗图 | fct_funnel（筛选 platform_name=全网 或随切片器）：stage（按 stage_ord 排序）、user_cnt；漏斗自动显示阶段转化率，也可直接用 stage_conv_pct/total_conv_pct 做卡 |
| 右上 | 折线图 | X：stage（筛 stage≠浏览）；图例：platform_name；Y：stage_conv_pct |
| 下方通栏 | 条形图 | fct_category_funnel：category × browse_to_order_pct（降序），数据标签显示百分比 |
| 辅助（可选） | 簇状柱形图 | 各环节流失人数（用下方两个度量；也可直接用 `user_cnt` 柱图人工读差） |

上表「各环节流失人数」所需度量（DAX 已按单表结构写好，尚未在 Power BI 中实测）：

```dax
上一环节用户数 = VAR cur = MAX(fct_funnel[stage_ord])
                RETURN CALCULATE(MAX(fct_funnel[user_cnt]), ALL(fct_funnel[stage]), fct_funnel[stage_ord] = cur - 1)
本环节流失人数 = MAX(fct_funnel[user_cnt]) - [上一环节用户数]   -- 浏览环节无上一环节，返回空
```

## 5. 页面 3【用户 & 商品运营】

| 区域 | 可视化类型 | 数据字段/度量 |
|---|---|---|
| 左上 | 饼图/环形图 | fct_rfm_summary：segment × users（或 gmv_pct 做第二张）；下挂明细表 dim_user_rfm（segment、r_days、f_cnt、m_amt）支持右键钻取 |
| 右上 | 矩阵（条件格式做热力图） | 行 fct_cohort_retention.cohort_month；列放 retention_30d_pct/60d_pct/90d_pct 三列；背景色按值渐变（蓝阶）；视觉筛选 complete_90d=1 时仅看完整批次 |
| 左下 | 簇状柱形图 | fct_category_sales：category × gmv（数据标签含 valid_orders） |
| 右下 | 簇状柱形图 | fct_sku_label_summary：sku_label × sku_cnt，标签带 gmv_pct |
| 底部明细 1 | 表（Table） | dim_sku_label 筛选 sku_label="滞销SKU"：global_product_id、category、brand、list_price、sales_qty、sales_gmv；可再按 sales_qty=0 筛出「从未下单 358 个」 |
| 底部明细 2 | 表 | dim_sku_label 筛选 sku_label="爆品SKU"：按 sales_gmv 降序 TOP N，即爆品榜 |

## 6. 可选：第 4 页【扩展专题监控】（附录 C/D/E 上屏）

三张扩展专题事实表彼此独立、无需建模关系，适合单独做一个书签页，**不要并入三页主看板**（口径不同：全量订单 vs 已完成订单）。

| 区域 | 可视化类型 | 数据字段/度量 |
|---|---|---|
| 左上 | 100% 堆积条形图 | fct_order_status（筛 platform_code=ALL 或加平台切片器）：轴 platform_name、图例 order_status、值 status_pct |
| 右上 | 簇状柱形图 + 折线双轴 | fct_promo_summary（筛 platform_code=ALL）：X=promotion_id，柱=completion_pct，线=avg_depth_pct；配文本卡注明「卡方 p=0.145，组间无显著差异」 |
| 左下 | 矩阵热力图 | fct_category_pair 在 PowerQuery 中透视成 8×8 矩阵（行 category_a、列 category_b、值 lift，对角线补 1），蓝阶条件格式；或直接做 category_a × lift 条形图取 TOP/BOTTOM 5 |
| 右下 | KPI 卡片 | 用 `basket_metrics.csv`（需手动导入 metrics 目录该文件）：已完成口径 UPT 2.52、件单价 1,020.82 元、跨品类订单占比 93.77% |

页面顶部建议固定一条横幅文本：「本页为字段结构观察：状态/促销/品类对均经检验无业务关联信号（详见报告附录 C/D/E），不作为真实流失率与促销效果结论」。

## 7. 验收与口径提示

- 三张页签的 KPI 与 `report/数据分析报告.md` 数字一致：GMV 569.21 万、漏斗 2,711→2,368→1,953→1,734、RFM 高价值 46.48%+流失预警 30.01%、滞销 1,255 个。
- 所有比率字段 CSV 中已乘 100 存为百分点数值（如 72.98 表示 72.98%），PowerBI 中显示格式设为「小数位 2 位 + %」时注意不要再乘 100（可直接格式化为数字加「%」后缀）。
- 敏感性对照数据（Cohort 宽松口径、严格路径漏斗、LTV 两种分母）在 `output/metrics/` 下，属报告附录内容，不进三页主看板；如需上屏建议单独建「口径对照」书签页，避免与主口径并列误读。
- 第 4 页扩展专题（订单状态/促销/篮子）为**全量订单口径**（10,996 单），与主看板「已完成」口径（2,216 单）不同源，页面间不要跨页筛选联动；其结论是"字段无信号"的结构观察，图表仅作字段健康度监控演示。
