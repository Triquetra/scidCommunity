#!/usr/bin/env python3
"""
Chess Piece Downloader and Packager for scidCommunity.
Downloads SVG pieces from the Lichess GitHub repository,
converts them to transparent PNGs at various board sizes,
and combines them horizontally in Scid's required layout.

Usage:
    python3 scripts/download_lichess_pieces.py <piece_set_name>

Example:
    python3 scripts/download_lichess_pieces.py cburnett
    python3 scripts/download_lichess_pieces.py fresca

A copyright file is written into the output folder recording the author and
licence of the set, as required by img/pieces/ReadMe.txt.
"""

import argparse
import os
import shutil
import subprocess
import sys
import urllib.request

# Scid piece order:
# wp wn wb wr wq wk bp bn bb br bq bk
# Corresponding Lichess files:
# wP wN wB wR wQ wK bP bN bB bR bQ bK
PIECES = ['wP', 'wN', 'wB', 'wR', 'wQ', 'wK', 'bP', 'bN', 'bB', 'bR', 'bQ', 'bK']
LICHESS_BASE_URL = "https://raw.githubusercontent.com/lichess-org/lila/master/public/piece/{}/{}.svg"

# Board sizes used by the sets already shipped with scidCommunity.
SIZES = [25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100,
         105, 110, 115, 130, 145, 170, 200]

# Author and licence of the piece sets in lichess-org/lila, taken from
# https://github.com/lichess-org/lila/blob/master/COPYING.md
LICHESS_LICENSES = {
    'alpha': ('Eric Bentzen', 'free for personal non commercial use',
              'http://www.enpassant.dk/chess/downl/alpha.zip'),
    'anarcandy': ('caderek', 'CC BY-NC-SA 4.0',
                  'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'california': ('Jerry S.', 'CC BY-NC-SA 4.0',
                   'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'caliente': ('avi', 'CC BY-NC-SA 4.0',
                 'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'cardinal': ('sadsnake1', 'CC BY-NC-SA 4.0',
                 'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'cburnett': ('Colin M.L. Burnett', 'GPLv2+',
                 'https://www.gnu.org/licenses/gpl-2.0.txt'),
    'celtic': ('Maurizio Monge', 'MIT',
               'https://github.com/maurimo/chess-art/blob/main/LICENSE'),
    'chess7': ('Style-7', 'freeware', 'http://www.styleseven.com/'),
    'chessnut': ('Alexis Luengas', 'Apache 2.0',
                 'https://github.com/LexLuengas/chessnut-pieces/blob/master/LICENSE.txt'),
    'companion': ('David L. Brown', 'freeware',
                  'http://www.enpassant.dk/chess/fonteng.htm#GC'),
    'cooke': ('fejfar', 'CC BY-NC-SA 4.0',
              'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'disguised': ('danegraphics', 'CC BY-NC-SA 4.0',
                  'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'dubrovny': ('sadsnake1', 'CC BY-NC-SA 4.0',
                 'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'fantasy': ('Maurizio Monge', 'MIT',
                'https://github.com/maurimo/chess-art/blob/main/LICENSE'),
    'firi': ('James Faure', 'CC BY 4.0',
             'https://creativecommons.org/licenses/by/4.0/'),
    'fresca': ('sadsnake1', 'CC BY-NC-SA 4.0',
               'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'gioco': ('sadsnake1', 'CC BY-NC-SA 4.0',
              'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'horsey': ('cham, michael1241', 'CC BY-NC-SA 4.0',
               'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'icpieces': ('sadsnake1', 'CC BY-NC-SA 4.0',
                 'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'kiwen-suwi': ('neverRare', 'CC BY 4.0',
                   'https://creativecommons.org/licenses/by/4.0/'),
    'leipzig': ('Armando Hernandez Marroquin', 'freeware',
                'http://www.enpassant.dk/chess/fonteng.htm#LEIPZIG'),
    'letter': ('usolando', 'AGPLv3+',
               'https://www.gnu.org/licenses/agpl-3.0.txt'),
    'maestro': ('sadsnake1', 'CC BY-NC-SA 4.0',
                'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'merida': ('Armando Hernandez Marroquin', 'GPLv2+',
               'https://www.gnu.org/licenses/gpl-2.0.txt'),
    'minimal-warmth': ('blunder_reign', 'CC BY-NC-SA 4.0',
                       'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'monarchy': ('slither77', 'CC BY-NC-SA 4.0',
                 'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'mono': ('Thibault Duplessis and Colin M.L. Burnett', 'GPLv2+',
             'https://www.gnu.org/licenses/gpl-2.0.txt'),
    'mpchess': ('Maxime Chupin', 'GPLv3+',
                'https://www.gnu.org/licenses/quick-guide-gplv3.en.html'),
    'papercut': ('Nikolay Anzarov', 'CC BY 4.0',
                 'https://creativecommons.org/licenses/by/4.0/'),
    'pixel': ('therealqtpi', 'AGPLv3+',
              'https://www.gnu.org/licenses/agpl-3.0.txt'),
    'rhosgfx': ('RhosGFX', 'CC0 1.0',
                'https://creativecommons.org/publicdomain/zero/1.0/'),
    'shapes': ('flugsio', 'CC BY-SA 4.0',
               'https://creativecommons.org/licenses/by-sa/4.0/'),
    'spatial': ('Maurizio Monge', 'MIT',
                'https://github.com/maurimo/chess-art/blob/main/LICENSE'),
    'staunty': ('sadsnake1', 'CC BY-NC-SA 4.0',
                'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'tatiana': ('sadsnake1', 'CC BY-NC-SA 4.0',
                'https://creativecommons.org/licenses/by-nc-sa/4.0/'),
    'totoy': ('Kosal Sen', 'CC BY 4.0',
              'https://creativecommons.org/licenses/by/4.0/'),
}

NON_COMMERCIAL_NOTE = """\
This licence does not permit commercial use. Any redistribution of these
images, modified or not, must keep the same attribution and licence (share
alike). The PNG strips below are a derivative work of the original SVGs.
"""


def find_magick():
    """Return the ImageMagick command name, preferring IM7's 'magick'."""
    for name in ("magick", "convert"):
        if shutil.which(name):
            return name
    print("Error: ImageMagick is not installed or not in PATH.", file=sys.stderr)
    sys.exit(1)


def find_svg_renderer():
    """Return the best available SVG rasteriser as a small command builder."""
    if shutil.which("rsvg-convert"):
        return "rsvg"
    if shutil.which("inkscape"):
        return "inkscape"
    return "magick"


def render_svg(renderer, magick, svg_path, png_path, size):
    """Render one SVG to a size x size transparent PNG."""
    if renderer == "rsvg":
        cmd = ["rsvg-convert", "-w", str(size), "-h", str(size),
               "-o", png_path, svg_path]
    elif renderer == "inkscape":
        cmd = ["inkscape", "--export-type=png", f"--export-filename={png_path}",
               f"--export-width={size}", f"--export-height={size}", svg_path]
    else:
        # Rasterise at ~3x the target so the downscale stays crisp instead of
        # upscaling the default 96dpi render.
        cmd = [magick, "-background", "none", "-density", str(size * 3),
               svg_path, "-resize", f"{size}x{size}", png_path]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error rendering {svg_path} at {size}px:", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        return False
    return True


def image_size(magick, path):
    result = subprocess.run([magick, "identify", "-format", "%w %h", path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        w, h = result.stdout.split()
        return int(w), int(h)
    except ValueError:
        return None


def write_copyright(output_dir, piece_set, author, license_name, license_url):
    """Write the copyright file required by img/pieces/ReadMe.txt."""
    lines = [
        f"{piece_set.capitalize()} chess pieces",
        "=" * (len(piece_set) + len(" chess pieces")),
        "",
        f"  Author  : {author}",
        f"  Source  : https://github.com/lichess-org/lila/tree/master/"
        f"public/piece/{piece_set}",
        f"  License : {license_name}",
        f"            {license_url}",
        "",
        "Obtained from the Lichess source repository (lichess-org/lila) and",
        "converted from the original 50x50 viewBox SVGs to transparent PNG",
        "strips compatible with the scidCommunity chess interface.",
    ]
    if "NC" in license_name:
        lines += ["", NON_COMMERCIAL_NOTE.rstrip("\n")]
    lines.append("")

    path = os.path.join(output_dir, "copyright")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"  Wrote {os.path.relpath(path)}")


def main():
    parser = argparse.ArgumentParser(
        description="Download Lichess SVG pieces and build Scid PNG strips.")
    parser.add_argument("piece_set",
                        help="Lichess piece set name, e.g. fresca or cburnett")
    parser.add_argument("--sizes", type=int, nargs="+", default=SIZES,
                        help="board sizes to generate (default: all Scid sizes)")
    parser.add_argument("--author", help="override the author recorded in copyright")
    parser.add_argument("--license", dest="license_name",
                        help="override the licence name recorded in copyright")
    parser.add_argument("--license-url", help="override the licence URL")
    args = parser.parse_args()

    piece_set = args.piece_set.strip().lower()
    magick = find_magick()
    renderer = find_svg_renderer()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    output_dir = os.path.join(project_root, "img", "pieces", piece_set.capitalize())
    temp_dir = os.path.join(script_dir, f"temp_{piece_set}")

    print(f"Targeting piece set: {piece_set}")
    print(f"Output directory: {output_dir}")
    print(f"SVG renderer: {renderer}")

    os.makedirs(temp_dir, exist_ok=True)

    try:
        # 1. Download all SVGs
        svg_files = {}
        for p in PIECES:
            url = LICHESS_BASE_URL.format(piece_set, p)
            svg_path = os.path.join(temp_dir, f"{p}.svg")
            print(f"Downloading {p}.svg...")
            try:
                urllib.request.urlretrieve(url, svg_path)
                svg_files[p] = svg_path
            except Exception as e:
                print(f"Error downloading {p} from {url}: {e}", file=sys.stderr)
                return 1

        # 2. Render and combine for each target size
        os.makedirs(output_dir, exist_ok=True)
        for size in sorted(args.sizes):
            print(f"Processing size {size}...")
            temp_pngs = []

            for p in PIECES:
                png_path = os.path.join(temp_dir, f"{p}_{size}.png")
                if not render_svg(renderer, magick, svg_files[p], png_path, size):
                    return 1
                dims = image_size(magick, png_path)
                if dims != (size, size):
                    print(f"Error: {p} rendered as {dims}, expected "
                          f"{size}x{size}.", file=sys.stderr)
                    return 1
                temp_pngs.append(png_path)

            # Combine pieces horizontally into a single strip.
            # Force 8-bit RGBA so Tk gets the same pixel format as the other
            # shipped sets, even when a set is entirely greyscale.
            output_strip = os.path.join(output_dir,
                                        f"{piece_set}_{size}.png")
            cmd = [magick] + temp_pngs + ["+append", f"PNG32:{output_strip}"]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Error appending images for size {size}:", file=sys.stderr)
                print(result.stderr, file=sys.stderr)
                return 1
            print(f"  Created {os.path.relpath(output_strip)}")

        # 3. Record attribution and licence
        author, license_name, license_url = LICHESS_LICENSES.get(
            piece_set, ("the Lichess authors", "see Lichess COPYING.md",
                        "https://github.com/lichess-org/lila/blob/master/COPYING.md"))
        write_copyright(output_dir, piece_set,
                        args.author or author,
                        args.license_name or license_name,
                        args.license_url or license_url)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

    print(f"\nSuccessfully downloaded and generated '{piece_set}' pieces!")
    print("Restart scidCommunity to see the new set in your options.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
