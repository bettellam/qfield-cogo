.pragma library
// cogo_enu.js — calcolo COGO su piano topocentrico locale (ENU)
// Input/output: EPSG:6706 (RDN2008, ETRF2000) + quota ortometrica H.
// N0 = ondulazione del geoide all'origine (grigliato IGM), costante sul cantiere.
// Angoli in gon, azimut da Nord in senso orario, 0–400.

var A = 6378137.0;
var F = 1 / 298.257222101;          // GRS80
var E2 = F * (2 - F);
var GON = Math.PI / 200;
var DEG = Math.PI / 180;

// ---------- Utilità angolari ----------
function normGon(g) { g = g % 400; return g < 0 ? g + 400 : g; }
function azimutGon(de, dn) { return normGon(Math.atan2(de, dn) / GON); }

// ---------- Geodesia ----------
function geo2ecef(latDeg, lonDeg, h) {
    var p = latDeg * DEG, l = lonDeg * DEG;
    var s = Math.sin(p), c = Math.cos(p);
    var Nr = A / Math.sqrt(1 - E2 * s * s);
    return [(Nr + h) * c * Math.cos(l), (Nr + h) * c * Math.sin(l), (Nr * (1 - E2) + h) * s];
}

function ecef2geo(X, Y, Z) {
    var lon = Math.atan2(Y, X);
    var p = Math.sqrt(X * X + Y * Y);
    var lat = Math.atan2(Z, p * (1 - E2));
    var h = 0, Nr;
    for (var i = 0; i < 6; i++) {
        var s = Math.sin(lat);
        Nr = A / Math.sqrt(1 - E2 * s * s);
        h = p / Math.cos(lat) - Nr;
        lat = Math.atan2(Z, p * (1 - E2 * Nr / (Nr + h)));
    }
    return { lat: lat / DEG, lon: lon / DEG, h: h };
}

// ---------- Origine del piano ----------
// lat, lon (6706), H ortometrica, N0 da grigliato.
function makeOrigin(lat, lon, H, N0, grigliato) {
    if (N0 === null || N0 === undefined || isNaN(N0))
        throw new Error("N0 non valido: origine fuori copertura del grigliato?");
    var p = lat * DEG, l = lon * DEG;
    return {
        lat: lat, lon: lon, H: H, N0: N0, grigliato: grigliato || "",
        O: geo2ecef(lat, lon, H + N0),
        sp: Math.sin(p), cp: Math.cos(p), sl: Math.sin(l), cl: Math.cos(l)
    };
}

// geodetiche (6706) + H → ENU
function toENU(lat, lon, H, o) {
    var P = geo2ecef(lat, lon, H + o.N0);
    var dx = P[0] - o.O[0], dy = P[1] - o.O[1], dz = P[2] - o.O[2];
    return {
        e: -o.sl * dx + o.cl * dy,
        n: -o.sp * o.cl * dx - o.sp * o.sl * dy + o.cp * dz,
        u:  o.cp * o.cl * dx + o.cp * o.sl * dy + o.sp * dz
    };
}

// ENU → geodetiche (6706) + H
function enu2geo(e, n, u, o) {
    var dx = -o.sl * e - o.sp * o.cl * n + o.cp * o.cl * u;
    var dy =  o.cl * e - o.sp * o.sl * n + o.cp * o.sl * u;
    var dz =             o.cp * n        + o.sp * u;
    var g = ecef2geo(o.O[0] + dx, o.O[1] + dy, o.O[2] + dz);
    return { lat: g.lat, lon: g.lon, H: g.h - o.N0 };
}

// Punto calcolato in planimetria (e, n) a cui si assegna una quota H nota:
// si cerca la u che restituisce esattamente quella H.
function fromENU(e, n, H, o) {
    var u = H - o.H, g;
    for (var i = 0; i < 4; i++) {
        g = enu2geo(e, n, u, o);
        u += H - g.H;
    }
    return enu2geo(e, n, u, o);
}

// ---------- COGO (piano ENU, distanze orizzontali al suolo) ----------

// Problema inverso
function inversa(p1, p2) {
    var de = p2.e - p1.e, dn = p2.n - p1.n;
    return { d: Math.sqrt(de * de + dn * dn), az: azimutGon(de, dn), dU: p2.u - p1.u };
}

// Irradiamento (problema diretto)
function irradia(p, azGon, d) {
    var a = azGon * GON;
    return { e: p.e + d * Math.sin(a), n: p.n + d * Math.cos(a) };
}

// Intersezione distanza–distanza: due soluzioni, a sinistra e a destra di p1→p2
function intDistDist(p1, d1, p2, d2) {
    var de = p2.e - p1.e, dn = p2.n - p1.n;
    var b = Math.sqrt(de * de + dn * dn);
    if (b === 0) throw new Error("Punti coincidenti");
    if (d1 + d2 < b || Math.abs(d1 - d2) > b) throw new Error("Cerchi senza intersezione");
    var x = (d1 * d1 - d2 * d2 + b * b) / (2 * b);
    var y = Math.sqrt(Math.max(0, d1 * d1 - x * x));
    var ue = de / b, un = dn / b;                    // versore p1→p2
    var me = p1.e + x * ue, mn = p1.n + x * un;
    return {
        destra:   { e: me + y * un, n: mn - y * ue },
        sinistra: { e: me - y * un, n: mn + y * ue }
    };
}

// Progressiva e scostamento di p rispetto all'allineamento a→b
// offset > 0 a destra della direzione a→b
function progressivaOffset(a, b, p) {
    var de = b.e - a.e, dn = b.n - a.n;
    var L = Math.sqrt(de * de + dn * dn);
    var ue = de / L, un = dn / L;
    var qe = p.e - a.e, qn = p.n - a.n;
    var prog = qe * ue + qn * un;
    var off = qe * un - qn * ue;
    return { progressiva: prog, offset: off, piede: { e: a.e + prog * ue, n: a.n + prog * un } };
}

// Punto da progressiva e offset su allineamento a→b
function puntoDaProgOffset(a, b, prog, off) {
    var de = b.e - a.e, dn = b.n - a.n;
    var L = Math.sqrt(de * de + dn * dn);
    var ue = de / L, un = dn / L;
    return { e: a.e + prog * ue + off * un, n: a.n + prog * un - off * ue };
}

// ---------- Operazioni elementari su allineamento A–B ----------
// I punti portano anche H (ortometrica); i punti derivati ricevono una quota
// interpolata linearmente lungo A→B, marcata come "interpolata".

// Punto misurato → punto di calcolo (ENU + H)
function punto(lat, lon, H, o) {
    var p = toENU(lat, lon, H, o);
    p.H = H;
    return p;
}

function _lung(a, b) {
    var de = b.e - a.e, dn = b.n - a.n;
    var L = Math.sqrt(de * de + dn * dn);
    if (L < 1e-6) throw new Error("A e B coincidenti");
    return L;
}

function _Hinterp(a, b, t) {
    return (a.H === undefined || b.H === undefined) ? null : a.H + t * (b.H - a.H);
}

// Punto medio di A–B
function puntoMedio(a, b) {
    return { e: (a.e + b.e) / 2, n: (a.n + b.n) / 2, H: _Hinterp(a, b, 0.5), quota: "interpolata" };
}

// Divisione di A–B in N parti uguali: restituisce gli N-1 punti interni, da A verso B
function dividi(a, b, N) {
    N = Math.floor(N);
    if (N < 2) throw new Error("N deve essere almeno 2");
    var out = [];
    for (var k = 1; k < N; k++) {
        var t = k / N;
        out.push({ e: a.e + t * (b.e - a.e), n: a.n + t * (b.n - a.n),
                   H: _Hinterp(a, b, t), quota: "interpolata", indice: k });
    }
    return out;
}

// Suddivisione a intervallo fisso a partire da progressiva "inizio" (default = passo)
function dividiIntervallo(a, b, passo, inizio) {
    var L = _lung(a, b);
    if (!(passo > 0)) throw new Error("Passo non valido");
    var s = (inizio === undefined) ? passo : inizio, out = [], k = 1;
    while (s < L - 1e-9) {
        var t = s / L;
        out.push({ e: a.e + t * (b.e - a.e), n: a.n + t * (b.n - a.n),
                   H: _Hinterp(a, b, t), quota: "interpolata", indice: k++, progressiva: s });
        s += passo;
    }
    var ultima = out.length ? out[out.length - 1].progressiva : 0;
    return { punti: out, resto: L - ultima };
}

// Punto a distanza x da A lungo A→B e a distanza y ortogonale alla retta.
// x < 0: prima di A; x > |AB|: prolungamento oltre B. y > 0 a destra di A→B.
function puntoSuAllineamento(a, b, x, y) {
    var L = _lung(a, b);
    var p = puntoDaProgOffset(a, b, x, y || 0);
    var t = x / L;
    p.H = _Hinterp(a, b, Math.max(0, Math.min(1, t)));
    p.quota = (t < 0 || t > 1) ? "da A/B (fuori segmento)" : "interpolata";
    return p;
}

// Piede della perpendicolare da P alla retta A–B, con progressiva e scostamento
function piedePerpendicolare(a, b, p) {
    var L = _lung(a, b);
    var r = progressivaOffset(a, b, p);
    var t = r.progressiva / L;
    r.piede.H = _Hinterp(a, b, Math.max(0, Math.min(1, t)));
    r.piede.quota = "interpolata";
    r.interno = (t >= 0 && t <= 1);
    return r;
}

// Punto da stazione A, angolo α (gon, orario) dalla direzione A→R, distanza d
function puntoAngoloDistanza(a, r, alfaGon, d) {
    return irradia(a, normGon(inversa(a, r).az + alfaGon), d);
}

// Punto di calcolo → EPSG:6706 + H (se H manca, usa la quota dell'origine)
function aGeografiche(p, o) {
    var H = (p.H === null || p.H === undefined) ? o.H : p.H;
    return fromENU(p.e, p.n, H, o);
}
