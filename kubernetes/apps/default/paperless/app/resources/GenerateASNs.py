import os
import sys
from pathlib import Path
import argparse

import AveryLabels
from reportlab.lib.units import mm, cm
from reportlab_qrcode import QRCodeImage


def render(c, x, y, barcode_value=None):
    # If barcode_value provided, draw that; otherwise raise an error.
    if barcode_value is None:
        raise RuntimeError("render called without barcode_value")

    qr = QRCodeImage(barcode_value, size=y * 0.9)
    qr.drawOn(c, 1 * mm, y * 0.05)
    c.setFont("Helvetica", 2 * mm)
    c.drawString(y, (y - 2 * mm) / 2, barcode_value)


def main(start_asn: int):
    count = 189
    end_asn = start_asn + count - 1

    res_dir = Path(__file__).resolve().parent
    out_name = f"ASN-{start_asn:05d}-{end_asn:05d}.pdf"
    out_path = res_dir / out_name

    # Create an iterator of barcode strings for the labels
    def iterator():
        for n in range(start_asn, start_asn + count):
            yield f"ASN{n:05d}"

    label = AveryLabels.AveryLabel(4731)
    label.open(str(out_path))

    # render_iterator expects a func(canv, width, height, chunk)
    def render_chunk(canv, w, h, chunk):
        render(canv, w, h, chunk)

    label.render_iterator(render_chunk, iterator())
    label.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate ASN labels PDF")
    parser.add_argument(
        "start", nargs="?", type=int, help="Start ASN number (e.g. 190)"
    )
    args = parser.parse_args()

    # Priority: CLI arg -> STARTASN env var -> default 190
    if args.start is not None:
        start = args.start
    else:
        env = os.environ.get("STARTASN")
        start = int(env) if env is not None else 190

    main(start)
