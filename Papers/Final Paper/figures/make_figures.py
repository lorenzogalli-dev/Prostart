"""Figures for the final paper, built from the repository's own data.

Run from anywhere:  python3 "Papers/Final Paper/figures/make_figures.py"

  fig_esp32_start.pdf   a real block start on the ESP32 unit (08/10 capture)
  fig_error_scale.pdf   every timing error in the paper on one log axis
  fig_box.png           the 3D-printed enclosure, rendered from the STL files
  placeholder_*.png     slots for photos/data that arrive later
"""
import struct
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "Arduino/AlgorithmRealTimeESP32/Python_Tools"))
import start_detector as sd  # noqa: E402

# The paper's palette (elr-style.sty).
INK, MUTED, LINE = "#30363D", "#68717A", "#DDE3E8"
BLUE, CYAN, GOLD = "#163A63", "#137B76", "#B7924A"

plt.rcParams.update({
    "font.family": "serif", "font.size": 8, "axes.edgecolor": MUTED,
    "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": LINE, "grid.linewidth": 0.5,
    "lines.linewidth": 1.2, "savefig.bbox": "tight", "savefig.pad_inches": 0.02,
})


def fig_esp32_start():
    path = ROOT / ("Arduino/AlgorithmRealTimeESP32/Data/block_starts_081026/"
                   "accel_20261008_010908_0.164s.csv")
    r = sd.analyse(str(path))
    det, go = r["det"], r["markers"]["go_t_s"]
    ev = next(e for e in r["events"] if e["verdict"] == "valid start")
    t = (np.array(det.tr_t) - go) * 1000.0
    h = np.array(det.tr_horiz) * 1000.0
    ratio = np.array(det.tr_ratio)
    on, trig = (ev["t"] - go) * 1000.0, (ev["trigger_t"] - go) * 1000.0
    m = (t > -60) & (t < 260)

    fig, (a1, a2) = plt.subplots(2, 1, figsize=(3.3, 2.5), sharex=True,
                                 gridspec_kw=dict(height_ratios=[1.6, 1], hspace=0.12))
    a1.plot(t[m], h[m], color=BLUE)
    a1.set_ylabel("horizontal |a| (mg)")
    a2.plot(t[m], ratio[m], color=CYAN)
    a2.axhline(sd.DEF["ratio_on"], color=MUTED, lw=0.7, ls=":")
    a2.set_ylabel("STA/LTA")
    a2.set_xlabel("time after “go” (ms)")
    for a in (a1, a2):
        a.axvline(0, color=GOLD, lw=1.0)
        a.axvline(on, color=INK, lw=1.0)
        a.axvline(trig, color=MUTED, lw=0.8, ls="--")
    top = h[m].max()
    a1.text(2, top * 0.92, "go", color=GOLD, fontsize=7)
    a1.text(on - 3, top * 0.92, f"AIC onset\n{ev['reaction_ms']:.1f} ms",
            color=INK, fontsize=7, ha="right", va="top")
    a1.text(trig + 3, top * 0.55, f"trigger\n+{trig - on:.1f} ms", color=MUTED, fontsize=7)
    fig.savefig(HERE / "fig_esp32_start.pdf")
    plt.close(fig)
    print(f"esp32 start: RT {ev['reaction_ms']:.2f} ms, trigger {trig - on:+.2f} ms "
          f"after onset, odr {r['odr']:.1f} Hz")


def fig_error_scale():
    # (label, ms, group): R = reaction time, F = photo finish, ref = references.
    rows = [
        ("Hand timing vs. electronic", 240, "ref"),
        ("Design target: one frame at 30 fps", 33.3, "ref"),
        ("One frame at 60 fps", 16.7, "ref"),
        ("Photo finish vs. 60 fps video", 10, "F"),
        ("Reaction time vs. 240 fps video", 8, "R"),
        ("One frame at 240 fps", 4.2, "ref"),
        ("One accelerometer sample (804 Hz)", 1.24, "R"),
    ]
    col = {"ref": MUTED, "R": BLUE, "F": CYAN}
    fig, ax = plt.subplots(figsize=(3.3, 2.0))
    y = np.arange(len(rows))[::-1]
    for yi, (lab, v, g) in zip(y, rows):
        ax.hlines(yi, 0.8, v, color=LINE, lw=1.0)
        ax.plot(v, yi, "o", ms=6 if g != "ref" else 4.5, color=col[g],
                mec="white", mew=0.8, zorder=3)
        ax.text(v * 1.18, yi, f"{v:g} ms", va="center", fontsize=7, color=INK)
    ax.set_yticks(y, [r[0] for r in rows], fontsize=7)
    ax.set_xscale("log")
    ax.set_xlim(0.8, 900)
    ax.set_xticks([1, 10, 100], ["1 ms", "10 ms", "100 ms"])
    ax.grid(axis="y", visible=False)
    ax.tick_params(axis="y", length=0)
    for lab, c in (("measured, reaction", BLUE), ("measured, finish", CYAN),
                   ("reference", MUTED)):
        ax.plot([], [], "o", color=c, label=lab, ms=4.5)
    ax.legend(loc="lower right", fontsize=6.5, frameon=False, handletextpad=0.2)
    fig.savefig(HERE / "fig_error_scale.pdf")
    plt.close(fig)


def read_stl(path):
    data = Path(path).read_bytes()
    n = struct.unpack("<I", data[80:84])[0]
    rec = np.frombuffer(data[84:84 + 50 * n], dtype=np.dtype(
        [("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]))
    v = rec["v"].astype(float)
    return v * 1000.0 if np.ptp(v) < 1.0 else v  # exported in metres


def _rot(tri, deg):
    c, s = np.cos(np.radians(deg)), np.sin(np.radians(deg))
    return tri @ np.array([[c, s, 0], [-s, c, 0], [0, 0, 1]])


def _raster(parts, azim=-50, elev=28, W=1600, H=1200):
    """Orthographic z-buffer render, flat shading, outlines from depth/normal
    breaks. matplotlib's 3D painter sorts whole polygons and garbles meshes."""
    az, el = np.radians(azim), np.radians(elev)
    Rz = np.array([[np.cos(az), -np.sin(az), 0], [np.sin(az), np.cos(az), 0], [0, 0, 1]])
    Rx = np.array([[1, 0, 0], [0, np.cos(el), -np.sin(el)], [0, np.sin(el), np.cos(el)]])
    # camera: looking down -y after rotation -> screen x = X, screen y = Z, depth = Y
    R = Rx @ Rz
    allv = np.concatenate([p[0] for p in parts]).reshape(-1, 3) @ R.T
    lo, hi = allv.min(0), allv.max(0)
    scale = 0.9 * min(W / (hi[0] - lo[0]), H / (hi[2] - lo[2]))
    off = np.array([W / 2, H / 2]) - scale * np.array([(lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2])
    img = np.ones((H, W, 3)); zb = np.full((H, W), np.inf); nimg = np.zeros((H, W, 3))
    light = np.array([-0.35, -0.6, 0.72]); light /= np.linalg.norm(light)
    fid = 0
    for tri, rgb in parts:
        n = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
        shade = 0.38 + 0.62 * np.abs(n @ light)
        v = tri @ R.T
        sx = v[..., 0] * scale + off[0]
        sy = H - (v[..., 2] * scale + off[1])
        dz = v[..., 1]
        for i in range(len(tri)):
            fid += 1
            x0, x1 = int(max(sx[i].min(), 0)), int(min(np.ceil(sx[i].max()), W - 1))
            y0, y1 = int(max(sy[i].min(), 0)), int(min(np.ceil(sy[i].max()), H - 1))
            if x1 < x0 or y1 < y0:
                continue
            X, Y = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
            (ax_, bx, cx), (ay, by, cy) = sx[i], sy[i]
            d = (by - cy) * (ax_ - cx) + (cx - bx) * (ay - cy)
            if abs(d) < 1e-9:
                continue
            w0 = ((by - cy) * (X - cx) + (cx - bx) * (Y - cy)) / d
            w1 = ((cy - ay) * (X - cx) + (ax_ - cx) * (Y - cy)) / d
            w2 = 1 - w0 - w1
            inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
            z = w0 * dz[i, 0] + w1 * dz[i, 1] + w2 * dz[i, 2]
            sub = zb[y0:y1 + 1, x0:x1 + 1]
            win = inside & (z < sub)
            sub[win] = z[win]
            img[y0:y1 + 1, x0:x1 + 1][win] = np.array(rgb) * shade[i]
            nimg[y0:y1 + 1, x0:x1 + 1][win] = n[i]
    # outlines where depth jumps or the face orientation changes
    edge = np.zeros((H, W), bool)
    zf = np.where(np.isinf(zb), 1e6, zb)
    for axis in (0, 1):
        edge |= np.abs(np.diff(zf, axis=axis, prepend=zf[:1] if axis == 0 else zf[:, :1])) > 0.8
        sh = np.roll(nimg, 1, axis=axis)
        both = np.isfinite(zb) & np.isfinite(np.roll(zb, 1, axis=axis))
        edge |= both & (np.abs((nimg * sh).sum(2)) < 0.94)  # creases, not facets
    img[edge] *= 0.35
    return img


def fig_box():
    enc = ROOT / "Hardware/Enclosure"
    box = read_stl(enc / "start_box.stl")
    lid = _rot(read_stl(enc / "start_box_lid.stl"), 90)
    btn = read_stl(enc / "start_box_button.stl")
    c = box.reshape(-1, 3)
    cx, cy = (c[:, 0].min() + c[:, 0].max()) / 2, (c[:, 1].min() + c[:, 1].max()) / 2
    lv = lid.reshape(-1, 3)
    lid = lid - [(lv[:, 0].min() + lv[:, 0].max()) / 2 - cx,
                 (lv[:, 1].min() + lv[:, 1].max()) / 2 - cy,
                 lv[:, 2].min() - c[:, 2].max() - 30]
    btn = btn + [cx * 0.4, -18, 0]  # in front of the box
    img = _raster([(box, (0.30, 0.44, 0.58)), (lid, (0.80, 0.82, 0.84)),
                   (btn, (0.78, 0.62, 0.32))])
    rows, cols = np.where(img.min(2) < 0.999)
    img = img[rows.min() - 10:rows.max() + 10, cols.min() - 10:cols.max() + 10]
    plt.imsave(HERE / "fig_box.png", np.clip(img, 0, 1))
    print("box size (mm):", np.round(np.ptp(c, axis=0), 1))


def placeholder(name, text, aspect=(4, 3)):
    fig, ax = plt.subplots(figsize=aspect)
    ax.set_facecolor("#F6F8FA")
    ax.text(0.5, 0.5, "PLACEHOLDER\n\n" + text, ha="center", va="center",
            fontsize=9, color=MUTED, transform=ax.transAxes, family="sans-serif")
    ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
    for sp in ax.spines.values():
        sp.set_visible(True); sp.set_color(GOLD); sp.set_linestyle("--")
    fig.savefig(HERE / name, dpi=150)
    plt.close(fig)


if __name__ == "__main__":
    fig_esp32_start()
    fig_error_scale()
    fig_box()
    placeholder("placeholder_validation.png",
                "Reaction time: board vs. 240 fps video\n"
                "one point per start (Bland-Altman)\n"
                "LED frame = go, first visible push = onset")
    placeholder("placeholder_finished_unit.png",
                "Photo:\nfinished unit\non the block\n(PCB in the\nprinted box)", aspect=(3, 4))
    placeholder("placeholder_app.png",
                "App screenshots (iPhone 13):\nreaction result, photo-finish\n"
                "result frame with line and chest point", aspect=(4, 3))
    placeholder("placeholder_pcb_photo.png", "Photo: assembled PCB")
    placeholder("placeholder_finish_frame.png",
                "App result frame at the crossing:\nfinish line, cyan silhouette,\n"
                "timed chest point")
