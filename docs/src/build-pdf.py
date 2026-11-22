"""Render docs/src/phase2-report.html to the Phase 2 report PDF using Chrome.

Usage (from the repo root):  python3 docs/src/build-pdf.py
Needs:  pip install playwright  (uses the installed Google Chrome)
"""
from pathlib import Path
from playwright.sync_api import sync_playwright

SRC = Path(__file__).with_name("phase2-report.html").resolve()
OUT = SRC.parents[1] / "Private Network Service Platform — Phase 2 Report.pdf"
TITLE = "Private Network Service Platform — Phase 2 Report"

HEADER = f"""<div style="font-size:7.5px;color:#8a8984;width:100%;padding:0 17mm;
font-family:-apple-system,Helvetica,Arial,sans-serif;">{TITLE}</div>"""
FOOTER = """<div style="font-size:7.5px;color:#8a8984;width:100%;padding:0 17mm;text-align:right;
font-family:-apple-system,Helvetica,Arial,sans-serif;">Page <span class="pageNumber"></span>
of <span class="totalPages"></span></div>"""

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome")
    page = browser.new_page()
    page.goto(SRC.as_uri(), wait_until="load")
    page.pdf(
        path=str(OUT),
        format="A4",
        print_background=True,
        prefer_css_page_size=True,
        display_header_footer=True,
        header_template=HEADER,
        footer_template=FOOTER,
    )
    browser.close()

print(OUT)
