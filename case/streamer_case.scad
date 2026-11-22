// BPi M2U streamer case (OpenSCAD 2021.01)
//
// Orientation (as seen from the front):
//   front = display (inside, behind a window), 40-pin header + onboard IR receiver
//   left  = USB + LAN + audio jack
//   right = DC-in (drill the hole for the 90° adapter yourself)
//   back  = board SATA / SATA power / HDMI / OTG
//
// Coordinates: X left->right, Y front->back, Z up.
// Origin X/Y = front-left corner of the PCB (as seen from the front),
// Z = 0 is the underside of the floor.
// Board data taken from the official BPi-M2-Ultra-TOP.dxf (board rotated
// 180°: u = 96.4 - x_dxf, v = 59.9 - y_dxf).
//
// Assembly: board on the standoffs -> header extension -> 90° adapter plugged
// onto the display -> lower display + adapter into the front pocket (it slides
// down between window wall and rails and rests on the ledge) -> disk screwed
// to the lid brackets, SATA cable plugged -> lid on.
//
// Render:  part = "base" | "lid" | "assembly" | "section"

part = "assembly";

$fn = 40;
eps = 0.01;

// ---------- general ----------
wall    = 2.4;   // side walls
floor_t = 2.0;   // floor thickness
lid_t   = 2.4;   // lid thickness
clr     = 0.3;   // fit clearance

// ---------- board (from DXF) ----------
board_w = 91.4;
board_d = 59.9;
pcb_t   = 1.6;
standoff_h = 5;          // room for SD slot / RAM on the bottom side
standoff_d = 6;
board_screw_d = 2.2;     // pilot for M2.5 self-tapping (board holes ~3 mm)
board_holes = [[2.755, 2.750], [88.605, 2.750],
               [2.755, 57.106], [88.605, 51.823]];

pcb_z     = floor_t + standoff_h;
board_top = pcb_z + pcb_t;

// connectors (u/v from DXF, z relative to board_top)
usb   = [[-4.6, 14.9], [14.4, 29.3], 16.0];   // [min], [max], height
lan   = [[-4.6, 33.2], [16.9, 48.9], 13.5];
audio = [9.8, 3.0, 7.5];                       // v, z centre, hole d
ir    = [9.9, 0.4, 5.4];                       // u centre, v min, v max
header_u = [28.0, 78.8];                       // 40-pin header span along X

// ---------- display (inside the case) ----------
disp_w = 85; disp_h = 55; disp_t = 6;
disp_x0     = 0;                // left edge in line with the board's left edge
disp_z0     = board_top + 11;   // lower edge above board surface
disp_back_v = -13;              // back face 13 mm in front of the board front edge
// visible area borders, seen from the front: left, right, bottom, top
disp_border = [7, 2, 2, 2];
win_chamfer = 1.5;              // window edge chamfer on the outside
rail_t = 3;                     // guide rails behind the display
ledge  = 0;                     // ledge depth behind the display back (0 = flush, keeps the adapter free)
ledge_x0 = 17;                  // ledge starts right of the IR window

// ---------- 2.5" disk ----------
disk_len  = 100.0;
disk_w    = 69.85;
disk_hmax = 9.5;          // 7 mm disks fit too (slotted holes)
top_gap   = 3;            // disk top -> lid underside
disk_x0   = -4.3;         // left end of the disk
disk_y0   = 12;           // front side of the disk

// ---------- cable space ----------
cable_right = 50;         // right of the disk connector end
cable_back  = 50;         // behind the board

// ---------- derived inner box ----------
in_x0 = usb[0][0] - 0.2;                         // USB/LAN flush with the wall
in_x1 = disk_x0 + disk_len + cable_right;
in_y0 = disp_back_v - disp_t - clr;              // display glass against the front wall
in_y1 = board_d + cable_back;
top_z   = disp_z0 + disp_h + 2;                  // wall top = lid underside
disk_z0 = top_z - top_gap - disk_hmax;           // disk hangs right under the lid

out_x0 = in_x0 - wall; out_x1 = in_x1 + wall;
out_y0 = in_y0 - wall; out_y1 = in_y1 + wall;

// lid screw bosses: [x, y]  (all full height)
boss = 6;
lid_screw_d = 2.7;        // pilot for M3 self-tapping
bosses = [
  [in_x0 + boss/2,  disp_back_v + rail_t + 1 + boss/2],   // left wall, behind the display pocket
  [in_x1 - boss/2,  in_y0 + boss/2],
  [in_x0 + boss/2,  in_y1 - boss/2],
  [in_x1 - boss/2,  in_y1 - boss/2],
];

// ---------------------------------------------------------------
module rbox(p0, p1) translate(p0) cube(p1 - p0);

module slot2d(a, b, d) hull() { translate(a) circle(d = d); translate(b) circle(d = d); }

module vents(x0, y0, len, n, pitch, w = 2.2) {
  for (i = [0 : n - 1]) translate([x0, y0 + i * pitch]) hull() {
    circle(d = w); translate([len, 0]) circle(d = w);
  }
}

// display window (with outside chamfer)
module disp_window() {
  x0 = disp_x0 + disp_border[0]; x1 = disp_x0 + disp_w - disp_border[1];
  z0 = disp_z0 + disp_border[2]; z1 = disp_z0 + disp_h - disp_border[3];
  rbox([x0, out_y0 - 1, z0], [x1, in_y0 + 1, z1]);
  hull() {
    rbox([x0, out_y0 + win_chamfer, z0], [x1, out_y0 + win_chamfer + eps, z1]);
    rbox([x0 - win_chamfer - 1, out_y0 - 1, z0 - win_chamfer - 1],
         [x1 + win_chamfer + 1, out_y0 - 1 + eps, z1 + win_chamfer + 1]);
  }
}

// display pocket: ledge under the display + L-shaped guide rails behind/beside it
module disp_pocket() {
  // ledge with 45° support underneath
  hull() {
    rbox([ledge_x0, in_y0 - eps, disp_z0 - 2], [disp_x0 + disp_w, disp_back_v + ledge, disp_z0]);
    rbox([ledge_x0, in_y0 - eps, disp_z0 - 2 - (disp_t + ledge)], [disp_x0 + disp_w, in_y0, disp_z0 - 2]);
  }
  // rails, floor to top
  for (s = [[disp_x0, disp_x0 + rail_t, disp_x0 - 1.7 - clr, disp_x0 - clr],
            [disp_x0 + disp_w - rail_t, disp_x0 + disp_w, disp_x0 + disp_w + clr, disp_x0 + disp_w + clr + 1.7]]) {
    rbox([s[0], disp_back_v + clr, floor_t - eps], [s[1], disp_back_v + clr + rail_t, top_z]);
    rbox([s[2], in_y0 - eps, floor_t - eps], [s[3], disp_back_v + clr + rail_t, top_z]);
  }
}

// ---------------- base ----------------
module base() {
  difference() {
    union() {
      // shell
      difference() {
        rbox([out_x0, out_y0, 0], [out_x1, out_y1, top_z]);
        rbox([in_x0, in_y0, floor_t], [in_x1, in_y1, top_z + 1]);
      }
      disp_pocket();
      // board standoffs
      for (h = board_holes) translate([h[0], h[1], floor_t - eps])
        cylinder(d = standoff_d, h = standoff_h + eps);
      // lid bosses
      for (b = bosses) translate([b[0] - boss/2, b[1] - boss/2, floor_t - eps])
        cube([boss, boss, top_z - floor_t + eps]);
      // feet
      for (x = [out_x0 + 8, out_x1 - 8], y = [out_y0 + 8, out_y1 - 8])
        translate([x, y, -3]) cylinder(d = 10, h = 3 + eps);
    }
    // board screw pilots
    for (h = board_holes) translate([h[0], h[1], 0.8]) cylinder(d = board_screw_d, h = 20);
    // lid screw pilots
    for (b = bosses) translate([b[0], b[1], top_z - 12]) cylinder(d = lid_screw_d, h = 13);

    // left wall: USB, LAN, audio
    for (c = [usb, lan])
      rbox([out_x0 - 1, c[0][1] - 0.6, board_top - 0.6],
           [in_x0 + 1, c[1][1] + 0.6, board_top + c[2] + 0.6]);
    translate([out_x0 - 1, audio[0], board_top + audio[1]]) rotate([0, 90, 0])
      cylinder(d = audio[2], h = wall + 2);

    // front wall: display window, IR window
    disp_window();
    rbox([ir[0] - 6, out_y0 - 1, board_top - 1], [ir[0] + 6, in_y0 + 1, board_top + 8]);

    // floor vents under the CPU / board centre (intake)
    translate([0, 0, -1]) linear_extrude(floor_t + 2) vents(22, 14, 40, 9, 4);
    // floor vents in the cable area
    translate([0, 0, -1]) linear_extrude(floor_t + 2) vents(100, 12, 36, 10, 4);
    // back wall vents, high (exhaust)
    for (i = [0 : 13]) translate([in_x0 + 12 + i * 9, in_y1 - 1, top_z - 18])
      rotate([-90, 0, 0]) linear_extrude(wall + 2) slot2d([0, 0], [0, -10], 3);
    // right wall vents, low
    for (i = [0 : 9]) translate([in_x1 - 1, in_y0 + 30 + i * 8, floor_t + 5])
      rotate([90, 0, 90]) linear_extrude(wall + 2) slot2d([0, 0], [0, 12], 3);
  }
}

// ---------------- lid (modelled in place, exported flipped) ----------------
br_t = 3;   // disk bracket thickness

module lid() {
  difference() {
    union() {
      // plate
      rbox([out_x0, out_y0, top_z], [out_x1, out_y1, top_z + lid_t]);
      // locating lip
      difference() {
        rbox([in_x0 + clr, in_y0 + clr, top_z - 3], [in_x1 - clr, in_y1 - clr, top_z + eps]);
        rbox([in_x0 + clr + 1.6, in_y0 + clr + 1.6, top_z - 4], [in_x1 - clr - 1.6, in_y1 - clr - 1.6, top_z + 1]);
        for (b = bosses) rbox([b[0] - boss/2 - clr, b[1] - boss/2 - clr, top_z - 4],
                              [b[0] + boss/2 + clr, b[1] + boss/2 + clr, top_z + 1]);
        // display pocket rails reach the top
        rbox([disp_x0 - 3, in_y0 - 1, top_z - 4], [disp_x0 + disp_w + 3, disp_back_v + rail_t + 1, top_z + 1]);
      }
      // disk brackets (hang down along both long sides of the disk)
      for (y = [disk_y0 - clr - br_t, disk_y0 + disk_w + clr])
        rbox([disk_x0 + 2, y, disk_z0 - 1], [disk_x0 + disk_len - 2, y + br_t, top_z + eps]);
    }
    // lid screw holes (countersunk from the top)
    for (b = bosses) translate([b[0], b[1], top_z - 4]) {
      cylinder(d = 3.4, h = 10);
      translate([0, 0, 4 + lid_t - 1.7]) cylinder(d1 = 3.4, d2 = 6.6, h = 1.7 + eps);
    }
    // disk side holes (SFF-8201: 3 mm above the bottom, 76.6 mm apart).
    // Slotted in X (connector end unknown: 9.4..14 mm from either end)
    // and in Z (7 mm and 9.5 mm disks).
    for (e = [[9.4, 14.0], [86.0, 90.6]])
      translate([0, disk_y0 - br_t - 5, 0]) rotate([-90, 0, 0])
        linear_extrude(disk_w + 2 * br_t + 10)
          hull() for (x = e, z = [disk_z0 + 3, disk_z0 + 5.5])
            translate([disk_x0 + x, -z]) circle(d = 3.4);
    // vents over the cable area and behind the disk
    translate([0, 0, top_z - 4]) linear_extrude(lid_t + 5) {
      vents(disk_x0 + disk_len + 8, 8, 34, 24, 4);
      vents(4, disk_y0 + disk_w + 8, 80, 5, 4);
    }
  }
}

// ---------------- dummies for the preview ----------------
module board_dummy() {
  color("darkgreen") translate([0, 0, pcb_z]) cube([board_w, board_d, pcb_t]);
  color("silver") for (c = [usb, lan])
    rbox([c[0][0], c[0][1], board_top], [c[1][0], c[1][1], board_top + c[2]]);
  color("black") rbox([header_u[0], 0.5, board_top], [header_u[1], 5.5, board_top + 8.5]);
  color("dimgray") rbox([ir[0] - 3, ir[1], board_top], [ir[0] + 3, ir[2], board_top + 6]);
  color("gray") rbox([31, 18, board_top], [49, 35, board_top + 1.5]);   // CPU
}

module disk_dummy() color("lightsteelblue")
  rbox([disk_x0, disk_y0, disk_z0], [disk_x0 + disk_len, disk_y0 + disk_w, disk_z0 + disk_hmax]);

module display_dummy() color("navy")
  rbox([disp_x0, disp_back_v - disp_t, disp_z0], [disp_x0 + disp_w, disp_back_v, disp_z0 + disp_h]);

// ---------------- output ----------------
if (part == "base") base();
else if (part == "lid") translate([0, 0, top_z + lid_t]) rotate([180, 0, 0]) lid();
else if (part == "section") intersection() {   // cut at X = 50, seen from the left
  rbox([50, -100, -10], [300, 300, 200]);
  union() { color("orange") base(); color("gold") lid(); board_dummy(); disk_dummy(); display_dummy(); }
}
else {
  color("orange", 0.55) base();
  color("gold", 0.45) translate([0, 0, 25]) lid();   // lifted for visibility
  board_dummy(); disk_dummy(); display_dummy();
}

echo(str("outer size: ", out_x1 - out_x0, " x ", out_y1 - out_y0, " x ", top_z + lid_t, " mm (+3 mm feet)"));
echo(str("board top z=", board_top, "  disk bottom z=", disk_z0, "  display z=", disp_z0, "..", disp_z0 + disp_h));
