#!/usr/bin/env python3
"""Builds GrappleMod.pk3.

  GRAPPLE1  small test yard (door, switch, platforms)
  GRAPPLE2  four-lane speedway: a big stadium-shaped loop, 2 m walls, open sky
  sprites   rope bead + 8-angle traffic car sprites in four colors

Run from the repo root:  python3 build.py
Set CAR_PREVIEW=/path/preview.png to also save a contact sheet of the car sprites.
"""
import io
import math
import os
import re
import struct
import sys
import zipfile

from PIL import Image, ImageDraw

SRC = "grapple_mod"
os.makedirs(f"{SRC}/sprites", exist_ok=True)
os.makedirs(f"{SRC}/maps", exist_ok=True)

# --------------------------------------------------------------------------
# Track constants. These MUST match TrackGeom in grapple_mod/traffic.zs
# (checked below), because the cars compute their lane positions from them.
# 32 map units = 1 meter.
# --------------------------------------------------------------------------
TRACK = dict(TRK_S=6000.0, TRK_R=2400.0,
             TRK_LANE0=192.0, TRK_LANE1=64.0, TRK_LANE2=-64.0, TRK_LANE3=-192.0)
TRK_S, TRK_R = TRACK["TRK_S"], TRACK["TRK_R"]


def check_track_constants():
    text = open(f"{SRC}/traffic.zs").read()
    found = {m.group(1): float(m.group(2))
             for m in re.finditer(r"const\s+(TRK_\w+)\s*=\s*(-?[\d.]+)\s*;", text)}
    for k, v in TRACK.items():
        assert found.get(k) == v, f"{k}: build.py has {v}, traffic.zs has {found.get(k)}"
    print("track constants match traffic.zs")


# --------------------------------------------------------------------------
# PNG / WAD helpers
# --------------------------------------------------------------------------
def chunk(t, d):
    import zlib
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)


def png_with_grab(img, gx, gy):
    """PNG bytes with a grAb chunk (sprite offset) inserted right after IHDR."""
    buf = io.BytesIO()
    img.save(buf, "PNG")
    raw = buf.getvalue()
    return raw[:33] + chunk(b"grAb", struct.pack(">ii", gx, gy)) + raw[33:]


def wad(lumps):
    data, d, pos = b"", b"", 12
    for name, content in lumps:
        d += struct.pack("<ii8s", pos + len(data), len(content), name.encode().ljust(8, b"\0"))
        data += content
    return b"PWAD" + struct.pack("<ii", len(lumps), 12 + len(data)) + data + d


# --------------------------------------------------------------------------
# Sprites
# --------------------------------------------------------------------------
def make_rope_bead():
    img = Image.new("RGBA", (8, 8), (0, 0, 0, 0))
    px = img.load()
    for y in range(8):
        for x in range(8):
            r = ((x - 3.5) ** 2 + (y - 3.5) ** 2) ** 0.5
            if r <= 3.8:
                px[x, y] = (255, 255, 255, 255) if r < 2 else (110, 220, 255, 255)
    open(f"{SRC}/sprites/ROPEA0.png", "wb").write(png_with_grab(img, 4, 4))


# Car geometry in map units: x forward, y left, z up. Drawn at 2 px per unit and
# shown at Scale 0.5, so the car is 144 x 64 x 40 units (4.5 x 2 x 1.25 m).
CAR_W, CAR_H = 320, 120
CAR_ORIGIN = (160, 104)      # pixel that sits on the ground under the car's center
PX_PER_UNIT = 2
SS = 4                       # supersampling for smooth edges
CAR_COLORS = {"R": (205, 38, 38), "B": (46, 92, 210), "Y": (225, 190, 40), "G": (48, 165, 70)}
GLASS = (28, 36, 48)
RUBBER = (18, 18, 20)


def box_faces(x0, x1, y0, y1, z0, z1, side_col, top_col=None):
    top_col = top_col or side_col
    f = [
        ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], (1, 0, 0), side_col),
        ([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], (-1, 0, 0), side_col),
        ([(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], (0, 1, 0), side_col),
        ([(x1, y0, z0), (x0, y0, z0), (x0, y0, z1), (x1, y0, z1)], (0, -1, 0), side_col),
        ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (0, 0, 1), top_col),
    ]
    return f


def car_faces(body):
    faces = []
    for sy in (1, -1):                       # wheels first (drawn order is by depth anyway)
        for sx in (1, -1):
            cy = sy * 30
            faces += box_faces(sx * 46 - 14, sx * 46 + 14, cy - 5, cy + 5, 0, 22, RUBBER)
    faces += box_faces(-72, 72, -32, 32, 6, 24, body)
    faces += box_faces(-38, 34, -28, 28, 24, 40, GLASS, body)
    for sy in (1, -1):                       # headlights front, taillights back
        faces += box_faces(71, 73.5, sy * 18 - 8, sy * 18 + 8, 11, 18, (255, 240, 150))
        faces += box_faces(-73.5, -71, sy * 18 - 8, sy * 18 + 8, 11, 18, (210, 20, 20))
    return faces


def render_car(rot, body):
    """Sprite rotation rot (1..8): viewer stands at (rot-1)*45 degrees CCW from the car's front."""
    th = math.radians((rot - 1) * 45.0)
    lx, ly = -math.cos(th), -math.sin(th)    # horizontal looking direction
    rx, ry = -math.sin(th), math.cos(th)     # viewer's right
    el = math.radians(6.0)                   # slight look-down
    cam = (-lx * math.cos(el), -ly * math.cos(el), math.sin(el))
    lt = (cam[0], cam[1], cam[2] + 0.7)
    ln = math.sqrt(sum(c * c for c in lt))
    lt = tuple(c / ln for c in lt)

    vis = []
    for pts, n, col in car_faces(body):
        if sum(a * b for a, b in zip(n, cam)) <= 0.01:
            continue
        cx = sum(p[0] for p in pts) / len(pts)
        cy = sum(p[1] for p in pts) / len(pts)
        vis.append((cx * lx + cy * ly, pts, n, col))
    vis.sort(key=lambda v: -v[0])            # far faces first

    img = Image.new("RGBA", (CAR_W * SS, CAR_H * SS), (0, 0, 0, 0))
    dr = ImageDraw.Draw(img)
    for _, pts, n, col in vis:
        shade = 0.45 + 0.55 * max(0.0, sum(a * b for a, b in zip(n, lt)))
        rgb = tuple(min(255, int(c * shade)) for c in col)
        poly = []
        for (x, y, z) in pts:
            sx = CAR_ORIGIN[0] * SS + (x * rx + y * ry) * PX_PER_UNIT * SS
            up = z * math.cos(el) + (x * lx + y * ly) * math.sin(el)
            sy = CAR_ORIGIN[1] * SS - up * PX_PER_UNIT * SS
            poly.append((sx, sy))
        dr.polygon(poly, fill=rgb + (255,))
    return img.resize((CAR_W, CAR_H), Image.LANCZOS)


def make_car_sprites():
    sheet = Image.new("RGBA", (CAR_W * 4, CAR_H * 2 * len(CAR_COLORS)), (60, 60, 60, 255))
    for ci, (letter, rgb) in enumerate(CAR_COLORS.items()):
        for rot in range(1, 9):
            img = render_car(rot, rgb)
            name = f"CAR{letter}A{rot}"
            open(f"{SRC}/sprites/{name}.png", "wb").write(
                png_with_grab(img, CAR_ORIGIN[0], CAR_ORIGIN[1]))
            sheet.paste(img, (((rot - 1) % 4) * CAR_W, ci * CAR_H * 2 + ((rot - 1) // 4) * CAR_H), img)
    prev = os.environ.get("CAR_PREVIEW")
    if prev:
        sheet.save(prev)
        print("car preview saved to", prev)


# --------------------------------------------------------------------------
# UDMF map builder. Each region is described by directed edges: the sector to
# the RIGHT of an edge (a -> b) is its front side. Edges present in both
# directions become two-sided lines; edges with no partner are one-sided walls.
# --------------------------------------------------------------------------
class Map:
    def __init__(self):
        self.sectors, self.edges = [], {}
        self.specials, self.override, self.things = {}, {}, []

    def S(self, f, c, light=192, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3", tag=0):
        self.sectors.append(dict(f=f, c=c, light=light, ftex=ftex, ctex=ctex, wall=wall, tag=tag))
        return len(self.sectors) - 1

    @staticmethod
    def k(p):
        return (round(p[0], 3), round(p[1], 3))

    def poly(self, sec, pts):
        """pts clockwise: sec is inside."""
        pts = [self.k(p) for p in pts]
        for i in range(len(pts)):
            self.edges[(pts[i], pts[(i + 1) % len(pts)])] = sec

    def rev(self, sec, pts):
        """Same clockwise pts, but sec is OUTSIDE them (the far side of a hole)."""
        pts = [self.k(p) for p in pts]
        for i in range(len(pts)):
            self.edges[(pts[(i + 1) % len(pts)], pts[i])] = sec

    def box(self, sec, x1, y1, x2, y2, parent):
        pts = [(x1, y1), (x1, y2), (x2, y2), (x2, y1)]
        self.poly(sec, pts)
        self.rev(parent, pts)

    def textmap(self, label):
        special_edges = {k for k, v in self.specials.items() if "special" in v}
        verts, vidx, sides, lines, done = [], {}, [], [], set()

        def vid(p):
            if p not in vidx:
                vidx[p] = len(verts)
                verts.append(p)
            return vidx[p]

        def side(sec, two, ov):
            w = self.sectors[sec]["wall"]
            sides.append(dict(sector=sec, texturetop=ov.get("texturetop", w),
                              texturebottom=ov.get("texturebottom", w),
                              texturemiddle="-" if two else ov.get("texturemiddle", w)))
            return len(sides) - 1

        one_sided = 0
        for key in list(self.edges):
            if key in done:
                continue
            a, b = key
            if (b, a) in self.edges:
                if (b, a) in special_edges and (a, b) not in special_edges:
                    a, b = b, a
                done.update([(a, b), (b, a)])
                two = True
            else:
                done.add(key)
                two = False
                one_sided += 1
            ov = self.override.get((a, b), {})
            front = side(self.edges[(a, b)], two, ov)
            back = side(self.edges[(b, a)], two, {}) if two else None
            lines.append(dict(v1=vid(a), v2=vid(b), front=front, back=back, two=two,
                              props=self.specials.get((a, b), {})))

        for si in range(len(self.sectors)):          # every sector boundary must close
            deg = {}
            for (a, b), s in self.edges.items():
                if s == si:
                    deg[a] = deg.get(a, 0) + 1
                    deg[b] = deg.get(b, 0) - 1
            assert all(v == 0 for v in deg.values()), f"{label}: sector {si} is not closed"
        print(f"{label}: {len(self.sectors)} sectors closed OK, {len(lines)} linedefs "
              f"({one_sided} one-sided), {len(verts)} vertices, {len(self.things)} things")

        def b_(v):
            return "true" if v else "false"

        out = ['namespace = "zdoom";']
        for x, y in verts:
            out.append(f"vertex {{ x = {x:.3f}; y = {y:.3f}; }}")
        for l in lines:
            s = f"linedef {{ v1 = {l['v1']}; v2 = {l['v2']}; sidefront = {l['front']};"
            if l["two"]:
                s += f" sideback = {l['back']}; twosided = true;"
            else:
                s += " blocking = true;"
            for k, v in l["props"].items():
                s += f" {k} = {b_(v) if isinstance(v, bool) else v};"
            out.append(s + " }")
        for sd in sides:
            out.append(f'sidedef {{ sector = {sd["sector"]}; texturetop = "{sd["texturetop"]}"; '
                       f'texturebottom = "{sd["texturebottom"]}"; texturemiddle = "{sd["texturemiddle"]}"; }}')
        for sc in self.sectors:
            s = (f'sector {{ heightfloor = {sc["f"]}; heightceiling = {sc["c"]}; '
                 f'texturefloor = "{sc["ftex"]}"; textureceiling = "{sc["ctex"]}"; lightlevel = {sc["light"]};')
            if sc["tag"]:
                s += f" id = {sc['tag']};"
            out.append(s + " }")
        for th in self.things:
            x, y, ang, typ = th[:4]
            extra = "".join(f" {k} = {v};" for k, v in (th[4] if len(th) > 4 else {}).items())
            out.append(f"thing {{ x = {x}.0; y = {y}.0; angle = {ang}; type = {typ};{extra} "
                       "skill1 = true; skill2 = true; skill3 = true; skill4 = true; skill5 = true; "
                       "single = true; coop = true; dm = true; }")
        return "\n".join(out).encode()


def write_map(lump, filename, m):
    open(f"{SRC}/maps/{filename}", "wb").write(
        wad([(lump, b""), ("TEXTMAP", m.textmap(lump)), ("ENDMAP", b"")]))


# --------------------------------------------------------------------------
# GRAPPLE1: the original test yard
# --------------------------------------------------------------------------
def build_map1():
    m = Map()
    S, poly, box = m.S, m.poly, m.box

    hall = S(0, 384, 176)
    alcW = S(0, 72, 160, wall="STARTAN3")
    vestE = S(0, 128, 160)
    doorE = S(0, 0, 160, wall="DOORTRAK")
    corr = S(0, 128, 144)
    roomB = S(0, 256, 176)
    vestN = S(0, 128, 160)
    gate = S(0, 0, 160, wall="DOORTRAK", tag=1)
    alcN = S(0, 128, 144)

    poly(hall, [(0, 0), (0, 480), (0, 544), (0, 1024), (448, 1024), (576, 1024),
                (1024, 1024), (1024, 576), (1024, 448), (1024, 0)])
    poly(alcW, [(0, 544), (0, 480), (-32, 480), (-32, 544)])
    poly(vestE, [(1024, 576), (1088, 576), (1088, 448), (1024, 448)])
    poly(doorE, [(1088, 576), (1120, 576), (1120, 448), (1088, 448)])
    poly(corr, [(1120, 576), (1376, 576), (1376, 448), (1120, 448)])
    poly(roomB, [(1376, 320), (1376, 448), (1376, 576), (1376, 704), (1792, 704), (1792, 320)])
    poly(vestN, [(576, 1024), (448, 1024), (448, 1088), (576, 1088)])
    poly(gate, [(576, 1088), (448, 1088), (448, 1120), (576, 1120)])
    poly(alcN, [(576, 1120), (448, 1120), (448, 1376), (576, 1376)])

    padA = S(64, 384, 208); box(padA, 256, 256, 384, 384, hall)
    padB = S(128, 384, 208); box(padB, 512, 256, 640, 384, hall)
    padC = S(192, 384, 208); box(padC, 768, 256, 896, 384, hall)
    tower = S(256, 384, 208); box(tower, 448, 640, 576, 768, hall)
    pillB1 = S(160, 256, 208); box(pillB1, 1536, 448, 1632, 544, roomB)
    pillB2 = S(96, 256, 208); box(pillB2, 1700, 600, 1764, 664, roomB)

    east = ((1088, 576), (1088, 448))
    m.specials[east] = dict(special=12, arg0=0, arg1=16, arg2=105,
                            playeruse=True, repeatspecial=True, dontpegtop=True)
    m.override[east] = dict(texturetop="BIGDOOR2")
    gateline = ((448, 1088), (576, 1088))
    m.override[gateline] = dict(texturetop="BIGDOOR2")
    m.specials[gateline] = dict(dontpegtop=True)
    sw = ((-32, 480), (-32, 544))
    m.specials[sw] = dict(special=12, arg0=1, arg1=16, arg2=105,
                          playeruse=True, repeatspecial=True)
    m.override[sw] = dict(texturemiddle="SW1BRCOM")

    m.things = [
        (128, 128, 45, 1), (200, 200, 0, 2001), (232, 200, 0, 2008), (352, 100, 0, 2012),
        (700, 700, 225, 3004), (820, 520, 180, 3004), (300, 800, 270, 3001),
        (500, 1250, 270, 2012), (1500, 400, 180, 2008),
        (800, 800, 225, 30002), (200, 900, 270, 30002),     # cluster demons
    ]
    return m


# --------------------------------------------------------------------------
# GRAPPLE2: the speedway
#
# A stadium shape (two straights joined by two semicircles) around the origin.
# The median is at radius TRK_R; offsets are measured outward from it. Four
# lanes: +192 and +64 carry traffic counter-clockwise, -64 and -192 clockwise.
# The road is 512 units (16 m) wide, edged by 2 m (64 unit) walls that are just
# the step up to the infield and the outside, all under open sky.
# --------------------------------------------------------------------------
ARC_STEPS = 48
OUTER_X = TRK_S / 2 + TRK_R + 256 + 800
OUTER_Y = TRK_R + 256 + 800


def stadium(off, n=ARC_STEPS):
    """Counter-clockwise outline of the loop at lateral offset `off` from the median."""
    r = TRK_R + off
    pts = []
    for k in range(n + 1):                       # right semicircle, bottom to top
        a = math.radians(-90 + 180.0 * k / n)
        pts.append((TRK_S / 2 + r * math.cos(a), r * math.sin(a)))
    for k in range(n + 1):                       # left semicircle, top to bottom
        a = math.radians(90 + 180.0 * k / n)
        pts.append((-TRK_S / 2 + r * math.cos(a), r * math.sin(a)))
    return pts


def build_map2():
    m = Map()
    sky = "F_SKY1"
    OUT = dict(ctex=sky, light=224)
    outside = m.S(64, 1024, ftex="FLOOR5_3", wall="STONE2", **OUT)
    laneA = m.S(0, 1024, ftex="FLAT1", wall="GRAY1", **OUT)
    whiteA = m.S(0, 1024, ftex="AQF062", wall="GRAY1", **OUT)
    laneB = m.S(0, 1024, ftex="FLAT1", wall="GRAY1", **OUT)
    yellow = m.S(0, 1024, ftex="AQF043", wall="GRAY1", **OUT)
    laneC = m.S(0, 1024, ftex="FLAT1", wall="GRAY1", **OUT)
    whiteB = m.S(0, 1024, ftex="AQF062", wall="GRAY1", **OUT)
    laneD = m.S(0, 1024, ftex="FLAT1", wall="GRAY1", **OUT)
    infield = m.S(64, 1024, ftex="FLOOR7_2", wall="GRAY1", **OUT)
    secs = [outside, laneA, whiteA, laneB, yellow, laneC, whiteB, laneD, infield]

    # Loop outlines from the outside in: road edge, white line, yellow center line, white line, road edge.
    offs = [256, 131, 125, 4, -4, -125, -131, -256]
    for i, off in enumerate(offs):
        cw = stadium(off)[::-1]
        m.poly(secs[i + 1], cw)      # inside this loop
        m.rev(secs[i], cw)           # outside this loop

    # World boundary: one-sided walls, outside sector on the inside.
    m.poly(outside, [(-OUTER_X, -OUTER_Y), (-OUTER_X, OUTER_Y),
                     (OUTER_X, OUTER_Y), (OUTER_X, -OUTER_Y)])

    # Pylons: tall columns that give the hook something to grab above wall height.
    # Each rises from the infield or outside floor (64) to 448 (top is 12 m up).
    pylons = []
    for x in range(-2500, 2501, 1250):
        pylons.append((x, 1850, infield))
        pylons.append((x, -1850, infield))
        pylons.append((x, 2960, outside))
        pylons.append((x, -2960, outside))
    for px, py, parent in pylons:
        pyl = m.S(448, 1024, ftex="FLAT23", wall="SUPPORT2", **OUT)
        m.box(pyl, px - 64, py - 64, px + 64, py + 64, parent)

    m.things = [
        (0, int(-(TRK_R + 64)), 0, 1),                          # player start, lane +64
        (260, int(-(TRK_R + 64)), 0, 2001), (300, int(-(TRK_R + 64)), 0, 2008),
        (340, int(-(TRK_R + 64)), 0, 2012),                     # shotgun, shells, medikit on the road
        (0, 0, 0, 30001, {"arg0": 12}),                         # traffic spawner: 12 cars per lane
        (500, 0, 0, 2012), (0, 500, 0, 2018), (0, -500, 0, 2008),   # infield goodies (hook over the wall)
        (2000, 0, 0, 2012), (-2000, 0, 0, 2008),
        (600, 3000, 0, 2019), (-3000, -3000, 0, 2012),          # outside the loop
        (1500, 800, 0, 30002), (-1500, -800, 0, 30002), (0, 3200, 0, 30002),   # cluster demons
    ]
    return m


# --------------------------------------------------------------------------
# Static checks on the ZScript (there is no compiler here)
# --------------------------------------------------------------------------
RESERVED = set("""stop loop fail wait goto spawn see melee missile pain death xdeath raise heal crash
crush state states default class struct enum const static native virtual override abstract play ui
clearscope action readonly transient deprecated version return if else for while do switch case break
continue new delete null true false self super sizeof alignof is out in array map user private protected
vararg name string bool int uint byte sbyte short ushort float double vector2 vector3 vector4 color sound
textureid let var void char level players random frandom min max abs clamp
speed health target master tracer special args pitch roll pos vel radius height mass damage score tag
floorz ceilingz scale alpha gravity threshold reactiontime accuracy stamina""".split())


def lint_zscript():
    problems = []
    for fn in sorted(os.listdir(SRC)):
        if not fn.endswith(".zs"):
            continue
        text = open(f"{SRC}/{fn}").read()
        code = re.sub(r"//[^\n]*", "", text)
        code = re.sub(r'"[^"\n]*"', '""', code)
        for a, b in (("(", ")"), ("{", "}"), ("[", "]")):
            if code.count(a) != code.count(b):
                problems.append(f"{fn}: unbalanced {a}{b} ({code.count(a)} vs {code.count(b)})")
        decl = re.compile(r"\b(?:int|uint|double|bool|name|string|vector2|vector3|Actor|Sector|Line|"
                          r"TrafficCar|TrafficSpawner|TrackGeom|FLineTraceData|class<\w+>|Array<\w+>)\s+"
                          r"([A-Za-z_]\w*)\b")
        for mm in decl.finditer(code):
            if mm.group(1).lower() in RESERVED:
                line = code[:mm.start()].count("\n") + 1
                problems.append(f"{fn}:{line}: identifier '{mm.group(1)}' is reserved or shadows an Actor member")
    if problems:
        print("\n".join(problems))
        sys.exit("ZScript lint failed")
    print("zscript lint OK")


# --------------------------------------------------------------------------
if __name__ == "__main__":
    check_track_constants()
    lint_zscript()
    make_rope_bead()
    make_car_sprites()
    write_map("GRAPPLE1", "grapple1.wad", build_map1())
    write_map("GRAPPLE2", "grapple2.wad", build_map2())

    with zipfile.ZipFile("GrappleMod.pk3", "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(SRC):
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, SRC))
    print("wrote GrappleMod.pk3")
