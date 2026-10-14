# -*- coding: utf-8 -*-
"""
多平台电商存量经营分析 · 命令行自动化流水线
================================================
作用：与 code/analysis_pipeline.ipynb 完全等价的无界面执行入口。
实现方式：逐格读取 notebook 中的代码单元（code cell），在同一命名空间内
         按顺序 exec，因此 SQL 分段、指标口径、图表代码与 Notebook 零分叉，
         不会出现「两套实现数字对不上」的问题。

用法：
    python code/pipeline.py
    （在项目根目录执行；脚本会自行把工作目录切到项目根，亦可在 code/ 下执行）

产出：
    output/metrics/  全部 SQL 分段、EDA、增强口径、口径衔接/时段/同质性/复购间隔/累计曲线、交叉校验 CSV
    output/bi/       15 张 PowerBI 聚合 CSV
    figures/         14 张分析图 PNG（fig01~fig08、fig12~fig17）
    bi_screenshots/  Power BI 实物看板（3 张页面截图 + .pbix；手工产物，不随流水线覆盖）
注意：report/ 下的 Markdown 结论文档不随脚本覆盖（文档为人工维护交付物）。
"""

import os
import sys
from pathlib import Path

# ---- 1. 无界面绘图后端：必须在 import matplotlib.pyplot 之前设置 ----
os.environ.setdefault("MPLBACKEND", "Agg")

# ---- 2. 定位项目根目录（本文件位于 <root>/code/ 下），并切换 cwd，
#         使 notebook 单元中的 Path.cwd() 自适应逻辑无论在哪运行都指向根目录 ----
PROJECT_ROOT = Path(__file__).resolve().parent.parent
os.chdir(PROJECT_ROOT)
sys.path.insert(0, str(PROJECT_ROOT / "code"))

import pandas as pd
import nbformat

NB_PATH = PROJECT_ROOT / "code" / "analysis_pipeline.ipynb"


def _display_shim(*objs, **kwargs):
    """模拟 IPython display()：DataFrame 以文本形式打印，其余直接 print。

    notebook 部分单元用 display(df) 展示中间表，命令行环境没有 IPython，
    注入同名函数保证这些单元不报错且输出可见。
    """
    for obj in objs:
        if isinstance(obj, pd.DataFrame):
            # 长表只预览前 20 行，避免命令行被刷屏；完整结果均已落盘 CSV
            with pd.option_context("display.max_rows", 20,
                                   "display.width", 200,
                                   "display.max_columns", 40):
                print(obj)
        else:
            print(obj)


def _heading_before(cells: list, idx: int) -> str:
    """取代码单元前面最近的一个 markdown 单元的首个二级标题，作为进度日志。"""
    for j in range(idx - 1, -1, -1):
        c = cells[j]
        if c.cell_type == "markdown":
            for line in c.source.splitlines():
                line = line.strip()
                if line.startswith("#"):
                    return line.lstrip("# ").strip()
            return "(代码单元)"
    return "(代码单元)"


def main() -> None:
    if not NB_PATH.exists():
        raise FileNotFoundError(f"未找到 notebook：{NB_PATH}")

    nb = nbformat.read(NB_PATH, as_version=4)

    # 共享命名空间：所有代码单元顺序执行、变量互相可见，与 Jupyter 行为一致
    ns: dict = {"__name__": "__main__", "display": _display_shim}

    code_idx = 0
    for i, cell in enumerate(nb.cells):
        if cell.cell_type != "code":
            continue
        code_idx += 1
        title = _heading_before(nb.cells, i)
        print(f"\n[pipeline {code_idx:02d}] {title}")
        try:
            exec(compile(cell.source, f"<notebook-cell-{code_idx}>", "exec"), ns)
        except Exception as exc:  # 明确报错位置，便于定位到 notebook 模块
            print(f"!! 单元 {code_idx}（{title}）执行失败：{type(exc).__name__}: {exc}")
            raise

    print("\n===== 流水线执行完成 =====")
    n_met = len(list((PROJECT_ROOT / "output" / "metrics").glob("*.csv")))
    n_bi = len(list((PROJECT_ROOT / "output" / "bi").glob("*.csv")))
    n_fig = len(list((PROJECT_ROOT / "figures").glob("*.png")))
    print(f"output/metrics: {n_met} 个 CSV | output/bi: {n_bi} 个 CSV | figures: {n_fig} 张 PNG")
    print("交叉校验：SQL / pandas 9 项一致；Excel 复算值缓存在 cross_check.xlsx（说明见 excel_cross_check.md）；结论文档：report/")


if __name__ == "__main__":
    main()
