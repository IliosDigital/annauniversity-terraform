"""Minimal Word (.docx) reading and writing with the standard library only."""
import io
import re
import zipfile
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
SYNTHETIC_PAGE_CHARS = 3000
MAX_UNCOMPRESSED_BYTES = 200 * 1024 * 1024  # zip-bomb guard


def read_docx_pages(data):
    """[(page_number, text)]. Real page breaks are used when the file has them;
    otherwise a page is about 3000 characters."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if sum(i.file_size for i in archive.infolist()) > MAX_UNCOMPRESSED_BYTES:
            raise ValueError("docx expands beyond the allowed size")

        root = ET.fromstring(archive.read("word/document.xml"))

    pages, current, size, explicit = [], [], 0, False

    def close_page():
        nonlocal current, size
        if current:
            pages.append("\n".join(current))

        current, size = [], 0

    for paragraph in root.iter(W + "p"):
        for node in paragraph.iter():
            if node.tag == W + "lastRenderedPageBreak" or (
                node.tag == W + "br" and node.get(W + "type") == "page"
            ):
                explicit = True
                close_page()

        text = "".join(t.text or "" for t in paragraph.iter(W + "t")).strip()

        if text:
            current.append(text)
            size += len(text)

            if not explicit and size >= SYNTHETIC_PAGE_CHARS:
                close_page()

    close_page()
    return list(enumerate(pages, start=1))


def _paragraph(text, style=None, bold=False):
    props = f'<w:pPr><w:pStyle w:val="{style}"/></w:pPr>' if style else ""
    run_props = "<w:rPr><w:b/></w:rPr>" if bold else ""
    return (
        f"<w:p>{props}<w:r>{run_props}"
        f'<w:t xml:space="preserve">{escape(text)}</w:t></w:r></w:p>'
    )


def write_docx(blocks):
    """blocks: [("title"|"heading"|"para"|"bold"|"pagebreak", text)] -> docx bytes."""
    styles = {"title": ("Title", False), "heading": ("Heading1", False),
              "para": (None, False), "bold": (None, True)}
    page_break = '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
    body = "".join(
        page_break if kind == "pagebreak" else _paragraph(text, *styles[kind])
        for kind, text in blocks
    )
    document = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{body}</w:body></w:document>"
    )
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>"
    )
    rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        "</Relationships>"
    )
    buffer = io.BytesIO()

    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", rels)
        archive.writestr("word/document.xml", document)

    return buffer.getvalue()


def sniff(data):
    """'pdf', 'docx' or None, from the file's first bytes, not its name."""
    if data[:5] == b"%PDF-":
        return "pdf"

    if data[:4] == b"PK\x03\x04":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                if "word/document.xml" in archive.namelist():
                    return "docx"
        except zipfile.BadZipFile:
            return None

    return None
