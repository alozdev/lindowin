"""Renders the README images:

  docs/demo.gif            `docker` is missing -> one-line install (sped up) ->
                           `docker run nginx` -> "Welcome to nginx!"
  docs/compare.gif         Windows Server: native Docker fails with nginx,
                           lindowin runs it
  docs/social-preview.png  1280x640 image for the GitHub "Social preview" setting

The installer text is its real output (trimmed). Version numbers are fetched
from the same official sources the installer uses, so the images stay current.
Regenerated automatically by .github/workflows/demo-gif.yml.

Usage:
    pip install pillow
    python docs/make-demo-gif.py [--out-dir docs] [--fonts DIR]

--fonts: folder with CascadiaMono-Regular.ttf / CascadiaMono-SemiBold.ttf.
If omitted, Cascadia Mono (SIL OFL) is downloaded from Microsoft's GitHub.
"""
import argparse
import io
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASCADIA_ZIP = "https://github.com/microsoft/cascadia-code/releases/download/v2407.24/CascadiaCode-2407.24.zip"
INSTALL_CMD = "irm https://raw.githubusercontent.com/alozdev/lindowin/main/install.ps1 | iex"
UA = {"User-Agent": "lindowin-demo"}


# ---- Versions (same sources as install.ps1) --------------------------------------

def http_get(url, headers=None, attempts=4):
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    for i in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError:
            raise
        except Exception:
            if i == attempts:
                raise
            time.sleep(3 * i)


def latest_tag(repo):
    # github.com/<repo>/releases/latest redirects to .../tag/<tag>
    req = urllib.request.Request(f"https://github.com/{repo}/releases/latest", headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        m = re.search(r"/tag/([^/?#]+)$", r.geturl())
    if not m:
        raise RuntimeError(f"no latest release for {repo}")
    return m.group(1)


def short_sha(repo, ref):
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        data = json.loads(http_get(f"https://api.github.com/repos/{repo}/commits/{ref}", headers))
        return data["sha"][:7]
    except Exception:
        return None


def get_versions():
    listing = http_get("https://download.docker.com/win/static/stable/x86_64/").decode()
    found = re.findall(r'href="docker-(\d+\.\d+\.\d+)\.zip"', listing)
    docker = max(found, key=lambda v: tuple(int(x) for x in v.split(".")))
    return {
        "docker": docker,
        "docker_cli_build": short_sha("docker/cli", f"v{docker}"),
        "compose": latest_tag("docker/compose"),
        "buildx": latest_tag("docker/buildx"),
        "wsl": latest_tag("microsoft/WSL").lstrip("v"),
    }


def get_fonts_dir(arg):
    if arg:
        return arg
    tmp = os.path.join(tempfile.gettempdir(), "lindowin-fonts")
    if not os.path.exists(os.path.join(tmp, "CascadiaMono-Regular.ttf")):
        os.makedirs(tmp, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(http_get(CASCADIA_ZIP))) as z:
            for name in z.namelist():
                base = os.path.basename(name)
                if "/static/" in name and base in ("CascadiaMono-Regular.ttf", "CascadiaMono-SemiBold.ttf"):
                    with open(os.path.join(tmp, base), "wb") as f:
                        f.write(z.read(name))
    return tmp


# ---- Theme ------------------------------------------------------------------------

S = 2                 # draw at 2x, then downscale (smooth text and corners)
RADIUS = 12
BAR_H = 36
PAD_X, PAD_TOP = 16, 10
LH = 19

BG = (24, 24, 27)
BAR = (40, 40, 44)
BORDER = (64, 64, 70)
FG = (212, 212, 216)
DIM = (140, 140, 150)
WHITE = (250, 250, 250)
YELLOW = (229, 192, 123)
RED = (239, 108, 117)
GREEN = (152, 195, 121)
CYAN = (86, 182, 194)
BADGE_BG = (60, 52, 30)
ICON_BG = (1, 36, 86)
ICON_FG = (220, 230, 255)


class Fonts:
    def __init__(self, fonts_dir):
        mono = lambda n, size=14: ImageFont.truetype(os.path.join(fonts_dir, n), size * S)
        self.mono = mono("CascadiaMono-Regular.ttf")
        self.mono_b = mono("CascadiaMono-SemiBold.ttf")
        self.dir = fonts_dir
        self.ui = self.ui_font(12, bold=False)
        self.ui_b = self.ui_font(12, bold=True)

    def ui_font(self, size, bold):
        # Segoe UI on Windows (the workflow runs on windows-latest); Cascadia otherwise
        path = r"C:\Windows\Fonts\seguisb.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf"
        if os.path.exists(path):
            return ImageFont.truetype(path, size * S)
        name = "CascadiaMono-SemiBold.ttf" if bold else "CascadiaMono-Regular.ttf"
        return ImageFont.truetype(os.path.join(self.dir, name), size * S)


class Terminal:
    """One terminal window. Draw with render(); text helpers record frames via the Recorder."""

    def __init__(self, fonts, w, h, title, prompt):
        self.f, self.w, self.h, self.title, self.prompt = fonts, w, h, title, prompt
        self.rows = (h - BAR_H - PAD_TOP - 6) // LH
        self.lines = []
        self.badge = None
        self.cursor = True
        self.rec = None

    def mask(self):
        big = Image.new("L", (self.w * S, self.h * S), 0)
        ImageDraw.Draw(big).rounded_rectangle([0, 0, self.w * S - 1, self.h * S - 1], radius=RADIUS * S, fill=255)
        return big.resize((self.w, self.h), Image.LANCZOS).point(lambda v: 255 if v >= 128 else 0)

    def render(self):
        f, w, h = self.f, self.w * S, self.h * S
        img = Image.new("RGB", (w, h), BG)
        d = ImageDraw.Draw(img)

        # Title bar with a Windows Terminal style tab
        tab_w = 66 + d.textlength(self.title, font=f.ui) / S
        d.rectangle([0, 0, w, BAR_H * S], fill=BAR)
        d.rounded_rectangle([8 * S, 7 * S, (8 + tab_w) * S, (BAR_H + RADIUS) * S], radius=8 * S, fill=BG)
        d.rounded_rectangle([20 * S, 15 * S, 36 * S, 30 * S], radius=3 * S, fill=ICON_BG)
        d.text((22 * S, 14 * S), ">_", font=f.ui_b, fill=ICON_FG)
        d.text((46 * S, 13 * S), self.title, font=f.ui, fill=WHITE)
        d.text(((tab_w - 12) * S, 12 * S), "\u00d7", font=f.ui, fill=DIM)
        for x, glyph in ((self.w - 112, "\u2013"), (self.w - 70, "\u25a1"), (self.w - 30, "\u00d7")):
            d.text((x * S, 10 * S), glyph, font=f.ui, fill=FG)
        if self.badge:
            tw = d.textlength(self.badge, font=f.ui) / S
            x1 = self.w - 140
            d.rounded_rectangle([(x1 - tw - 22) * S, 9 * S, x1 * S, 28 * S], radius=10 * S, fill=BADGE_BG)
            d.text(((x1 - tw - 11) * S, 11 * S), self.badge, font=f.ui, fill=YELLOW)

        # Terminal text
        view = self.lines[-self.rows:]
        y = (BAR_H + PAD_TOP) * S
        for segs in view:
            x = PAD_X * S
            for text, color, bold in segs:
                font = f.mono_b if bold else f.mono
                d.text((x, y), text, font=font, fill=color)
                x += d.textlength(text, font=font)
            y += LH * S
        if self.cursor and view:
            x = PAD_X * S + sum(d.textlength(t, font=f.mono_b if b else f.mono) for t, _, b in view[-1])
            d.rounded_rectangle([x + 2 * S, y - LH * S + 3 * S, x + 9 * S, y - 2 * S], radius=S, fill=FG)

        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=RADIUS * S, outline=BORDER, width=S)
        return img.resize((self.w, self.h), Image.LANCZOS)

    # ---- text helpers (each one can record a frame) ----
    def snap(self, ms, cursor=True):
        self.cursor = cursor
        self.rec.snap(ms)

    def out(self, text="", color=FG, bold=False, ms=0):
        self.lines.append([(text, color, bold)])
        if ms:
            self.snap(ms, cursor=False)

    def ok(self, text, ms=200):
        self.lines.append([("    OK  ", GREEN, False), (text, FG, False)])
        self.snap(ms, cursor=False)

    def step(self, title, ms=160):
        self.out("==> " + title, CYAN, ms=ms)

    def type_cmd(self, cmd, before=700, after=350, step=2, speed=45):
        if not self.lines or self.lines[-1] != [(self.prompt, FG, False)]:
            self.lines.append([(self.prompt, FG, False)])
        self.snap(before)
        for i in range(0, len(cmd), step):
            self.lines[-1] = [(self.prompt, FG, False), (cmd[: i + step], YELLOW, False)]
            self.snap(speed)
        self.lines[-1] = [(self.prompt, FG, False), (cmd, YELLOW, False)]
        self.snap(after)

    def prompt_line(self):
        self.lines.append([(self.prompt, FG, False)])


class Recorder:
    """Places one or more terminals on a transparent canvas and records frames."""

    def __init__(self, w, h, panes):
        self.w, self.h, self.panes, self.frames = w, h, panes, []
        self.mask = Image.new("L", (w, h), 0)
        for term, (x, y) in panes:
            term.rec = self
            self.mask.paste(term.mask(), (x, y))

    def snap(self, ms):
        img = Image.new("RGB", (self.w, self.h), BG)
        for term, (x, y) in self.panes:
            img.paste(term.render(), (x, y))
        self.frames.append((img, ms))

    def blink(self, term, times=4, end=2500):
        for _ in range(times):
            term.snap(450, cursor=False)
            term.snap(450, cursor=True)
        term.snap(end)

    def save_gif(self, path):
        # One shared palette (no color flicker): exact theme colors + anti-aliasing
        # shades, plus one transparent index for the rounded corners / gaps.
        mix = lambda a, b, t: tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))
        colors = []
        add = lambda c: colors.append(c) if c not in colors else None
        for c in (BG, BAR, BORDER, BADGE_BG, ICON_BG):
            add(c)
        steps = [i / 8 for i in range(1, 9)]
        for fg in (FG, DIM, WHITE, YELLOW, RED, GREEN, CYAN):
            for t in steps:
                add(mix(BG, fg, t))
        for fg in (FG, DIM, WHITE):
            for t in steps:
                add(mix(BAR, fg, t))
        for t in steps:
            add(mix(BADGE_BG, YELLOW, t))
            add(mix(ICON_BG, ICON_FG, t))
            add(mix(BAR, BG, t))
            add(mix(BG, BORDER, t))
            add(mix(BAR, BORDER, t))
        colors = colors[:255]
        transparent = len(colors)
        pal = [v for c in colors for v in c] + [255, 0, 255]
        pal += [0, 0, 0] * (256 - len(pal) // 3)
        pal_img = Image.new("P", (1, 1))
        pal_img.putpalette(pal)
        outside = self.mask.point(lambda v: 255 - v)

        imgs = []
        for f, _ in self.frames:
            q = f.quantize(palette=pal_img, dither=Image.Dither.NONE)
            q.paste(transparent, (0, 0, self.w, self.h), mask=outside)
            imgs.append(q)
        imgs[0].save(path, save_all=True, append_images=imgs[1:], duration=[ms for _, ms in self.frames],
                     loop=0, transparency=transparent, disposal=2, optimize=False)
        return sum(ms for _, ms in self.frames) / 1000


def nginx_run(t, cmd, container_id):
    t.type_cmd(cmd, before=500, step=2, speed=40)
    t.out("Unable to find image 'nginx:latest' locally", ms=250)
    t.out("latest: Pulling from library/nginx", ms=550)
    t.out("Status: Downloaded newer image for nginx:latest", ms=250)
    t.out(container_id, DIM, ms=700)


# ---- docs/demo.gif ----------------------------------------------------------------

def build_demo(fonts, v):
    t = Terminal(fonts, 920, 280, "Windows PowerShell", "PS C:\\Users\\dev> ")
    rec = Recorder(920, 280, [(t, (0, 0))])

    # 1. docker is not there
    t.type_cmd("docker run -d -p 8080:80 nginx", before=800, speed=40)
    t.out("docker : The term 'docker' is not recognized as the name of a cmdlet, function,", RED)
    t.out("script file, or operable program.", RED, ms=1400)

    # 2. one-line install (sped up)
    t.type_cmd(INSTALL_CMD, before=500, step=3, speed=30, after=400)
    t.badge = ">> 2 min, sped up"
    t.out("")
    t.out("lindowin installer", WHITE, True)
    t.out("Headless Linux Docker for Windows. Terminal only, no Docker Desktop.", ms=400)
    t.step("Checking WSL")
    t.ok(f"WSL {v['wsl']}", ms=150)
    t.step("Installing Docker Engine inside WSL")
    t.ok("Docker Engine is running inside WSL", ms=250)
    t.step("Installing the Docker CLI for Windows")
    t.ok(f"docker.exe {v['docker']} installed (official static build)", ms=150)
    t.ok(f"docker compose {v['compose']} installed (checksum verified)", ms=150)
    t.ok(f"docker buildx {v['buildx']} installed (checksum verified)", ms=150)
    t.step("Configuring how published ports reach the network")
    t.ok("Mirrored networking: ports work exactly like on Linux (TCP/UDP, any IP)", ms=250)
    t.step("Starting and testing")
    t.ok(f"docker.exe {v['docker']}  ->  Docker Engine {v['docker']}", ms=300)
    t.out("Done!", GREEN, True, ms=1000)
    t.badge = None

    # 3. a Linux image just works
    t.out("")
    nginx_run(t, "docker run -d -p 8080:80 nginx", "3f9c2b7e41d8a05e6c1f9b2d7a4e8c03b5d6f1a2e9c7b4d8f0a3e6c9b2d5f7a1")
    t.type_cmd("curl.exe -s localhost:8080 | findstr title", before=400, speed=40)
    t.out("<title>Welcome to nginx!</title>", GREEN, True, ms=600)
    t.out("")
    t.prompt_line()
    rec.blink(t, times=2, end=2200)
    return rec


# ---- docs/compare.gif -------------------------------------------------------------

def build_compare(fonts, v):
    pw, ph, gap = 520, 250, 16
    left = Terminal(fonts, pw, ph, "Windows Server 2022: native Docker", "PS C:\\> ")
    right = Terminal(fonts, pw, ph, "Windows Server 2022: lindowin", "PS C:\\> ")
    rec = Recorder(pw * 2 + gap, ph, [(left, (0, 0)), (right, (pw + gap, 0))])
    left.prompt_line()
    right.prompt_line()
    right.cursor = False

    # Left: Windows containers only, so a Linux image cannot run
    left.type_cmd("docker run -d -p 80:80 nginx", before=900, speed=45)
    left.out("Unable to find image 'nginx:latest' locally", ms=300)
    left.out("latest: Pulling from library/nginx", ms=700)
    left.out("docker: no matching manifest for windows/amd64", RED)
    left.out("10.0.20348 in the manifest list entries.", RED, ms=600)
    left.out("")
    left.out("X  Linux images don't run here", RED, True, ms=1200)
    left.prompt_line()
    left.cursor = False

    # Right: same command, real Linux Docker
    nginx_run(right, "docker run -d -p 80:80 nginx", "3f9c2b7e41d8a05e6c1f9b2d7a4e8c03b5d...")
    right.type_cmd("curl.exe -s localhost | findstr title", before=300, speed=40)
    right.out("<title>Welcome to nginx!</title>", GREEN, True, ms=500)
    right.out("")
    right.out("OK Linux images just work", GREEN, True, ms=400)
    right.prompt_line()
    rec.blink(right, times=3, end=3000)
    return rec


# ---- docs/social-preview.png ------------------------------------------------------

def build_social(fonts, v):
    W, H = 1280, 640
    img = Image.new("RGB", (W * S, H * S), (15, 15, 18))
    d = ImageDraw.Draw(img)
    title = fonts.ui_font(96, bold=True)
    sub = fonts.ui_font(34, bold=False)
    small = fonts.ui_font(24, bold=False)
    d.text((80 * S, 70 * S), "lindowin", font=title, fill=WHITE)
    d.text((84 * S, 210 * S), "Headless Linux Docker for Windows", font=sub, fill=CYAN)
    d.text((84 * S, 262 * S), "Terminal only. No GUI. One command.", font=small, fill=DIM)
    img = img.resize((W, H), Image.LANCZOS)

    t = Terminal(fonts, 1120, 168, "Windows PowerShell", "PS C:\\> ")
    t.lines = [
        [(t.prompt, FG, False), ("docker run -d -p 8080:80 nginx", YELLOW, False)],
        [("3f9c2b7e41d8a05e6c1f9b2d7a4e8c03b5d6f1a2e9c7b4d8f0a3e6c9b2d5f7a1", DIM, False)],
        [(t.prompt, FG, False), ("curl.exe -s localhost:8080 | findstr title", YELLOW, False)],
        [("<title>Welcome to nginx!</title>", GREEN, True)],
        [(t.prompt, FG, False)],
    ]
    pane = t.render()
    img.paste(pane, (80, 392), t.mask())
    return img


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out-dir", default=os.path.join(ROOT, "docs"))
    p.add_argument("--fonts", default=None)
    args = p.parse_args()

    versions = get_versions()
    print("versions:", json.dumps(versions))
    fonts = Fonts(get_fonts_dir(args.fonts))

    for name, builder in (("demo.gif", build_demo), ("compare.gif", build_compare)):
        rec = builder(fonts, versions)
        secs = rec.save_gif(os.path.join(args.out_dir, name))
        print(f"{name}: {len(rec.frames)} frames, {secs:.1f} s")
    build_social(fonts, versions).save(os.path.join(args.out_dir, "social-preview.png"), optimize=True)
    print("social-preview.png: 1280x640")

    with open(os.path.join(args.out_dir, "demo-versions.json"), "w", encoding="utf-8") as f:
        json.dump(versions, f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
