from pathlib import Path
from zipfile import ZipFile

from lxml import etree

NS = {
    "hp": "http://www.hancom.co.kr/hwpml/2011/paragraph",
}


def text_of(node):
    return "".join(node.xpath(".//hp:t/text()", namespaces=NS))


def addr(cell):
    node = cell.find("hp:cellAddr", namespaces=NS)
    return int(node.get("rowAddr")), int(node.get("colAddr"))


def main():
    path = Path(
        r"C:\Users\User\Desktop\D조\☆점검일지\전기실 점검(동원,청사)\청사\열화상 일지\20260625 열화상 사진(연간)\output\1년 열화상 일지(20260625)(2026.06.25).hwpx"
    )
    with ZipFile(path) as zf:
        section = zf.read("Contents/section0.xml")

    root = etree.fromstring(section)
    target = None
    for table in root.xpath(".//hp:tbl", namespaces=NS):
        text = text_of(table)
        if "PT,CT" in text or "PT, CT" in text:
            target = table
            break
    if target is None:
        raise SystemExit("thermal table not found")

    by_addr = {}
    for cell in target.xpath("./hp:tr/hp:tc", namespaces=NS):
        by_addr[addr(cell)] = cell

    row_addrs = []
    for row in target.xpath("./hp:tr", namespaces=NS):
        cols = {addr(cell)[1] for cell in row.xpath("./hp:tc", namespaces=NS)}
        if 5 in cols and 6 in cols:
            row_addr = min(addr(cell)[0] for cell in row.xpath("./hp:tc", namespaces=NS))
            if row_addr >= 6:
                row_addrs.append(row_addr)

    for row_addr in sorted(set(row_addrs)):
        values = [text_of(by_addr[(row_addr, col)]).strip() for col in (2, 3, 4)]
        comments = []
        for col in (5, 6):
            comment = by_addr[(row_addr, col)].find(".//hp:shapeComment", namespaces=NS)
            comments.append((comment.text or "").replace("\n", " ") if comment is not None else "")
        print(row_addr, ",".join(values), "|", " | ".join(comments))


if __name__ == "__main__":
    main()
