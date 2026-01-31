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

    # Determine 2-digit range identifier from start ASN (hundred-thousands)
    range_id = start_asn // 100_000
    range_key = f"{range_id:02d}"

    res_dir = Path(__file__).resolve().parent
    barcodes_dir = res_dir / "barcodes"
    barcodes_dir.mkdir(parents=True, exist_ok=True)

    # Filename: ASN-<2digit range>-<start 7 digits>-<end 7 digits>.pdf
    out_name = f"ASN-{range_key}-{start_asn:07d}-{end_asn:07d}.pdf"
    out_path = barcodes_dir / out_name

    # Create an iterator of barcode strings for the labels
    def iterator():
        for n in range(start_asn, start_asn + count):
            yield f"ASN{n:07d}"

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
    parser.add_argument(
        "-r",
        "--range",
        dest="range_id",
        help="Range id (two digits, e.g. 01 for 0-199999)",
    )
    parser.add_argument(
        "-s", "--start", dest="start_opt", type=int, help="Explicit start ASN number"
    )
    args = parser.parse_args()

    # Priority: explicit --start -> positional start -> STARTASN env var -> --range -> default 190
    if args.start_opt is not None:
        start = args.start_opt
    elif args.start is not None:
        start = args.start
    else:
        env = os.environ.get("STARTASN")
        if env is not None:
            start = int(env)
        elif args.range_id is not None:
            # Resolve range start from state file
            rid = args.range_id
            # normalize to integer then zero-pad two digits
            try:
                rid_int = int(rid)
            except ValueError:
                print(f"Invalid range id: {rid}", file=sys.stderr)
                sys.exit(2)
            range_key = f"{rid_int:02d}"

            # Find scripts dir by searching parents for a 'scripts' directory
            scripts_dir = None
            for p in Path(__file__).resolve().parents:
                if (p / "scripts").is_dir():
                    scripts_dir = p / "scripts"
                    break
            if scripts_dir is None:
                print(
                    "Could not locate scripts directory to store state", file=sys.stderr
                )
                sys.exit(2)

            state_file = scripts_dir / "asn_state.json"
            try:
                if state_file.exists():
                    import json

                    with state_file.open("r") as fh:
                        state = json.load(fh)
                else:
                    state = {}
            except Exception:
                state = {}

            base_start = rid_int * 100_000
            base_end = base_start + 100_000 - 1

            last = state.get(range_key)
            if last is None:
                start = base_start
            else:
                start = int(last) + 1

            if start + 189 - 1 > base_end:
                print(
                    f"Range {range_key} exhausted or insufficient space for 189 ASNs",
                    file=sys.stderr,
                )
                sys.exit(1)

            # will update state after successful run
            update_state = True
            update_state_path = state_file
            update_state_key = range_key
        else:
            start = 190

    # Run
    main(start)

    # If we used range behavior, update the last generated ASN in state file
    if "update_state" in locals() and update_state:
        end_asn = start + 189 - 1
        import json

        state.update({update_state_key: end_asn})
        try:
            update_state_path.parent.mkdir(parents=True, exist_ok=True)
            with update_state_path.open("w") as fh:
                json.dump(state, fh, indent=2)
        except Exception as e:
            print(f"Warning: failed to update state file: {e}", file=sys.stderr)
