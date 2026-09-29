#!/usr/bin/env python3
"""Create a completed thermal journal by replacing image slots in an HWPX template."""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
import sys
import zipfile
from io import BytesIO
from pathlib import Path
import xml.etree.ElementTree as ET


NS = {
    "hp": "http://www.hancom.co.kr/hwpml/2011/paragraph",
    "hs": "http://www.hancom.co.kr/hwpml/2011/section",
    "hc": "http://www.hancom.co.kr/hwpml/2011/core",
    "opf": "http://www.idpf.org/2007/opf/",
}
EXPECTED_MIMETYPE = b"application/hwp+zip"
PHASE_PATTERN = re.compile(r"^[RST](?:상)?(?:\[?℃\]?)?$", re.IGNORECASE)


class JournalBuildError(RuntimeError):
    pass


def qname(prefix: str, local_name: str) -> str:
    return f"{{{NS[prefix]}}}{local_name}"


def register_namespaces(xml_bytes: bytes) -> None:
    seen: set[tuple[str, str]] = set()
    for _, pair in ET.iterparse(BytesIO(xml_bytes), events=("start-ns",)):
        prefix, uri = pair
        if (prefix, uri) in seen or prefix == "xml":
            continue
        seen.add((prefix, uri))
        try:
            ET.register_namespace(prefix, uri)
        except ValueError:
            pass


def parse_xml(xml_bytes: bytes) -> ET.Element:
    register_namespaces(xml_bytes)
    try:
        return ET.fromstring(xml_bytes)
    except ET.ParseError as exc:
        raise JournalBuildError(f"HWPX XML을 읽지 못했습니다: {exc}") from exc


def serialize_xml(root: ET.Element) -> bytes:
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def node_text(node: ET.Element) -> str:
    return " ".join(
        "".join(text_node.itertext()).strip()
        for text_node in node.findall(".//hp:t", NS)
        if "".join(text_node.itertext()).strip()
    ).strip()


def compact(value: str) -> str:
    return re.sub(r"\s+", "", value or "")


def find_cell(table: ET.Element, row: int, col: int) -> ET.Element:
    for cell in table.findall("./hp:tr/hp:tc", NS):
        address = cell.find("./hp:cellAddr", NS)
        if address is None:
            continue
        if int(address.get("rowAddr", "-1")) == row and int(address.get("colAddr", "-1")) == col:
            return cell
    raise JournalBuildError(f"표에서 대상 셀을 찾지 못했습니다: row={row}, col={col}")


def find_phase_columns(table: ET.Element) -> list[int]:
    columns: list[int] = []
    for cell in table.findall("./hp:tr/hp:tc", NS):
        value = compact(node_text(cell)).upper()
        if not PHASE_PATTERN.match(value):
            continue
        address = cell.find("./hp:cellAddr", NS)
        if address is not None:
            columns.append(int(address.get("colAddr", "0")))
    return sorted(set(columns))


def set_cell_text(cell: ET.Element, value: str) -> None:
    text_nodes = cell.findall(".//hp:t", NS)
    if text_nodes:
        text_nodes[0].text = value
        for extra in text_nodes[1:]:
            extra.text = None
        return

    run = cell.find(".//hp:run", NS)
    if run is None:
        paragraph = cell.find(".//hp:p", NS)
        if paragraph is None:
            raise JournalBuildError("온도값을 기록할 셀의 문단을 찾지 못했습니다.")
        run = ET.SubElement(paragraph, qname("hp", "run"), {"charPrIDRef": "17"})
    text_node = ET.SubElement(run, qname("hp", "t"))
    text_node.text = value


def first_picture_in_column(table: ET.Element, col: int) -> ET.Element | None:
    for cell in table.findall("./hp:tr/hp:tc", NS):
        address = cell.find("./hp:cellAddr", NS)
        if address is None or int(address.get("colAddr", "-1")) != col:
            continue
        picture = cell.find(".//hp:pic", NS)
        if picture is not None:
            return picture
    return None


def max_numeric_attribute(root: ET.Element, tag: str, attribute: str) -> int:
    maximum = 0
    for node in root.findall(f".//{tag}", NS):
        try:
            maximum = max(maximum, int(node.get(attribute, "0")))
        except ValueError:
            continue
    return maximum


def ensure_picture(
    cell: ET.Element,
    donor: ET.Element,
    image_ref: str,
    source_name: str,
    counters: dict[str, int],
) -> None:
    picture = cell.find(".//hp:pic", NS)
    if picture is None:
        picture = copy.deepcopy(donor)
        counters["id"] += 1
        counters["instid"] += 1
        counters["zOrder"] += 1
        picture.set("id", str(counters["id"]))
        picture.set("instid", str(counters["instid"]))
        picture.set("zOrder", str(counters["zOrder"]))

        run = cell.find(".//hp:run", NS)
        if run is None:
            paragraph = cell.find(".//hp:p", NS)
            if paragraph is None:
                raise JournalBuildError("그림을 넣을 셀의 문단을 찾지 못했습니다.")
            run = ET.SubElement(paragraph, qname("hp", "run"), {"charPrIDRef": "17"})
        run.insert(0, picture)

    image_node = picture.find(".//hc:img", NS)
    if image_node is None:
        raise JournalBuildError("그림 개체의 이미지 참조를 찾지 못했습니다.")
    image_node.set("binaryItemIDRef", image_ref)

    comment = picture.find("./hp:shapeComment", NS)
    if comment is not None:
        comment.text = (
            "그림입니다.\n\n"
            f"원본 그림의 이름: {source_name}\n\n"
            "원본 그림의 크기: 가로 536pixel, 세로 370pixel"
        )


def add_manifest_image(manifest: ET.Element, image_id: str, href: str) -> None:
    ET.SubElement(
        manifest,
        qname("opf", "item"),
        {
            "id": image_id,
            "href": href,
            "media-type": "image/jpeg",
            "isEmbeded": "1",
        },
    )


def collect_structure(root: ET.Element) -> dict:
    paragraphs = root.findall(".//hp:p", NS)
    tables = root.findall(".//hp:tbl", NS)
    return {
        "paragraphCount": len(paragraphs),
        "tableCount": len(tables),
        "pageBreakCount": sum(node.get("pageBreak") == "1" for node in paragraphs),
        "columnBreakCount": sum(node.get("columnBreak") == "1" for node in paragraphs),
        "tableShapes": [table_shape(table) for table in tables],
    }


def table_shape(table: ET.Element) -> tuple[str, str, str, str, str]:
    size = table.find("./hp:sz", NS)
    return (
        table.get("rowCnt", ""),
        table.get("colCnt", ""),
        size.get("width", "") if size is not None else "",
        size.get("height", "") if size is not None else "",
        table.get("pageBreak", ""),
    )


def validate_archive(path: Path) -> list[str]:
    errors: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            required = ["mimetype", "Contents/content.hpf", "Contents/header.xml", "Contents/section0.xml"]
            for name in required:
                if name not in names:
                    errors.append(f"필수 파일 누락: {name}")
            if names and names[0] != "mimetype":
                errors.append("mimetype이 첫 번째 ZIP 항목이 아닙니다.")
            if "mimetype" in names:
                if archive.read("mimetype").strip() != EXPECTED_MIMETYPE:
                    errors.append("HWPX mimetype이 올바르지 않습니다.")
                if archive.getinfo("mimetype").compress_type != zipfile.ZIP_STORED:
                    errors.append("mimetype은 무압축으로 저장되어야 합니다.")
            for name in names:
                if name.endswith((".xml", ".hpf")):
                    try:
                        ET.fromstring(archive.read(name))
                    except ET.ParseError as exc:
                        errors.append(f"XML 오류: {name}: {exc}")
    except (OSError, zipfile.BadZipFile) as exc:
        errors.append(f"HWPX ZIP 오류: {exc}")
    return errors


def write_result(path: Path | None, payload: dict) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    if path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    else:
        print(text)


def build_journal(session_path: Path, output_path: Path) -> dict:
    session = json.loads(session_path.read_text(encoding="utf-8-sig"))
    template_path = Path(session.get("templatePath", ""))
    items = session.get("items") or []
    if not template_path.is_file():
        raise JournalBuildError(f"원본 HWPX를 찾을 수 없습니다: {template_path}")
    if template_path.suffix.lower() != ".hwpx":
        raise JournalBuildError("HWPX 양식만 결과 문서로 만들 수 있습니다.")
    if not items:
        raise JournalBuildError("임시 작업에 점검항목이 없습니다.")
    if output_path.exists():
        raise JournalBuildError(f"결과 파일이 이미 존재합니다: {output_path}")

    for item in items:
        if not item.get("markerComplete"):
            raise JournalBuildError(f"마커 작업이 끝나지 않은 항목이 있습니다: {item.get('label', '')}")
        for key in ("processedX", "processedY"):
            if not Path(item.get(key, "")).is_file():
                raise JournalBuildError(f"처리된 사진을 찾을 수 없습니다: {item.get(key, '')}")

    with zipfile.ZipFile(template_path) as source:
        original_infos = source.infolist()
        original_data = {info.filename: source.read(info.filename) for info in original_infos}

    section_paths = sorted({item["sectionPath"] for item in items})
    section_roots: dict[str, ET.Element] = {}
    original_structures: dict[str, dict] = {}
    for section_path in section_paths:
        if section_path not in original_data:
            raise JournalBuildError(f"문서 섹션을 찾을 수 없습니다: {section_path}")
        root = parse_xml(original_data[section_path])
        section_roots[section_path] = root
        original_structures[section_path] = collect_structure(root)

    content_path = "Contents/content.hpf"
    content_root = parse_xml(original_data[content_path])
    manifest = content_root.find("./opf:manifest", NS)
    if manifest is None:
        raise JournalBuildError("HWPX manifest를 찾지 못했습니다.")

    image_payloads: dict[str, bytes] = {}
    replaced_images = 0
    written_temperatures = 0
    donors: dict[tuple[str, int, int], ET.Element] = {}
    counters: dict[str, dict[str, int]] = {}

    for section_path, root in section_roots.items():
        counters[section_path] = {
            "id": max_numeric_attribute(root, "hp:pic", "id"),
            "instid": max_numeric_attribute(root, "hp:pic", "instid"),
            "zOrder": max_numeric_attribute(root, "hp:pic", "zOrder"),
        }

    for item_number, item in enumerate(items, start=1):
        section_path = item["sectionPath"]
        root = section_roots[section_path]
        tables = root.findall(".//hp:tbl", NS)
        table_index = int(item["tableIndex"])
        if table_index < 0 or table_index >= len(tables):
            raise JournalBuildError(f"표 순서가 올바르지 않습니다: {table_index}")
        table = tables[table_index]

        phase_columns = find_phase_columns(table)
        markers = item.get("markers") or []
        if len(markers) > len(phase_columns):
            raise JournalBuildError(
                f"{item.get('label', '')}: 마커 {len(markers)}개를 기록할 온도 열이 "
                f"{len(phase_columns)}개뿐입니다."
            )
        row = int(item["row"])
        for phase_index, phase_col in enumerate(phase_columns):
            value = ""
            if phase_index < len(markers):
                value = str(markers[phase_index].get("displayTemperature", ""))
                written_temperatures += 1
            set_cell_text(find_cell(table, row, phase_col), value)

        for image_kind, cell_key, path_key, suffix in (
            ("visible", "visibleCell", "processedY", "y"),
            ("thermal", "thermalCell", "processedX", "x"),
        ):
            cell_info = item[cell_key]
            col = int(cell_info["col"])
            cell = find_cell(table, int(cell_info["row"]), col)
            donor_key = (section_path, table_index, col)
            if donor_key not in donors:
                donor = first_picture_in_column(table, col)
                if donor is None:
                    raise JournalBuildError(
                        f"{item.get('label', '')}: {image_kind} 열에서 복제할 그림 슬롯을 찾지 못했습니다."
                    )
                donors[donor_key] = donor

            image_id = f"thermalJournalImage{item_number:03d}{suffix.upper()}"
            package_name = f"BinData/thermal_journal_{item_number:03d}_{suffix}.jpg"
            processed_path = Path(item[path_key])
            image_payloads[package_name] = processed_path.read_bytes()
            add_manifest_image(manifest, image_id, package_name)
            ensure_picture(
                cell,
                donors[donor_key],
                image_id,
                processed_path.name,
                counters[section_path],
            )
            replaced_images += 1

    for section_path, root in section_roots.items():
        current_structure = collect_structure(root)
        if current_structure != original_structures[section_path]:
            raise JournalBuildError(f"페이지 구조 위험 검사 실패: {section_path}의 문단·표 구조가 변경되었습니다.")
        original_data[section_path] = serialize_xml(root)
    original_data[content_path] = serialize_xml(content_root)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temp_output = output_path.with_name(output_path.name + ".tmp")
    if temp_output.exists():
        temp_output.unlink()
    try:
        with zipfile.ZipFile(temp_output, "w") as target:
            for info in original_infos:
                payload = original_data[info.filename]
                if info.filename == "mimetype":
                    info.compress_type = zipfile.ZIP_STORED
                target.writestr(info, payload)
            for package_name, payload in image_payloads.items():
                target.writestr(package_name, payload, compress_type=zipfile.ZIP_DEFLATED)

        errors = validate_archive(temp_output)
        if errors:
            raise JournalBuildError("; ".join(errors))
        temp_output.replace(output_path)
    finally:
        if temp_output.exists():
            temp_output.unlink()

    return {
        "success": True,
        "outputPath": str(output_path.resolve()),
        "templatePath": str(template_path.resolve()),
        "itemCount": len(items),
        "replacedImageCount": replaced_images,
        "temperatureCount": written_temperatures,
        "structureGuardPassed": True,
        "archiveValidationPassed": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="임시 작업으로부터 열화상 일지 HWPX 생성")
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--result", type=Path)
    args = parser.parse_args()

    try:
        result = build_journal(args.session.resolve(), args.output.resolve())
        write_result(args.result, result)
        return 0
    except Exception as exc:
        result = {"success": False, "message": str(exc)}
        write_result(args.result, result)
        if args.result is None:
            print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
