"""Read a HWPX thermal journal template and list its photo rows.

This tool is intentionally read-only and uses only the Python standard library.
It writes UTF-8 JSON for the AutoHotkey/WebView2 host.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import zipfile
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET


HP_NS = "http://www.hancom.co.kr/hwpml/2011/paragraph"
NS = {"hp": HP_NS}
SECTION_PATTERN = re.compile(r"^Contents/section\d+\.xml$", re.IGNORECASE)


class TemplateAnalysisError(RuntimeError):
    pass


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def node_text(node: ET.Element) -> str:
    paragraphs: list[str] = []
    for paragraph in node.findall(".//hp:p", NS):
        text = normalize_text("".join(part.text or "" for part in paragraph.findall(".//hp:t", NS)))
        if text:
            paragraphs.append(text)
    return normalize_text(" ".join(paragraphs))


def compact_header(value: str) -> str:
    return re.sub(r"\s+", "", value or "")


def cell_address(cell: ET.Element) -> tuple[int, int]:
    address = cell.find("./hp:cellAddr", NS)
    if address is None:
        raise TemplateAnalysisError("표 셀 주소를 읽을 수 없습니다.")
    return int(address.get("rowAddr", "0")), int(address.get("colAddr", "0"))


def cell_span(cell: ET.Element) -> tuple[int, int]:
    span = cell.find("./hp:cellSpan", NS)
    if span is None:
        return 1, 1
    return int(span.get("rowSpan", "1")), int(span.get("colSpan", "1"))


def find_target_tables(section_roots: list[tuple[str, ET.Element]]) -> list[tuple[str, int, ET.Element]]:
    candidates: list[tuple[str, int, ET.Element]] = []

    for section_path, root in section_roots:
        for table_index, table in enumerate(root.findall(".//hp:tbl", NS)):
            table_text = compact_header(node_text(table))
            has_visible = "실화상" in table_text
            has_thermal = "열화상" in table_text
            if not (has_visible and has_thermal):
                continue

            candidates.append((section_path, table_index, table))

    if not candidates:
        raise TemplateAnalysisError("실화상·열화상 사진 열이 있는 표를 찾지 못했습니다.")

    return candidates


def analyze_table(table: ET.Element) -> dict:
    cells: list[dict] = []
    by_position: dict[tuple[int, int], dict] = {}

    for cell in table.findall("./hp:tr/hp:tc", NS):
        row, col = cell_address(cell)
        row_span, col_span = cell_span(cell)
        record = {
            "row": row,
            "col": col,
            "rowSpan": row_span,
            "colSpan": col_span,
            "text": node_text(cell),
        }
        cells.append(record)
        by_position[(row, col)] = record

    visible_headers = [cell for cell in cells if compact_header(cell["text"]) == "실화상"]
    thermal_headers = [cell for cell in cells if compact_header(cell["text"]) == "열화상"]
    if not visible_headers or not thermal_headers:
        raise TemplateAnalysisError("실화상·열화상 열의 위치를 확인하지 못했습니다.")

    visible_header = visible_headers[0]
    thermal_header = thermal_headers[0]
    header_row = max(visible_header["row"], thermal_header["row"])
    visible_col = visible_header["col"]
    thermal_col = thermal_header["col"]

    phase_headers = []
    for cell in cells:
        value = compact_header(cell["text"]).upper()
        if re.match(r"^[RST](?:상)?(?:\[?℃\]?)?$", value):
            phase_headers.append(cell["col"])

    result_start_col = min(phase_headers) if phase_headers else max(0, visible_col - 3)
    identifier_cols = list(range(result_start_col))

    inherited: dict[tuple[int, int], str] = {}
    for cell in cells:
        if cell["col"] not in identifier_cols or not cell["text"]:
            continue
        for row_offset in range(cell["rowSpan"]):
            inherited[(cell["row"] + row_offset, cell["col"])] = cell["text"]

    data_rows = sorted(
        row
        for row, col in by_position
        if row > header_row
        and col == visible_col
        and (row, thermal_col) in by_position
    )

    raw_items: list[dict] = []
    for row in data_rows:
        label_parts: list[str] = []
        for col in identifier_cols:
            value = normalize_text(inherited.get((row, col), ""))
            if value and value not in label_parts:
                label_parts.append(value)

        if not label_parts:
            label_parts = [f"항목 {len(raw_items) + 1}"]

        group = label_parts[0] if len(label_parts) > 1 else ""
        name = " · ".join(label_parts[1:]) if len(label_parts) > 1 else label_parts[0]
        base_label = " · ".join(label_parts)

        raw_items.append(
            {
                "id": f"row-{row}",
                "row": row,
                "group": group,
                "name": name,
                "baseLabel": base_label,
                "label": base_label,
                "visibleCell": {"row": row, "col": visible_col},
                "thermalCell": {"row": row, "col": thermal_col},
            }
        )

    if not raw_items:
        raise TemplateAnalysisError("사진을 넣을 수 있는 점검항목 행을 찾지 못했습니다.")

    totals = Counter(item["baseLabel"] for item in raw_items)
    seen: defaultdict[str, int] = defaultdict(int)
    for item in raw_items:
        base_label = item["baseLabel"]
        if totals[base_label] > 1:
            seen[base_label] += 1
            item["label"] = f"{base_label} ({seen[base_label]})"
            item["name"] = f"{item['name']} ({seen[base_label]})"

    title = ""
    for cell in sorted(cells, key=lambda item: (item["row"], item["col"])):
        if "전기설비온도측정표" in compact_header(cell["text"]):
            title = cell["text"]
            break
    if not title:
        title = "열화상 점검표"

    return {
        "title": title,
        "rowCount": int(table.get("rowCnt", "0")),
        "columnCount": int(table.get("colCnt", "0")),
        "headerRow": header_row,
        "visibleColumn": visible_col,
        "thermalColumn": thermal_col,
        "items": raw_items,
    }


def analyze_hwpx(path: Path) -> dict:
    if path.suffix.lower() != ".hwpx":
        raise TemplateAnalysisError("HWPX 파일만 분석할 수 있습니다.")
    if not path.is_file():
        raise TemplateAnalysisError("선택한 파일이 존재하지 않습니다.")

    try:
        with zipfile.ZipFile(path) as archive:
            section_paths = sorted(name for name in archive.namelist() if SECTION_PATTERN.match(name))
            if not section_paths:
                raise TemplateAnalysisError("HWPX 본문 섹션을 찾지 못했습니다.")

            section_roots = []
            for section_path in section_paths:
                section_roots.append((section_path, ET.fromstring(archive.read(section_path))))
    except zipfile.BadZipFile as exc:
        raise TemplateAnalysisError("올바른 HWPX 파일이 아닙니다.") from exc
    except ET.ParseError as exc:
        raise TemplateAnalysisError("HWPX 내부 XML을 읽지 못했습니다.") from exc

    target_tables = find_target_tables(section_roots)
    tables_result: list[dict] = []
    all_items: list[dict] = []

    for table_order, (section_path, table_index, table) in enumerate(target_tables, start=1):
        table_result = analyze_table(table)
        table_title = table_result["title"]

        for item in table_result["items"]:
            item["id"] = f"table-{table_order}-row-{item['row']}"
            item["tableOrder"] = table_order
            item["tableIndex"] = table_index
            item["sectionPath"] = section_path
            item["tableTitle"] = table_title

        table_summary = {
            "order": table_order,
            "sectionPath": section_path,
            "tableIndex": table_index,
            "title": table_title,
            "rowCount": table_result["rowCount"],
            "columnCount": table_result["columnCount"],
            "headerRow": table_result["headerRow"],
            "visibleColumn": table_result["visibleColumn"],
            "thermalColumn": table_result["thermalColumn"],
            "itemCount": len(table_result["items"]),
            "items": table_result["items"],
        }
        tables_result.append(table_summary)
        all_items.extend(table_result["items"])

    return {
        "success": True,
        "fileName": path.name,
        "filePath": str(path.resolve()),
        "format": "hwpx",
        "tableCount": len(tables_result),
        "tables": tables_result,
        "itemCount": len(all_items),
        "items": all_items,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        result = analyze_hwpx(args.input)
        exit_code = 0
    except TemplateAnalysisError as exc:
        result = {"success": False, "message": str(exc)}
        exit_code = 2
    except Exception as exc:  # keep host-facing errors concise but inspectable
        result = {"success": False, "message": f"문서 분석 중 오류가 발생했습니다: {exc}"}
        exit_code = 3

    output_text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output_text, encoding="utf-8")
    else:
        sys.stdout.write(output_text)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

