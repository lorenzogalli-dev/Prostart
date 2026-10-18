# Recover starts whose sample stamps were shifted early by the FIFO-overwrite bug
# (fixed 2026-10-16): measure the shift two ways, write corrected copies, re-judge.
import sys, os, glob, io
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from start_detector import analyse
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
print(f"{'run':8s} {'board':>9s}  shift_set  shift_end  {'corrected':>10s}  verdict")
for f in sorted(glob.glob(src + '/nodate_r000[34]*.csv')):
    if 'r00035' in f: continue
    lines = open(f).read().splitlines()
    hdr = {l[2:].split(':')[0]: l.split(':', 1)[1].strip() for l in lines if l.startswith('# ') and ':' in l}
    rows = [l for l in lines if l and (l[0].isdigit() or l[0] == '-')]
    pre = int(hdr['preroll_samples']); set_us = int(hdr['set_t_us']); go_us = int(hdr['go_t_us'])
    tus = [int(r.split(',')[1]) for r in rows]
    sh_set = set_us - tus[pre] + 622            # first sample after set lands ~half a period after it
    sh_end = (go_us + 999_400) - tus[-1]        # clean files end at go + 999.0-1000.1 ms
    # Only when both measures agree: r00033 resynced mid-file (gap 1.35 s), its tail is right.
    sh = sh_set if abs(sh_set) > 3000 and abs(sh_set - sh_end) < 2000 else 0
    out = []
    for l in lines:
        if l and (l[0].isdigit() or l[0] == '-'):
            p = l.split(','); t = int(p[1]) + sh
            out.append(f"{(t - (tus[0] + sh)) / 1e6:.6f},{t},{p[2]},{p[3]},{p[4]}")
        elif l.startswith(('# on_t_s', '# set_t_s', '# go_t_s', '# arm_t_s')):
            k = l[2:].split(':')[0].replace('_t_s', '_t_us')
            out.append(f"# {l[2:].split(':')[0]}: {(int(hdr[k]) - (tus[0] + sh)) / 1e6:.6f}")
        elif l.startswith('# arm_'): continue   # the board armed on shifted data: re-derive
        else: out.append(l)
    g = os.path.join(dst, os.path.basename(f).replace('.csv', '_corrected.csv'))
    open(g, 'w').write("\n".join(out) + "\n")
    a = analyse(g, force_rearm=True)
    ev = a['events']; s = ev[0] if ev else None
    print(f"{os.path.basename(f)[7:13]:8s} {float(hdr['board_reaction_ms']):8.1f}  {sh_set/1e3:8.1f}  {sh_end/1e3:8.1f}  "
          f"{(s['reaction_ms'] if s else float('nan')):9.1f}  {s['verdict'] if s else 'none'}")
