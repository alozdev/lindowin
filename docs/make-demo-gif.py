"""Renders docs/demo.gif: a terminal where `docker` is missing, the one-line
installer runs (sped up), and `docker` works afterwards.

The text is the installer's real output. Version numbers are fetched from the
same official sources the installer uses, so the GIF stays current. It is
regenerated automatically by .github/workflows/demo-gif.yml.

Usage:
    pip install pillow
    python docs/make-demo-gif.py [--out docs/demo.gif] [--fonts DIR]

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


# ---- Versions (same sources as install.ps1) --------------------------------------

def http_get(url, headers=None, attempts=4):
    req = urllib.request.Request(url, headers={"User-Agent": "wsl-docker-engine-demo", **(headers or {})})
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
    req = urllib.request.Request(f"https://github.com/{repo}/releases/latest",
                                 headers={"User-Agent": "wsl-docker-engine-demo"})
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
    with open(os.path.join(ROOT, "install.ps1"), encoding="utf-8") as f:
        ubuntu = re.search(r'\$UbuntuImage\s*=\s*"([^"]+)"', f.read()).group(1)
    return {
        "docker": docker,
        "docker_cli_build": short_sha("docker/cli", f"v{docker}"),
        "docker_engine_build": short_sha("moby/moby", f"docker-v{docker}"),
        "compose": latest_tag("docker/compose"),
        "buildx": latest_tag("docker/buildx"),
        "wsl": latest_tag("microsoft/WSL").lstrip("v"),
        "ubuntu": ubuntu,
    }


def get_fonts_dir(arg):
    if arg:
        return arg
    tmp = os.path.join(tempfile.gettempdir(), "wsl-docker-engine-fonts")
    if not os.path.exists(os.path.join(tmp, "CascadiaMono-Regular.ttf")):
        os.makedirs(tmp, exist_ok=True)
        with zipfile.ZipFile(io.BytesIO(http_get(CASCADIA_ZIP))) as z:
            for name in z.namelist():
                base = os.path.basename(name)
                if "/static/" in name and base in ("CascadiaMono-Regular.ttf", "CascadiaMono-SemiBold.ttf"):
                    with open(os.path.join(tmp, base), "wb") as f:
                        f.write(z.read(name))
    return tmp


# ---- Rendering --------------------------------------------------------------------

S = 2                 # draw at 2x, then downscale (smooth text and corners)
W, H = 920, 280       # final size
RADIUS = 12
BAR_H = 36
PAD_X, PAD_TOP = 16, 10
LH = 19
ROWS = (H - BAR_H - PAD_TOP - 6) // LH

# Modern dark theme
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
PROMPT = "PS C:\\Users\\dev> "


class Terminal:
    def __init__(self, fonts_dir):
        mono = lambda n: ImageFont.truetype(os.path.join(fonts_dir, n), 14 * S)
        self.mono = mono("CascadiaMono-Regular.ttf")
        self.mono_b = mono("CascadiaMono-SemiBold.ttf")
        ui, ui_b = r"C:\Windows\Fonts\segoeui.ttf", r"C:\Windows\Fonts\seguisb.ttf"
        self.ui = ImageFont.truetype(ui, 12 * S) if os.path.exists(ui) else mono("CascadiaMono-Regular.ttf")
        self.ui_b = ImageFont.truetype(ui_b, 12 * S) if os.path.exists(ui_b) else self.mono_b
        self.lines = []
        self.frames = []
        self.badge = None
        big = Image.new("L", (W * S, H * S), 0)
        ImageDraw.Draw(big).rounded_rectangle([0, 0, W * S - 1, H * S - 1], radius=RADIUS * S, fill=255)
        self.mask = big.resize((W, H), Image.LANCZOS).point(lambda v: 255 if v >= 128 else 0)

    def render(self, cursor=True):
        w, h = W * S, H * S
        img = Image.new("RGB", (w, h), BG)
        d = ImageDraw.Draw(img)

        # Title bar with a Windows Terminal style tab
        d.rectangle([0, 0, w, BAR_H * S], fill=BAR)
        d.rounded_rectangle([8 * S, 7 * S, 200 * S, (BAR_H + RADIUS) * S], radius=8 * S, fill=BG)
        d.rounded_rectangle([20 * S, 15 * S, 36 * S, 30 * S], radius=3 * S, fill=ICON_BG)
        d.text((22 * S, 14 * S), ">_", font=self.ui_b, fill=ICON_FG)
        d.text((46 * S, 13 * S), "Windows PowerShell", font=self.ui, fill=WHITE)
        d.text((180 * S, 12 * S), "\u00d7", font=self.ui, fill=DIM)
        d.text((214 * S, 11 * S), "+", font=self.ui, fill=DIM)
        cx, cy = 243 * S, 20 * S
        d.line([(cx - 4 * S, cy - 2 * S), (cx, cy + 2 * S), (cx + 4 * S, cy - 2 * S)], fill=DIM, width=S + 1)
        for x, glyph in ((W - 112, "\u2013"), (W - 70, "\u25a1"), (W - 30, "\u00d7")):
            d.text((x * S, 10 * S), glyph, font=self.ui, fill=FG)
        if self.badge:
            tw = d.textlength(self.badge, font=self.ui) / S
            x1 = W - 140
            d.rounded_rectangle([(x1 - tw - 22) * S, 9 * S, x1 * S, 28 * S], radius=10 * S, fill=BADGE_BG)
            d.text(((x1 - tw - 11) * S, 11 * S), self.badge, font=self.ui, fill=YELLOW)

        # Terminal text
        view = self.lines[-ROWS:]
        y = (BAR_H + PAD_TOP) * S
        for segs in view:
            x = PAD_X * S
            for text, color, bold in segs:
                f = self.mono_b if bold else self.mono
                d.text((x, y), text, font=f, fill=color)
                x += d.textlength(text, font=f)
            y += LH * S
        if cursor and view:
            x = PAD_X * S + sum(d.textlength(t, font=self.mono_b if b else self.mono) for t, _, b in view[-1])
            d.rounded_rectangle([x + 2 * S, y - LH * S + 3 * S, x + 9 * S, y - 2 * S], radius=S, fill=FG)

        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=RADIUS * S, outline=BORDER, width=S)
        return img.resize((W, H), Image.LANCZOS)

    def snap(self, ms, cursor=True):
        self.frames.append((self.render(cursor), ms))

    def out(self, text="", color=FG, bold=False, ms=0):
        self.lines.append([(text, color, bold)])
        if ms:
            self.snap(ms, cursor=False)

    def ok(self, text, ms=200):
        self.lines.append([("    OK  ", GREEN, False), (text, FG, False)])
        self.snap(ms, cursor=False)

    def step(self, title, ms=260):
        self.out("")
        self.out("==> " + title, CYAN, ms=ms)

    def type_cmd(self, cmd, before=700, after=350, step=2, speed=45):
        self.lines.append([(PROMPT, FG, False)])
        self.snap(before)
        for i in range(0, len(cmd), step):
            self.lines[-1] = [(PROMPT, FG, False), (cmd[: i + step], YELLOW, False)]
            self.snap(speed)
        self.lines[-1] = [(PROMPT, FG, False), (cmd, YELLOW, False)]
        self.snap(after)

    def save_gif(self, path):
        # One shared palette (no color flicker): exact theme colors + anti-aliasing
        # shades, plus one transparent index for the rounded corners.
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
            q.paste(transparent, (0, 0, W, H), mask=outside)
            imgs.append(q)
        imgs[0].save(path, save_all=True, append_images=imgs[1:], duration=[ms for _, ms in self.frames],
                     loop=0, transparency=transparent, disposal=2, optimize=False)


def build(t, v):
    cli_build = f", build {v['docker_cli_build']}" if v["docker_cli_build"] else ""
    engine_build = f", build {v['docker_engine_build']}" if v["docker_engine_build"] else ""

    # 1. docker is not there
    t.type_cmd("docker --version", before=900)
    t.out("docker : The term 'docker' is not recognized as the name of a cmdlet, function,", RED)
    t.out("script file, or operable program. Check the spelling of the name, or if a path", RED)
    t.out("was included, verify that the path is correct and try again.", RED, ms=2200)

    # 2. one-line install (sped up)
    t.type_cmd("irm https://raw.githubusercontent.com/alozdev/wsl-docker-engine/main/install.ps1 | iex",
               before=600, step=3, speed=35, after=500)
    t.badge = ">> install sped up"
    t.out("")
    t.out("wsl-docker-engine installer", WHITE, True)
    t.out("Docker Engine on WSL 2 + Docker CLI for Windows, without Docker Desktop", ms=500)
    t.step("Checking this PC")
    t.ok("Windows build 26100, x64")
    t.out("    Downloading installer files from github.com/alozdev/wsl-docker-engine", ms=300)
    t.step("Checking WSL")
    t.ok(f"WSL {v['wsl']}")
    t.step("Preparing the 'docker' WSL distro")
    t.out(f"    Downloading and installing {v['ubuntu']} as 'docker' (a few minutes)...", ms=900)
    t.ok("Distro 'docker' created", ms=300)
    t.step("Installing Docker Engine inside WSL")
    t.out("  [wsl] Configuring /etc/wsl.conf", ms=180)
    t.out("  [wsl] Installing socat", ms=250)
    t.out("  [wsl] Installing Docker Engine (official script from get.docker.com)", ms=1000)
    t.out(f"  [wsl] Installed: Docker version {v['docker']}{engine_build}", ms=200)
    t.out("  [wsl] Automatic updates enabled for Docker Engine", ms=150)
    t.out("  [wsl] Done", ms=150)
    t.out("    Restarting the distro so systemd and the new settings take effect...", ms=600)
    t.ok("Docker Engine is running inside WSL", ms=300)
    t.step("Installing the Docker CLI for Windows")
    t.ok(f"docker.exe {v['docker']} installed (official static build)", ms=300)
    t.ok(f"docker compose {v['compose']} installed (checksum verified)", ms=250)
    t.ok(f"docker buildx {v['buildx']} installed (checksum verified)", ms=250)
    t.step("Building the Docker pipe relay")
    t.ok("Relay built", ms=250)
    t.step("Configuring your user environment")
    t.ok("Added to your PATH", ms=150)
    t.ok("COMPOSE_CONVERT_WINDOWS_PATHS=1 (compose bind mounts like ./data work)", ms=150)
    t.ok("Starts automatically at sign-in", ms=200)
    t.step("Starting and testing")
    t.ok(f"docker.exe {v['docker']}  ->  Docker Engine {v['docker']}", ms=400)
    t.out("")
    t.out("Done!", GREEN, True, ms=1600)
    t.badge = None

    # 3. docker works
    t.type_cmd("docker --version", before=600)
    t.out(f"Docker version {v['docker']}{cli_build}", ms=1000)
    t.type_cmd("docker run --rm hello-world", before=500)
    t.out("Unable to find image 'hello-world:latest' locally", ms=250)
    t.out("latest: Pulling from library/hello-world", ms=450)
    t.out("Status: Downloaded newer image for hello-world:latest", ms=300)
    t.out("")
    t.out("Hello from Docker!", WHITE, True)
    t.out("This message shows that your installation appears to be working correctly.", ms=300)
    t.out("")
    t.lines.append([(PROMPT, FG, False)])
    t.snap(600)
    for _ in range(4):          # blinking cursor at the end
        t.snap(450, cursor=False)
        t.snap(450, cursor=True)
    t.snap(2500)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=os.path.join(ROOT, "docs", "demo.gif"))
    p.add_argument("--fonts", default=None)
    args = p.parse_args()

    versions = get_versions()
    print("versions:", json.dumps(versions))
    t = Terminal(get_fonts_dir(args.fonts))
    build(t, versions)
    t.save_gif(args.out)
    with open(os.path.join(os.path.dirname(args.out), "demo-versions.json"), "w", encoding="utf-8") as f:
        json.dump(versions, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{args.out}: {len(t.frames)} frames, {sum(ms for _, ms in t.frames) / 1000:.1f} s")


if __name__ == "__main__":
    sys.exit(main())
