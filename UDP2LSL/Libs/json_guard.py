# -*- coding: utf-8 -*-
# 处理json数据，取 float、矩阵校验、丢弃脏行。

"""
Libs/json_guard.py
字段提取与简单校验工具。
"""

from typing import Any, List, Optional


def f(x: Any) -> Optional[float]:
    return float(x) if isinstance(x, (int, float)) else None


def i(x: Any) -> Optional[int]:
    return int(x) if isinstance(x, (int, float)) else None


def rows_as_float(mat: Any, ch: int) -> List[List[float]]:
    rows: List[List[float]] = []
    if not isinstance(mat, list) or ch <= 0:
        return rows
    for row in mat:
        if isinstance(row, list) and len(row) >= ch:
            try:
                vec = [float(row[j]) for j in range(ch)]
            except Exception:
                continue
            rows.append(vec)
    return rows