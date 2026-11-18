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
CAR_COLORS = {"R": (205, 38, 38), "B": (46, 92, 210), "Y": (225, 190, 40), "G": (48, 165, 70), "K": (52, 52, 64)}
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


def stadium_world(m):
    """The ring road, infield, outside and world boundary shared by GRAPPLE2 and GRAPPLE3."""
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
    return outside, infield, OUT


def add_pylons(m, outside, infield, OUT):
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


def add_exit_room(m, outside, locked):
    """Exit room in the top-left outside corner. One-sided walls all round (a gap of void),
    so the door is the only way in. locked=True: a blue-keycard door (GRAPPLE2).
    locked=False: a closed door with sector tag 10 that the wave director opens (GRAPPLE3)."""
    room = m.S(64, 224, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    door = m.S(64, 64, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="DOORTRAK", tag=0 if locked else 10)
    m.poly(room, [(-6268, 2532), (-6268, 2820), (-6268, 2980), (-6268, 3268),
                  (-5564, 3268), (-5564, 2980), (-5564, 2820), (-5564, 2532)])
    m.poly(door, [(-5564, 2820), (-5564, 2980), (-5500, 2980), (-5500, 2820)])
    m.rev(outside, [(-6300, 2500), (-6300, 3300), (-5500, 3300),
                    (-5500, 2980), (-5500, 2820), (-5500, 2500)])
    door_line = ((-5500, 2820), (-5500, 2980))
    if locked:
        m.specials[door_line] = dict(special=13, arg0=0, arg1=16, arg2=105, arg3=2,   # Door_LockedRaise, lock 2 = blue card
                                     playeruse=True, repeatspecial=True, dontpegtop=True)
        m.override[door_line] = dict(texturetop="DOORBLU")
    else:
        m.specials[door_line] = dict(dontpegtop=True)
        m.override[door_line] = dict(texturetop="BIGDOOR2")
    exit_line = ((-6268, 2820), (-6268, 2980))
    m.specials[exit_line] = dict(special=243, arg0=0, playeruse=True)            # Exit_Normal
    m.override[exit_line] = dict(texturemiddle="SW1EXIT")


def build_map2():
    m = Map()
    outside, infield, OUT = stadium_world(m)
    add_pylons(m, outside, infield, OUT)
    add_exit_room(m, outside, True)

    m.things = [
        (0, int(-(TRK_R + 64)), 0, 1),                          # player start, lane +64
        (260, int(-(TRK_R + 64)), 0, 2001), (300, int(-(TRK_R + 64)), 0, 2008),
        (340, int(-(TRK_R + 64)), 0, 2012),                     # shotgun, shells, medikit on the road
        (0, 0, 0, 30001, {"arg0": 12}),                         # traffic spawner: 12 cars per lane
        (0, 0, 0, 5),                                           # blue keycard, center of the infield (hook over the wall)
        (-5900, 2900, 0, 2012),                                 # medikit in the exit room
        (500, 0, 0, 2012), (0, 500, 0, 2018), (0, -500, 0, 2008),   # infield goodies (hook over the wall)
        (2000, 0, 0, 2012), (-2000, 0, 0, 2008),
        (600, 3000, 0, 2019), (-3000, -3000, 0, 2012),          # outside the loop
        (1500, 800, 0, 30002), (-1500, -800, 0, 30002), (0, 3200, 0, 30002),   # cluster demons
        (3000, 800, 180, 30003), (-2500, -800, 0, 30003),   # leaper mancubi
        (-1800, 2400, 0, 30004), (1800, 2400, 180, 30004), (5350, 100, 90, 30004),   # ram cars
    ]
    return m


# --------------------------------------------------------------------------
# GRAPPLE3: the town. The same ring road as the speedway, with a town of buildings in the
# infield, beacon towers at the five wave zones, and an exit room that opens after wave 5.
# --------------------------------------------------------------------------
def add_building(m, parent, x, y, W, Dp, H, facade, rot=0, fl=64, doorhalf=48):
    """A walk-in building: a solid block (roof at height H, reachable by hooking its wall
    near the top) with a hollow room inside and a doorway. rot = 0..3 turns the doorway
    from the south wall counter-clockwise by 90 degrees each step. fl = the parent's floor."""
    T = 64
    OUT = dict(ctex="F_SKY1", light=224)
    I = m.S(fl, fl + 160, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    D = m.S(fl, fl + 96, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    cu, cv = W / 2.0, Dp / 2.0

    def tr(u, v):
        du, dv = u - cu, v - cv
        for _ in range(rot % 4):
            du, dv = -dv, du
        return (int(round(x + cu + du)), int(round(y + cv + dv)))

    def rect(u1, v1, u2, v2):
        p, q = tr(u1, v1), tr(u2, v2)
        return (min(p[0], q[0]), min(p[1], q[1]), max(p[0], q[0]), max(p[1], q[1]))

    def R():
        return m.S(H, 1024, ftex="FLAT1", wall=facade, **OUT)

    du1, du2 = W // 2 - doorhalf, W // 2 + doorhalf
    local = [
        (R(), 0, 0, du1, T), (R(), du2, 0, W, T),
        (R(), 0, T, T, Dp), (R(), W - T, T, W, Dp),
        (R(), T, Dp - T, W - T, Dp),
        (I, T, T, W - T, Dp - T), (D, du1, 0, du2, T),
    ]
    rects = [(sec,) + rect(u1, v1, u2, v2) for sec, u1, v1, u2, v2 in local]
    foot = rect(0, 0, W, Dp)
    verts = set()
    for _, x1, y1, x2, y2 in rects:
        verts.update([(x1, y1), (x1, y2), (x2, y2), (x2, y1)])
    fx1, fy1, fx2, fy2 = foot
    verts.update([(fx1, fy1), (fx1, fy2), (fx2, fy2), (fx2, fy1)])

    def with_inserts(pts):
        out = []
        for i, p in enumerate(pts):
            q = pts[(i + 1) % len(pts)]
            out.append(p)
            between = [v for v in verts if v != p and v != q and (
                (v[0] == p[0] == q[0] and min(p[1], q[1]) < v[1] < max(p[1], q[1])) or
                (v[1] == p[1] == q[1] and min(p[0], q[0]) < v[0] < max(p[0], q[0])))]
            between.sort(key=lambda v: abs(v[0] - p[0]) + abs(v[1] - p[1]))
            out += between
        return out

    # the hole in the parent first, so the parent's side of each line is the one that
    # gets the facade texture
    outline = with_inserts([(fx1, fy1), (fx1, fy2), (fx2, fy2), (fx2, fy1)])
    m.rev(parent, outline)
    for i, p in enumerate(outline):
        q = outline[(i + 1) % len(outline)]
        m.override[(m.k(q), m.k(p))] = dict(texturebottom=facade, texturetop=facade)
    for sec, x1, y1, x2, y2 in rects:
        m.poly(sec, with_inserts([(x1, y1), (x1, y2), (x2, y2), (x2, y1)]))
    return ((fx1 + fx2) // 2, (fy1 + fy2) // 2)


def build_map3():
    m = Map()
    outside, infield, OUT = stadium_world(m)
    add_pylons(m, outside, infield, OUT)
    add_exit_room(m, outside, False)

    # Town: eight buildings in three rows. Items sit in the middle of each room.
    W, DP, H = 512, 384, 352
    facades = ["BROWN1", "BRICK7", "STARGR2", "COMPSTA1"]
    spots = [(-2700, -1400), (-900, -1400), (900, -1400),
             (-1800, -200), (0, -200), (1800, -200),
             (-900, 1000), (900, 1000)]
    loot = [
        [2001, 2008],          # shotgun, shells
        [2011, 2048],          # stimpack, box of bullets
        [2012, 2007],          # medikit, clip
        [2018, 2012],          # armor, medikit
        [2002, 2007],          # chaingun, clip
        [2012, 2049],          # medikit, box of shells
        [2013],                # soulsphere
        [2011, 2011, 2048],    # stimpacks, box of bullets
    ]
    items = []
    for i, (bx, by) in enumerate(spots):
        mx, my = add_building(m, infield, bx, by, W, DP, H, facades[i % len(facades)])
        for k, typ in enumerate(loot[i]):
            items.append((mx - 40 + 60 * k, my, 0, typ))

    # Beacon towers mark the five wave zones (bright, tall, easy to see from the road).
    beacons = [(1, 1800, -3000, infield), (2, 5900, 0, infield), (3, 1200, 600, infield),
               (4, 625, 3000, infield), (5, -5900, 1000, infield)]
    things = []
    for n, bx, by, _ in beacons:
        parent = infield if n == 3 else outside
        bs = m.S(448, 1024, light=255, ftex="FLAT23", wall="SUPPORT2", ctex="F_SKY1")
        m.box(bs, bx - 64, by - 64, bx + 64, by + 64, parent)
        things.append((bx, by, 0, 30007, {"arg0": n, "arg1": 1100}))

    # Enemy spawn markers: (wave, kind 0 = Cluster Demon / 1 = Ram Car, x, y, facing)
    marks = [
        (1, 0, 900, -3000, 90), (1, 0, 1800, -3300, 90), (1, 0, 2700, -3000, 90),
        (2, 1, 5300, 600, 270), (2, 0, 5900, 900, 180), (2, 0, 5900, -900, 180),
        (3, 0, 600, 650, 0), (3, 0, 1200, 550, 0), (3, 0, 1500, 700, 0), (3, 0, 2100, 600, 0), (3, 0, 0, 700, 0),
        (4, 1, -600, 2400, 0), (4, 1, 900, 2300, 180),
        (4, 0, 0, 3300, 270), (4, 0, 1250, 3300, 270), (4, 0, -1250, 3300, 270),
        (5, 1, -5300, 300, 90), (5, 1, -4900, 1500, 270),
        (5, 0, -5900, 300, 0), (5, 0, -5900, 1700, 0), (5, 0, -6200, 1000, 0),
        (5, 0, -5600, 2000, 0), (5, 0, -6100, 2300, 0), (5, 0, -5700, -300, 0),
    ]
    for wave, kind, mx, my, ang in marks:
        things.append((mx, my, ang, 30006, {"arg0": wave, "arg1": kind}))

    m.things = [
        (0, int(-(TRK_R + 64)), 0, 1),                          # player start, lane +64
        (0, 600, 0, 30001, {"arg0": 12}),                       # traffic spawner: 12 cars per lane
        (-1250, 900, 0, 30005),                                 # wave director
    ] + items + things
    return m


# --------------------------------------------------------------------------
# GRAPPLE4: the city. A walled 3200 x 3200 grid: four 1024 x 1024 blocks of buildings
# separated by 384-wide streets, with cars on every street (rounded-rectangle lanes in
# traffic.zs: CITY_* constants; keep them in step with the numbers here). Waves start by
# themselves, one after another. A closed exit room on the west wall opens after wave 5.
# --------------------------------------------------------------------------
CITY_HALF_WORLD = 1600
CITY_BLOCK_C = 704
CITY_BLOCK = 1024


def build_map4():
    m = Map()
    ground = m.S(0, 1024, 224, ftex="FLAT1", ctex="F_SKY1", wall="GRAY1")
    Wd = CITY_HALF_WORLD
    # ground outline with a notch where the exit door sits (west wall, y -96..96)
    m.poly(ground, [(-Wd, -Wd), (-Wd, -96), (-Wd, 96), (-Wd, Wd), (Wd, Wd), (Wd, -Wd)])

    # exit door and exit room, west of the wall
    door = m.S(0, 0, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="DOORTRAK", tag=10)
    room = m.S(0, 160, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    m.poly(door, [(-Wd - 64, -96), (-Wd - 64, 96), (-Wd, 96), (-Wd, -96)])
    m.poly(room, [(-Wd - 400, -296), (-Wd - 400, -96), (-Wd - 400, 96), (-Wd - 400, 296),
                  (-Wd - 64, 296), (-Wd - 64, 96), (-Wd - 64, -96), (-Wd - 64, -296)])
    door_line = ((-Wd, -96), (-Wd, 96))
    m.specials[door_line] = dict(dontpegtop=True)
    m.override[door_line] = dict(texturetop="BIGDOOR2")
    exit_line = ((-Wd - 400, -96), (-Wd - 400, 96))
    m.specials[exit_line] = dict(special=243, arg0=0, playeruse=True)
    m.override[exit_line] = dict(texturemiddle="SW1EXIT")

    # four blocks: (center x, center y, door turn, roof height, facade)
    B = CITY_BLOCK
    blocks = [
        (-CITY_BLOCK_C, -CITY_BLOCK_C, 1, 352, "BROWN1"),
        (CITY_BLOCK_C, -CITY_BLOCK_C, 2, 448, "BRICK7"),
        (CITY_BLOCK_C, CITY_BLOCK_C, 3, 512, "STARGR2"),
        (-CITY_BLOCK_C, CITY_BLOCK_C, 0, 400, "COMPSTA1"),
    ]
    loot = [[2001, 2049, 2012], [2002, 2048, 2018], [2013, 2012, 2008], [2011, 2011, 2048]]
    roof_loot = [2012, 2011, 2012, 2019]
    items = []
    for i, (cx, cy, rot, H, facade) in enumerate(blocks):
        mx, my = add_building(m, ground, cx - B // 2, cy - B // 2, B, B, H, facade,
                              rot=rot, fl=0, doorhalf=96)
        for k, typ in enumerate(loot[i]):
            items.append((mx - 120 + 120 * k, my, 0, typ))
        items.append((cx - B // 2 + 32, cy + B // 2 - 32, 0, roof_loot[i]))   # on the roof

    # Spawn markers: (wave, kind 0 = Cluster Demon / 1 = Ram Car, x, y, facing)
    S1 = 1408
    marks = [
        (1, 0, -S1, -S1, 0), (1, 0, S1, -S1, 90), (1, 0, S1, S1, 180),
        (2, 1, S1, 600, 270), (2, 0, -S1, 900, 0), (2, 0, 0, S1, 270),
        (3, 0, -S1, 0, 0), (3, 0, S1, 0, 180), (3, 0, 0, -S1, 90), (3, 0, 0, S1, 270), (3, 0, 0, 0, 90),
        (4, 1, -S1, 700, 270), (4, 1, 700, S1, 180),
        (4, 0, -700, -S1, 90), (4, 0, 700, -S1, 90), (4, 0, S1, -300, 180),
        (5, 1, 0, 700, 270), (5, 1, -700, 0, 0),
        (5, 0, -S1, -S1, 0), (5, 0, S1, S1, 180), (5, 0, -S1, S1, 270),
        (5, 0, S1, -S1, 90), (5, 0, 0, S1, 270), (5, 0, 0, -S1, 90),
    ]
    things = []
    for wave, kind, mx, my, ang in marks:
        things.append((mx, my, ang, 30006, {"arg0": wave, "arg1": kind}))

    m.things = [
        (0, -900, 90, 1),                                       # player start, south end of the center street
        (0, 0, 0, 30001, {"arg0": 6}),                          # traffic spawner: 6 cars per lane
        (0, 100, 0, 30005, {"arg0": 1}),                        # wave director, automatic waves
    ] + items + things
    return m


# --------------------------------------------------------------------------
# GRAPPLE5: the tutorial. Octagonal rooms joined by short hallways, all indoors:
#   room 1 (pit start, 8 pillars with imps) -> door -> hallway 1 (shotgun + shells)
#   -> room 2 (one Cluster Demon) -> hallway 2 -> room 3 (big pillar, cars circling it
#   plus one Ram Car) -> exit room. Keep TUT_* in traffic.zs in step with ROOM3 below.
# --------------------------------------------------------------------------
TUT_ROOM3_CY = 4480    # traffic.zs TUT_CY


def octagon(cx, cy, a, north=0, south=0):
    """Clockwise octagon of apothem a (flat sides facing N/E/S/W). north/south = half-width
    of a doorway gap in that wall, whose two end vertices are added to the outline."""
    s2 = int(round(a * 0.41421))
    pts = [(cx - s2, cy + a)]
    if north:
        pts += [(cx - north, cy + a), (cx + north, cy + a)]
    pts += [(cx + s2, cy + a), (cx + a, cy + s2), (cx + a, cy - s2), (cx + s2, cy - a)]
    if south:
        pts += [(cx + south, cy - a), (cx - south, cy - a)]
    pts += [(cx - s2, cy - a), (cx - a, cy - s2), (cx - a, cy + s2)]
    return pts


def build_map5():
    m = Map()
    S, poly = m.S, m.poly
    H = 96                      # half width of every doorway and hallway (6 m across)

    # ---- room 1: 64 m across, pit in the south-west corner, 8 pillars ----
    room1 = S(0, 576, 192, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    poly(room1, octagon(0, 0, 1024, north=H))
    pit = S(-128, 576, 160, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    m.box(pit, -700, -700, -444, -444, room1)           # 8 m square, 4 m deep
    pillars = S(480, 576, 192, ftex="FLAT1", ctex="CEIL3_5", wall="STARTAN3")
    imps = []
    for k in range(8):
        a = math.radians(22.5 + 45 * k)                 # offset so none lands on the pit
        px, py = int(round(640 * math.cos(a))), int(round(640 * math.sin(a)))
        m.box(pillars, px - 64, py - 64, px + 64, py + 64, room1)
        ix, iy = int(round(750 * math.cos(a))), int(round(750 * math.sin(a)))   # behind it
        imps.append((ix, iy, int(math.degrees(a) + 180) % 360, 3001))

    # ---- doorway: vestibule, door slab, hallway 1 ----
    vest1 = S(0, 192, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    door = S(0, 0, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="DOORTRAK")
    hall1 = S(0, 192, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="COMPSTA1")
    poly(vest1, [(-H, 1024), (-H, 1088), (H, 1088), (H, 1024)])
    poly(door, [(-H, 1088), (-H, 1152), (H, 1152), (H, 1088)])
    poly(hall1, [(-H, 1152), (-H, 1664), (H, 1664), (H, 1152)])
    for edge in (((-H, 1088), (H, 1088)), ((H, 1152), (-H, 1152))):   # both faces open the door
        m.specials[edge] = dict(special=12, arg0=0, arg1=16, arg2=105,
                                playeruse=True, repeatspecial=True, dontpegtop=True)
        m.override[edge] = dict(texturetop="BIGDOOR2")

    # ---- room 2: 40 m across, empty ----
    room2 = S(0, 448, 192, ftex="FLOOR4_8", ctex="CEIL3_5", wall="BROWN1")
    poly(room2, octagon(0, 2304, 640, north=H, south=H))

    hall2 = S(0, 192, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="COMPSTA1")
    poly(hall2, [(-H, 2944), (-H, 3456), (H, 3456), (H, 2944)])

    # ---- room 3: 64 m across, one big pillar ----
    room3 = S(0, 704, 192, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARGR2")
    poly(room3, octagon(0, TUT_ROOM3_CY, 1024, north=H, south=H))
    bigp = S(608, 704, 192, ftex="FLAT1", ctex="CEIL3_5", wall="STARGR2")
    oct3 = octagon(0, TUT_ROOM3_CY, 192)
    poly(bigp, oct3)
    m.rev(room3, oct3)

    # ---- exit: vestibule and small room ----
    vest2 = S(0, 192, 176, ftex="FLOOR4_8", ctex="CEIL3_5", wall="COMPSTA1")
    poly(vest2, [(-H, 5504), (-H, 5568), (H, 5568), (H, 5504)])
    exitroom = S(0, 192, 192, ftex="FLOOR4_8", ctex="CEIL3_5", wall="STARTAN3")
    poly(exitroom, [(-192, 5568), (-192, 5952), (-H, 5952), (H, 5952), (192, 5952),
                    (192, 5568), (H, 5568), (-H, 5568)])
    sw = ((-H, 5952), (H, 5952))
    m.specials[sw] = dict(special=243, arg0=0, playeruse=True)          # Exit_Normal
    m.override[sw] = dict(texturemiddle="SW1EXIT")

    m.things = [
        (-572, -572, 45, 1), (-520, -572, 45, 2), (-624, -572, 45, 3), (-572, -520, 45, 4),
        (-32, 1408, 0, 2001), (32, 1408, 0, 2008),             # shotgun and shells, middle of hallway 1
        (0, 2304, 270, 30002),                                  # the single Cluster Demon, room 2
        (0, 3200, 0, 2012),                                     # medikit in hallway 2
        (0, TUT_ROOM3_CY, 0, 30001, {"arg0": 6}),               # traffic spawner: 6 cars per circle
        (-800, 5000, 0, 30004),                                 # the Ram Car
        (0, 5700, 0, 2012),                                     # medikit in the exit room
    ] + imps
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
    write_map("GRAPPLE3", "grapple3.wad", build_map3())
    write_map("GRAPPLE4", "grapple4.wad", build_map4())
    write_map("GRAPPLE5", "grapple5.wad", build_map5())

    with zipfile.ZipFile("GrappleMod.pk3", "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(SRC):
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, SRC))
    print("wrote GrappleMod.pk3")
