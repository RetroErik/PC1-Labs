// Generate 200-step NASM gradient tables for sunset200, rainbow200, cubehelix200
// Output: grad200_tables.inc

var fso = new ActiveXObject("Scripting.FileSystemObject");
var outPath = fso.GetParentFolderName(WScript.ScriptFullName) + "\\grad200_tables.inc";

function encode(r, g, b) {
  var ri = Math.min(7, Math.max(0, Math.round(r)));
  var gi = Math.min(7, Math.max(0, Math.round(g)));
  var bi = Math.min(7, Math.max(0, Math.round(b)));
  return [ri, (gi << 4) | bi];
}

function lerpEncode(r1,g1,b1, r2,g2,b2, t) {
  return encode(r1+(r2-r1)*t, g1+(g2-g1)*t, b1+(b2-b1)*t);
}

function generateFromWaypoints(waypoints) {
  var steps = [];
  for (var i = 0; i < 200; i++) {
    var t = i / 199;
    var lo = waypoints[0], hi = waypoints[waypoints.length - 1];
    for (var w = 0; w < waypoints.length - 1; w++) {
      if (t >= waypoints[w].t && t <= waypoints[w+1].t) {
        lo = waypoints[w]; hi = waypoints[w+1]; break;
      }
    }
    var seg = (hi.t === lo.t) ? 0 : (t - lo.t) / (hi.t - lo.t);
    steps.push(lerpEncode(lo.r, lo.g, lo.b, hi.r, hi.g, hi.b, seg));
  }
  return steps;
}

// --- Sunset 200 ---
var sunset200 = generateFromWaypoints([
  {t:0.00, r:0, g:0, b:0},
  {t:0.05, r:1, g:0, b:2},
  {t:0.12, r:2, g:0, b:4},
  {t:0.18, r:3, g:0, b:7},
  {t:0.25, r:5, g:0, b:6},
  {t:0.32, r:6, g:0, b:4},
  {t:0.38, r:7, g:0, b:3},
  {t:0.44, r:7, g:0, b:1},
  {t:0.50, r:7, g:0, b:0},
  {t:0.56, r:7, g:1, b:0},
  {t:0.62, r:7, g:2, b:0},
  {t:0.68, r:7, g:3, b:0},
  {t:0.74, r:7, g:4, b:0},
  {t:0.80, r:7, g:5, b:0},
  {t:0.86, r:7, g:6, b:0},
  {t:0.90, r:7, g:7, b:0},
  {t:0.94, r:7, g:7, b:2},
  {t:1.00, r:7, g:7, b:7}
]);

// --- Rainbow 200 ---
function hsv2rgb(h, s, v) {
  h = ((h % 6) + 6) % 6;
  var c = v * s;
  var x = c * (1 - Math.abs(h % 2 - 1));
  var m = v - c;
  var r, g, b;
  if (h < 1) { r=c; g=x; b=0; }
  else if (h < 2) { r=x; g=c; b=0; }
  else if (h < 3) { r=0; g=c; b=x; }
  else if (h < 4) { r=0; g=x; b=c; }
  else if (h < 5) { r=x; g=0; b=c; }
  else { r=c; g=0; b=x; }
  return [r+m, g+m, b+m];
}

var rainbow200 = [];
for (var i = 0; i < 200; i++) {
  var t = i / 199;
  if (t < 0.08) {
    var v = t / 0.08;
    var rgb = hsv2rgb(0, 1, v);
    rainbow200.push(encode(rgb[0]*7, rgb[1]*7, rgb[2]*7));
  } else if (t > 0.92) {
    var wt = (t - 0.92) / 0.08;
    var rgb = hsv2rgb(5.8, 1, 1);
    rainbow200.push(encode((rgb[0] + wt*(1-rgb[0]))*7, (rgb[1] + wt*(1-rgb[1]))*7, (rgb[2] + wt*(1-rgb[2]))*7));
  } else {
    var ht = (t - 0.08) / 0.84;
    var h = ht * 6;
    var rgb = hsv2rgb(h, 1, 1);
    rainbow200.push(encode(rgb[0]*7, rgb[1]*7, rgb[2]*7));
  }
}

// --- Cubehelix 200 (optimized: rot=37, amp=2.4, start=0.5) ---
// Use known best params from sweep, oversample to find unique colors
function cubehelix(t, startAngle, rotations, amp) {
  var angle = 2 * Math.PI * (startAngle / 3 + rotations * t);
  var a = amp * t * (1 - t);
  var cosA = Math.cos(angle), sinA = Math.sin(angle);
  var r = t + a * (-0.14861 * cosA + 1.78277 * sinA);
  var g = t + a * (-0.29227 * cosA - 0.90649 * sinA);
  var b = t + a * (1.97294 * cosA);
  return [Math.max(0, Math.min(1, r)), Math.max(0, Math.min(1, g)), Math.max(0, Math.min(1, b))];
}

// Sweep parameters to find best (same as HTML)
var bestColors = [], bestCount = 0, bestP = {};
for (var rot = 5; rot <= 50; rot += 5) {
  var samples = Math.max(10000, rot * 1000);
  for (var amp10 = 13; amp10 <= 25; amp10 += 2) {
    for (var start10 = 0; start10 <= 30; start10 += 5) {
      var unique = [], seen = {};
      for (var ii = 0; ii <= samples; ii++) {
        var tt = ii / samples;
        var c = cubehelix(tt, start10/10, rot, amp10/10);
        var ri = Math.min(7, Math.max(0, Math.round(c[0] * 7)));
        var gi = Math.min(7, Math.max(0, Math.round(c[1] * 7)));
        var bi = Math.min(7, Math.max(0, Math.round(c[2] * 7)));
        var key = (ri << 6) | (gi << 3) | bi;
        if (!seen[key]) { seen[key] = true; unique.push([ri, (gi << 4) | bi]); }
      }
      if (unique.length > bestCount) { bestCount = unique.length; bestColors = unique; bestP = {s:start10/10,r:rot,a:amp10/10}; }
    }
  }
}
// Fine-tune around best
var bRot = bestP.r;
for (var rot = Math.max(3, bRot - 3); rot <= bRot + 3; rot++) {
  var samples = Math.max(10000, rot * 1000);
  for (var amp10 = 13; amp10 <= 25; amp10++) {
    for (var start10 = 0; start10 <= 30; start10 += 2) {
      var unique = [], seen = {};
      for (var ii = 0; ii <= samples; ii++) {
        var tt = ii / samples;
        var c = cubehelix(tt, start10/10, rot, amp10/10);
        var ri = Math.min(7, Math.max(0, Math.round(c[0] * 7)));
        var gi = Math.min(7, Math.max(0, Math.round(c[1] * 7)));
        var bi = Math.min(7, Math.max(0, Math.round(c[2] * 7)));
        var key = (ri << 6) | (gi << 3) | bi;
        if (!seen[key]) { seen[key] = true; unique.push([ri, (gi << 4) | bi]); }
      }
      if (unique.length > bestCount) { bestCount = unique.length; bestColors = unique; bestP = {s:start10/10,r:rot,a:amp10/10}; }
    }
  }
}
WScript.Echo("Cubehelix: " + bestCount + " unique (rot=" + bestP.r + " amp=" + bestP.a + " start=" + bestP.s + ")");

// Distribute to 200
var cubehelix200 = [];
if (bestColors.length >= 200) {
  for (var i = 0; i < 200; i++) {
    var idx = Math.round(i * (bestColors.length - 1) / 199);
    cubehelix200.push(bestColors[idx]);
  }
} else {
  for (var i = 0; i < 200; i++) {
    var idx = Math.min(bestColors.length - 1, Math.floor(i * bestColors.length / 200));
    cubehelix200.push(bestColors[idx]);
  }
}

// --- Write NASM tables ---
function writeTable(name, data) {
  var lines = [];
  lines.push("; " + name + ": 200 entries x 2 bytes (R, (G<<4)|B)");
  lines.push(name + ":");
  for (var i = 0; i < 200; i += 8) {
    var parts = [];
    for (var j = i; j < Math.min(i + 8, 200); j++) {
      parts.push(data[j][0] + ", 0x" + (data[j][1] < 16 ? "0" : "") + data[j][1].toString(16).toUpperCase());
    }
    lines.push("    db " + parts.join(", "));
  }
  return lines.join("\r\n");
}

var output = [];
output.push("; ============================================================================");
output.push("; grad200_tables.inc — 200-step gradient tables for cgaflip9 Mode 3");
output.push("; Generated by gen_grad200.js — DO NOT EDIT BY HAND");
output.push("; ============================================================================");
output.push("");
output.push(writeTable("grad200_sunset", sunset200));
output.push("");
output.push(writeTable("grad200_rainbow", rainbow200));
output.push("");
output.push(writeTable("grad200_cubehelix", cubehelix200));

var f = fso.CreateTextFile(outPath, true);
f.Write(output.join("\r\n") + "\r\n");
f.Close();

WScript.Echo("Written: " + outPath);
WScript.Echo("Sunset200: 200 entries");
WScript.Echo("Rainbow200: 200 entries");
WScript.Echo("Cubehelix200: 200 entries (from " + bestCount + " unique pool)");
