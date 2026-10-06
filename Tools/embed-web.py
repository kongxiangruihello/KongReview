#!/usr/bin/env python3
"""把 Web/ 下的 JavaScript 嵌入为 Swift 源文件（避免依赖 SwiftPM 资源包，DMG 里不会找不到文件）。
修改 Web/*.js 后执行：python3 Tools/embed-web.py
"""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Packages/KongReviewCore/Sources/KongReviewCore/WebScripts.swift")
files = [("readability", "Readability.js", "Mozilla Readability 0.6.0（Apache License 2.0，见 Web/Readability-LICENSE.md）"),
         ("extract", "extract.js", "调用 Readability 提取正文"),
         ("reader", "reader.js", "阅读器：划线与标注")]
parts = ["// 由 Tools/embed-web.py 生成，请勿手改。\n\npublic enum WebScripts {\n"]
for name, fn, doc in files:
    src = open(os.path.join(ROOT, "Web", fn), encoding="utf-8").read()
    assert '"""#' not in src and '\\#' not in src, fn
    parts.append(f"    /// {doc}\n    public static let {name}: String = #\"\"\"\n{src}\n\"\"\"#\n\n")
parts.append("}\n")
open(OUT, "w", encoding="utf-8").write("".join(parts))
print("written", OUT)
