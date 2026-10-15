// Test di cogo_enu.js con Node: node test/test_cogo_enu.js
// Il file usa ".pragma library" (QML): qui la riga viene rimossa e il codice valutato in un contesto isolato.
const fs = require("fs"), path = require("path"), vm = require("vm");
const src = fs.readFileSync(path.join(__dirname, "..", "cogo_linea", "cogo_enu.js"), "utf8").replace(/^\.pragma library\s*/, "");
const C = {}; vm.createContext(C); vm.runInContext(src, C);

let fail = 0;
function ok(nome, cond, info) { console.log((cond ? "OK   " : "FAIL ") + nome + (info ? "  " + info : "")); if (!cond) fail++; }
const near = (a, b, t) => Math.abs(a - b) <= t;

// Origine a Padova, N0 indicativo
const o = C.makeOrigin(45.4064, 11.8768, 12.0, 47.2, "test");
const A = C.punto(45.4064, 11.8768, 12.0, o), B = C.punto(45.4071, 11.8790, 14.0, o);

// Andata e ritorno
const g = C.aGeografiche(B, o), B2 = C.punto(g.lat, g.lon, g.H, o);
ok("roundtrip ENU <-> 6706", near(B2.e, B.e, 1e-6) && near(B2.n, B.n, 1e-6) && near(g.H, 14, 1e-6));

// Operazioni del plugin
const L = C.inversa(A, B).d;
ok("punto medio", near(C.inversa(A, C.puntoMedio(A, B)).d, L / 2, 1e-6));
ok("dividi 4", near(C.inversa(A, C.dividi(A, B, 4)[2]).d, 3 * L / 4, 1e-6));
const P1 = C.puntoSuAllineamento(A, B, 30, 5), r1 = C.piedePerpendicolare(A, B, P1);
ok("progressiva/offset", near(r1.progressiva, 30, 1e-6) && near(r1.offset, 5, 1e-6));
const di = C.dividiIntervallo(A, B, 50);
ok("intervallo fisso", di.punti.length === 3 && near(di.resto, L - 150, 1e-6), "resto " + di.resto.toFixed(3));
const pa = C.puntoAngoloDistanza(A, B, 100, 10), ra = C.piedePerpendicolare(A, B, pa);
ok("angolo e distanza (100 gon = destra)", near(ra.offset, 10, 1e-6) && near(ra.progressiva, 0, 1e-6));
const dd = C.intDistDist(A, 120, B, 120);
ok("distanza-distanza", near(C.inversa(A, dd.destra).d, 120, 1e-6) && near(C.inversa(B, dd.sinistra).d, 120, 1e-6)
   && C.piedePerpendicolare(A, B, dd.destra).offset > 0);

console.log(fail ? `\n${fail} test falliti` : "\nTutti i test superati");
process.exit(fail ? 1 : 0);
