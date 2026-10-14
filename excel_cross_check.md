# SQL - Python - Excel 三重指标交叉校验手册（Excel 复算逻辑）

> 目的：用 Excel 独立复算核心指标，与 `code/data_process.sql`（SQL 腿）、`analysis_pipeline.ipynb` 中的 pandas 计算（Python 腿，结果见 `output/metrics/cross_check_sql_python.csv`）三方对账。
> 适用版本：Excel 365 / Excel 2021（XLOOKUP、FILTER、UNIQUE 为 365 动态数组函数；旧版本替代写法在文末给出）。
> 对账原则：**三个工具的数据口径必须完全一致**——有效订单 = `order_status="已完成"`，金额取 `total_amount`，去重列用各自的「非重复计数」。
> 逻辑回归/AUC 核对记录：本手册仅涉及交易、漏斗、品类、RFM 等业务指标的 Excel 复算，**全文不涉及逻辑回归与 AUC 表述**（2026-10-04 逐行核对），无需随模型口径修订。
> **交付物**：根目录 `cross_check.xlsx` 已按本手册重建（为保证可重算，采用 §5 的旧版兼容写法：SUMIFS / COUNTIFS / VLOOKUP / SUMPRODUCT + 辅助列，不使用 XLOOKUP 与动态数组），工作簿内公式由 Excel 全量重算并缓存结果，三方对账表见 §4。§1~§3 的 Excel 365 写法与 §5 的旧版替代写法均保留，供读者独立复核。

---

## 0. 工作簿准备（一次性）

1. 新建 `cross_check.xlsx`，用「数据 → 获取数据 → 自文本/CSV」依次导入 `data/` 下 9 张业务 CSV（**不要导入 auth_user.csv**）。CSV 为 UTF-8 编码，导入时点「转换数据」把编码确认为 UTF-8（9 个文件均为标准表头，无需拆分）。
2. 导入后 Power Query 中选择「关闭并加载到 → 仅创建连接 → 勾选‘将此数据添加到数据模型’」。再对 `order`、`order_item`、`product`、`user`、`user_behavior` 五张表额外「加载到表」，它们在公式中要用结构化引用。
3. 每张表自动成为「表（Table）」，表名与文件名一致：`order`、`order_item`、`product`、`user`、`user_behavior`、`platform`、`order_status`、`payment_method`、`shipping_method`。
4. 数据模型中建立关系：
   - `order_item.order_id` → `order.order_id`（多对一）
   - `order_item.global_product_id` → `product.global_product_id`（多对一）
   - `order.global_user_id` → `user.global_user_id`（多对一）
   - `user_behavior.global_user_id` → `user.global_user_id`；`user_behavior.global_product_id` → `product.global_product_id`

---

## 1. XLOOKUP：多表关联样本复核（对应 SQL 的 4 张字典 LEFT JOIN）

新建 Sheet「关联复核」，从 `order` 表抽取 100 个订单样本（A 列起粘贴：order_id、platform、order_status、payment_method、shipping_method），然后：

| 目标列 | 单元格 | 公式 | 期望值说明 |
|---|---|---|---|
| 平台中文名 | G2 | `=XLOOKUP([@platform],platform[code],platform[name],"未命中")` | taobao→淘宝、jd→京东、douyin→抖音 |
| 状态编码 | H2 | `=XLOOKUP([@order_status],order_status[name],order_status[code],"未命中")` | 已完成→completed、待付款→pending |
| 支付方式编码 | I2 | `=XLOOKUP([@payment_method],payment_method[name],payment_method[code],"未命中")` | 微信支付→wechat |
| 配送方式编码 | J2 | `=XLOOKUP([@shipping_method],shipping_method[name],shipping_method[code],"未命中")` | 快递配送→express；同城配送因 local/same_city 重名，XLOOKUP 返回首个匹配，与 SQL「MIN(code)」去重口径等价 |

**注意（与 SQL 同一坑点）**：`shipping_method` 中 local、same_city 两个 code 同名「同城配送」，XLOOKUP 永远只返回首个命中，天然不翻倍；如果误用普通 VLOOKUP 辅助列做一对多展开会重复金额。

再抽 100 行 `order_item` 样本，校验明细到主数据的关联：

| 目标列 | 公式 | 用途 |
|---|---|---|
| 商品品类 | `=XLOOKUP([@global_product_id],product[global_product_id],product[category],"未命中")` | 品类销售透视的前置校验 |
| 订单状态 | `=XLOOKUP([@order_id],order[order_id],order[order_status],"未命中")` | 给明细补「是否已完成」标记 |
| 关联校验 | `=IF(OR(G2="未命中",H2="未命中",…),1,0)` 向下求和 | **必须为 0**，与 SQL 外键/字典校验结果一致（本数据实际全部命中，非法编码 0 条） |

---

## 2. SUMIFS / COUNTIFS：核心指标复算（对应 SQL 的 `core_metrics` 分段）

新建 Sheet「指标复算」，按下列公式逐格录入，B 列为 Excel 结果，C 列已预填 SQL/Python 结果用于对账：

### 2.1 全网 GMV、有效订单量、客单价

| 指标（A列） | Excel 公式（B列） | SQL/Python 基准值（C列） |
|---|---|---|
| 全网 GMV（元） | `=SUMIFS(order[total_amount],order[order_status],"已完成")` | 5,692,092.13 |
| 有效订单量 | `=COUNTIFS(order[order_status],"已完成")` | 2,216 |
| 有效购买用户数（去重） | `=COUNTA(UNIQUE(FILTER(order[global_user_id],order[order_status]="已完成")))` | 1,643 |
| 客单价（元） | `=B2/B3` | 2,568.63 |

> COUNTIFS 只能计数订单行，去重用户必须用动态数组 `UNIQUE+FILTER`；旧版 Excel 见文末替代方案。

### 2.2 分平台 GMV（对应 SQL `core_metrics` 三行）

| 平台 | GMV 公式 | 基准值 | 订单量公式（COUNTIFS） | 基准值 |
|---|---|---:|---|---:|
| 淘宝 | `=SUMIFS(order[total_amount],order[order_status],"已完成",order[platform],"taobao")` | 2,322,985.63 | `=COUNTIFS(order[order_status],"已完成",order[platform],"taobao")` | 912 |
| 抖音 | 同上换 `"douyin"` | 1,752,679.64 | 同换 douyin | 673 |
| 京东 | 同上换 `"jd"` | 1,616,426.86 | 同换 jd | 631 |

分平台去重购买用户：`=COUNTA(UNIQUE(FILTER(order[global_user_id],(order[order_status]="已完成")*(order[platform]="taobao"))))` → 630（抖音 569、京东 444）。

自检：`=B6+B7+B8` 必须等于 B2（5,692,092.13），差额 0 才算通过。

### 2.3 漏斗去重用户数与转化率（对应 SQL `funnel_overall`）

| 环节 | 去重用户数公式 | 基准值 | 环节转化率公式 | 基准值 |
|---|---|---:|---|---:|
| 浏览 | `=COUNTA(UNIQUE(FILTER(user_behavior[global_user_id],user_behavior[behavior_type]="浏览")))` | 2,711 | — | — |
| 加购 | 同换 `"加购"` | 2,368 | `=C12/C11` | 87.35% |
| 下单 | 同换 `"下单"` | 1,953 | `=C13/C12` | 82.47% |
| 支付 | 同换 `"支付"` | 1,734 | `=C14/C13` | 88.79% |
| 浏览→支付累计 | — | — | `=C14/C11` | 63.96% |

分平台漏斗在 FILTER 条件中再加一项 `*(user_behavior[platform]="douyin")`，期望：抖音 1124/918/670/579（72.98% 为加购→下单），京东 742/703/661/617，淘宝 845/747/622/538。

### 2.4 品类 GMV（跨表条件求和的 Excel 写法）

SUMIFS 不能直接跨表，先用 XLOOKUP 给 `order_item` 加两列辅助列，再条件求和：
- 辅助列 1（订单状态）：`=XLOOKUP([@order_id],order[order_id],order[order_status])`
- 辅助列 2（品类）：`=XLOOKUP([@global_product_id],product[global_product_id],product[category])`

| 指标 | 公式 | 基准值 |
|---|---|---:|
| 食品饮料 GMV | `=SUMIFS(order_item[item_total],order_item[辅助列1],"已完成",order_item[辅助列2],"食品饮料")` | 777,447.61 |
| 美妆个护 GMV | 同换「美妆个护」 | 644,824.16 |

### 2.5 明细勾稽复核

在 `order_item` 加辅助列 `=[@quantity]*[@unit_price]-[@item_total]`，对该列 `=SUMPRODUCT(--(ABS(辅助列)>0.02))`，期望 **0**（27,523 行全部相等，与 SQL `dq_item` 一致）。订单级再用 `SUMIF` 按 order_id 汇总明细，与 `order.total_amount` 逐单 XLOOKUP 比对，期望差异列全部为 0（10,996/10,996 恒等）。

---

## 3. 数据透视表：汇总口径复算（对应 SQL 各 GROUP BY 分段）

| 透视表 | 行/筛选/值字段 | 关键设置 | 期望结果 |
|---|---|---|---|
| 分平台经营 | 行：platform；筛选：order_status=已完成；值：total_amount 求和、order_id **非重复计数**、global_user_id **非重复计数** | 需基于「数据模型」建透视表，值字段设置里才有「非重复计数」 | GMV 2,322,985.63 / 1,752,679.64 / 1,616,426.86；订单 912/673/631；用户 630/569/444 |
| 漏斗透视 | 数据源 user_behavior；行：platform、behavior_type；筛选：behavior_type∈{浏览,加购,下单,支付}；值：global_user_id 非重复计数 | 透视表旁加一列 `=本环节/上一环节` 算转化率 | 全网 2711/2368/1953/1734；抖音加购→下单 72.98% |
| 品类销售透视 | 数据模型中用 order_item；行：product(category)；筛选：order(order_status)=已完成；值：item_total 求和、order_id 非重复计数 | 关系链 order_item→order、order_item→product 已在第 0 步建好 | 食品饮料 777,447.61 居首，美妆个护 644,824.16 垫底 |
| 会员等级透视 | 行：user_level；值：total_amount 求和、order_id 非重复计数 | 同上筛选已完成 | 钻石 27.60% > 普通 25.50% > 银卡 24.11% > 金卡 22.79% |
| RFM 分层透视 | 直接导入 `output/bi/fct_rfm_summary.csv` 建透视 | 行：segment；值：users、gmv 求和并加「占总和百分比」值显示方式 | 高价值 434 人/46.48%，流失预警 380 人/30.01% |
| 月度趋势透视 | 行：order_time（组合 → 按年、月分组）；筛选：已完成；值：total_amount 求和 | 也可用 Power Query 加一列 `=TEXT([order_time],"yyyy-mm")` | 峰 2026-10=277,914.57；谷 2026-02=179,271.64 |

透视表拖完后，与 SQL 导出的 `output/bi/` 聚合 CSV 并排粘贴做差：`=Excel值-SQL值`，全 0 即通过。

---

## 4. 三方对账结论表（Excel 腿已按本手册重建并重算，结果已填列）

| 指标 | SQL 结果 | Python 结果 | Excel 结果（cross_check.xlsx 缓存值） | 三方是否一致 |
|---|---:|---:|---:|---|
| 全网 GMV | 5,692,092.13 | 5,692,092.13 | 5,692,092.13 | 一致 |
| 有效订单量 | 2,216 | 2,216 | 2,216 | 一致 |
| 有效购买用户数 | 1,643 | 1,643 | 1,643 | 一致 |
| 客单价 | 2,568.63 | 2,568.63 | 2,568.63 | 一致 |
| 浏览/加购/下单/支付用户 | 2711/2368/1953/1734 | 同左 | 2711/2368/1953/1734 | 一致 |
| 淘宝 GMV | 2,322,985.63 | 2,322,985.63 | 2,322,985.63 | 一致 |
| 抖音 GMV | 1,752,679.64 | 1,752,679.64 | 1,752,679.64 | 一致 |
| 京东 GMV | 1,616,426.86 | 1,616,426.86 | 1,616,426.86 | 一致 |
| 食品饮料 GMV | 777,447.61 | 777,447.61 | 777,447.61 | 一致 |
| 明细勾稽差异行数 | 0 | 0 | 0 | 一致 |

> Python 腿由流水线自动跑完并落盘 `output/metrics/cross_check_sql_python.csv`，9 项全部为「一致」（§4 对账表在该 9 项之外另加 1 项「明细勾稽差异行数」作金额一致性抽查，故表内共 10 行）；Excel 腿已按本手册（旧版兼容写法）在同一工作簿内重建并重算，缓存值见上表，与 SQL / pandas 逐项一致。三方任一不一致时，先查口径（是否筛了「已完成」、是否去重、金额列是否选错），再查关联（shipping_method 重名、外键未命中），禁止直接改数对齐。

---

## 5. 旧版 Excel 替代写法（无 XLOOKUP / 动态数组时）

- XLOOKUP → `=IFERROR(VLOOKUP([@platform],platform[[code]:[name]],2,FALSE),"未命中")`（查找列须在区域最左；按 name 反查 code 时用 INDEX+MATCH：`=INDEX(order_status[code],MATCH([@order_status],order_status[name],0))`）。
- 去重用户数 → 辅助列法：在 order 表加 `=IF(COUNTIFS($E$2:E2,E2,$H$2:H2,"已完成")=1,1,0)` 标记每个已完成用户首次出现，再 `=SUMIFS(标记列,状态列,"已完成")`，等价非重复计数。
- 多条件求和老函数 → `=SUMPRODUCT((order[order_status]="已完成")*(order[platform]="taobao")*order[total_amount])`，结果与 SUMIFS 相同。
