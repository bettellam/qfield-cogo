import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Layouts
import org.qgis
import org.qfield.core
import org.qfield.gui
import "cogo_enu.js" as Cogo

// COGO linea A-B — prototipo
// A e B si scelgono toccando la mappa: vale il punto del layer attivo più vicino al tocco.
// Calcolo su piano ENU con origine in A; N0 dal grigliato di QField se impostato.
// I punti calcolati vanno nel layer cogo_point (cogo_point.gpkg nella cartella del progetto).
Item {
  id: plugin

  property var mainWindow: iface.mainWindow()
  property var mapCanvas: iface.mapCanvas()

  property var crs6706: QfCoordinateReferenceSystemUtils.fromDescription("EPSG:6706")

  // {fid, x, y, z, haZ, tipo ("H" ortometrica | "h" ellissoidica), sorgente, lat, lon, layer}
  property var puntoA: null
  property var puntoB: null
  // Punto P per il piede della perpendicolare (dal layer attivo, può essere di un altro layer)
  property var puntoP: null
  // {operazione, parametro, scostamento, n0, nota, punti: [{lat, lon, H, quota, progressiva, descrizione}]}
  property var calcolo: null
  onCalcoloChanged: aggiornaAnteprima()
  property string testoAB: ""
  // Punto che il prossimo tocco sulla mappa imposterà: "A", "B", "P" o "" (tocchi a QField)
  property string attesa: ""

  // Configurazione persistente del plugin (pulsante di configurazione nel gestore plugin di QField)
  Settings {
    id: configurazione
    category: "cogo_linea"
    // "gon" centesimale, "deg" sessadecimale, "dms" sessagesimale (gradi-primi-secondi)
    property string unitaAngoli: "deg"
    // Quota per layer, JSON { "nome layer": { sorgente: "" (Z della geometria) o nome del campo, tipo: "H" | "h" } }
    property string quoteLayer: "{}"
  }
  property string unitaAngoli: configurazione.unitaAngoli

  readonly property string nomeCogoLayer: "cogo_point"
  readonly property string nomeGestoreTocchi: "cogo_linea"
  readonly property real tolleranzaPixel: 15

  // ---------- Supporto ----------

  function avviso(messaggio) {
    mainWindow.displayToast(messaggio);
  }

  // Layer attivo di QField (scelto nella legenda), aggiornato automaticamente
  property var dashBoard: iface.findItemByObjectName("dashBoard")
  property var layerCorrente: dashBoard ? dashBoard.activeLayer : null

  function layerAttivo() {
    return layerCorrente;
  }

  // Vero solo per un layer vettoriale di punti (un raster non ha geometryType)
  function layerDiPunti(layer) {
    return !!layer && typeof layer.geometryType === "function" && layer.geometryType() === Qgis.GeometryType.Point;
  }

  function fmt(v, dec) {
    if (v === null || v === undefined || isNaN(v))
      return "—";
    var t = Number(v).toFixed(dec);
    // Evita "-0.000" per valori negativi che si arrotondano a zero
    return Number(t) === 0 ? Math.abs(Number(t)).toFixed(dec) : t;
  }

  // Lettore di geometrie: pointList() restituisce i QgsPoint con la Z
  QfGeometryWrapper {
    id: lettore
  }

  // Trasformatore usato solo per leggere N dal grigliato di QField (vgridshift):
  // con h = 0 in ingresso la quota in uscita vale -N.
  CoordinateTransformer {
    id: geoide
    sourceCrs: QfCoordinateReferenceSystemUtils.wgs84Crs()
    destinationCrs: QfCoordinateReferenceSystemUtils.wgs84Crs()
    transformContext: qgisProject ? qgisProject.transformContext : QfCoordinateReferenceSystemUtils.emptyTransformContext()
    deltaZ: 0
  }

  function leggiN0(lat, lon) {
    var impostazioni = iface.findItemByObjectName("positioningSettings");
    var grigliato = impostazioni ? impostazioni.verticalGrid : "";
    if (!impostazioni)
      return { valore: 0, grigliato: "", letto: false, motivo: qsTr("impostazioni GNSS non trovate") };
    if (!grigliato)
      return { valore: 0, grigliato: "", letto: false, motivo: qsTr("nessun grigliato impostato") };
    geoide.verticalGrid = grigliato;
    geoide.sourcePosition = QfGeometryUtils.point(lon, lat, 0);
    var z = geoide.projectedPosition.z;
    if (!isFinite(z) || Math.abs(z) < 1e-6)
      return { valore: 0, grigliato: grigliato, letto: false, motivo: qsTr("lettura di %1 fallita (z=%2)").arg(grigliato).arg(z) };
    return { valore: -z, grigliato: grigliato, letto: true };
  }

  // ---------- Quote: sorgente e tipo ----------
  // Ogni layer dichiara da dove viene la quota (Z della geometria o un campo) e se è
  // ortometrica H o ellissoidica h. Senza configurazione: Z della geometria, ortometrica.
  // Il risultato ha la quota dello stesso tipo dei punti A/B.

  function configQuota(layer) {
    var tutte = {};
    try {
      tutte = JSON.parse(configurazione.quoteLayer) || {};
    } catch (e) {
      tutte = {};
    }
    var c = layer ? tutte[layer.name] : null;
    return { sorgente: c && c.sorgente ? c.sorgente : "", tipo: c && c.tipo === "h" ? "h" : "H" };
  }

  function impostaConfigQuota(layer, sorgente, tipo) {
    var tutte = {};
    try {
      tutte = JSON.parse(configurazione.quoteLayer) || {};
    } catch (e) {
      tutte = {};
    }
    tutte[layer.name] = { sorgente: sorgente, tipo: tipo };
    configurazione.quoteLayer = JSON.stringify(tutte);
    // Le quote di A, B e P sono state lette con la configurazione precedente
    puntoA = null;
    puntoB = null;
    puntoP = null;
    calcolo = null;
    testoAB = "";
  }

  function nomeTipo(tipo) {
    return tipo === "h" ? qsTr("h ellissoidica") : qsTr("H ortometrica");
  }

  // Descrizione breve per la riga di stato, es. "h da Z" o "H da Q_Geoid_E00"
  function testoConfigQuota(layer) {
    var c = configQuota(layer);
    return c.tipo + qsTr(" da ") + (c.sorgente === "" ? "Z" : c.sorgente);
  }

  // Nomi dei campi del layer (per la scelta della sorgente della quota)
  function nomiCampi(layer) {
    var nomi = [];
    if (!layer || !layer.fields)
      return nomi;
    var fs = layer.fields;
    try {
      var n = typeof fs.names === "function" ? fs.names() : fs.names;
      if (n && n.length !== undefined) {
        for (var i = 0; i < n.length; i++)
          nomi.push(String(n[i]));
        return nomi;
      }
    } catch (e) {}
    try {
      var c = typeof fs.count === "function" ? fs.count() : fs.count;
      for (var j = 0; j < c; j++)
        nomi.push(String(fs.at(j).name));
    } catch (e2) {}
    return nomi;
  }

  // Valore di un campo della feature (null se il campo manca o è vuoto)
  function valoreCampo(f, layer, nome) {
    var i = layer.fields.indexFromName(nome);
    if (i < 0)
      return null;
    var v;
    try {
      v = f.attribute(nome);
    } catch (e) {
      v = f.attributes[i];
    }
    return (v === null || v === undefined || v === "") ? null : v;
  }

  // Quota del punto p convertita nel tipo richiesto, con il N del grigliato nel punto
  function quotaNelTipo(p, tipo) {
    if (!p.haZ)
      return 0;
    if (p.tipo === tipo)
      return p.z;
    var n = leggiN0(p.lat, p.lon);
    if (!n.letto)
      throw new Error(qsTr("Il punto fid %1 ha quota %2, A ha quota %3: per convertire serve il grigliato verticale (%4)").arg(p.fid).arg(nomeTipo(p.tipo)).arg(nomeTipo(tipo)).arg(n.motivo));
    // h = H + N
    return tipo === "h" ? p.z + n.valore : p.z - n.valore;
  }

  // ---------- Scelta di A e B ----------

  // Cerca nel layer il punto più vicino a pMappa (coordinate mappa), entro la tolleranza
  function trovaPunto(layer, pMappa) {
    var ms = mapCanvas.mapSettings;
    var crsMappa = ms.destinationCrs;
    var tol = tolleranzaPixel * ms.mapUnitsPerPoint;
    var rettangolo = QfGeometryUtils.createRectangleFromPoints(QfGeometryUtils.point(pMappa.x - tol, pMappa.y - tol), QfGeometryUtils.point(pMappa.x + tol, pMappa.y + tol));
    var it = QfLayerUtils.createFeatureIteratorFromRectangle(layer, QfGeometryUtils.reprojectRectangle(rettangolo, crsMappa, layer.crs));
    var migliore = null;
    var dMin = Infinity;
    while (it.hasNext()) {
      var f = it.next();
      lettore.qgsGeometry = f.geometry;
      var punti = lettore.pointList();
      if (punti.length === 0)
        continue;
      var q = punti[0];
      var qm = QfGeometryUtils.reprojectPoint(QfGeometryUtils.point(q.x, q.y), layer.crs, crsMappa);
      var d = Math.hypot(qm.x - pMappa.x, qm.y - pMappa.y);
      if (d <= tol && d < dMin) {
        dMin = d;
        migliore = { fid: f.id, x: q.x, y: q.y, z: q.z };
        var cfg = configQuota(layer);
        migliore.sorgente = cfg.sorgente;
        migliore.tipo = cfg.tipo;
        if (cfg.sorgente !== "") {
          var v = valoreCampo(f, layer, cfg.sorgente);
          migliore.z = v === null ? NaN : Number(v);
        }
        // Nei punti di cogo_point il tipo è scritto in ogni punto (campo quota_rif)
        if (layer.name === nomeCogoLayer) {
          var rif = valoreCampo(f, layer, "quota_rif");
          if (rif !== null)
            migliore.tipo = String(rif).charAt(0) === "h" ? "h" : "H";
        }
      }
    }
    it.close();
    if (!migliore)
      return null;
    var g = QfGeometryUtils.reprojectPoint(QfGeometryUtils.point(migliore.x, migliore.y), layer.crs, crs6706);
    migliore.lon = g.x;
    migliore.lat = g.y;
    migliore.haZ = migliore.z !== undefined && !isNaN(migliore.z);
    migliore.layer = layer;
    return migliore;
  }

  // Pulsanti A / B: il prossimo tocco sulla mappa imposta quel punto
  function attendi(quale) {
    var layer = layerAttivo();
    if (!layerDiPunti(layer)) {
      avviso(qsTr("Scegli come layer attivo il layer di punti del rilievo"));
      attesa = "";
      return;
    }
    attesa = attesa === quale ? "" : quale;
  }

  // Gestore dei tocchi registrato nel pointHandler di QField.
  // Restituisce true quando il tocco è usato dal plugin (QField non fa altro).
  function gestisciTocco(punto, tipo, interazione) {
    if (!pannello.visible || attesa === "" || interazione !== "clicked")
      return false;
    var layer = layerAttivo();
    if (!layerDiPunti(layer)) {
      avviso(qsTr("Il layer attivo non è un layer di punti"));
      return true;
    }
    var p = trovaPunto(layer, mapCanvas.mapSettings.screenToCoordinate(punto));
    if (!p) {
      avviso(qsTr("Nessun punto di \"%1\" vicino al tocco").arg(layer.name));
      return true;
    }
    if (attesa === "P") {
      puntoP = p;
      attesa = "";
      calcolo = null;
      aggiornaAnteprima();
      return true;
    }
    var altro = attesa === "A" ? puntoB : puntoA;
    if (altro && altro.layer !== layer) {
      // Cambio di layer: si ricomincia da questo punto
      puntoA = null;
      puntoB = null;
    }
    if (attesa === "A") {
      puntoA = p;
      attesa = puntoB ? "" : "B";
    } else {
      puntoB = p;
      attesa = puntoA ? "" : "A";
    }
    calcolo = null;
    aggiornaAB();
    aggiornaAnteprima();
    return true;
  }

  function testoPunto(p) {
    if (!p)
      return qsTr("non impostato");
    return "fid " + p.fid + " · " + p.tipo + " " + (p.haZ ? fmt(p.z, 3) : qsTr("assente"));
  }

  // ---------- Calcolo ----------

  // Origine del piano in A, ricalcolata a ogni operazione.
  // Le quote sono tutte nel tipo di A (H o h); B e P si convertono se hanno un tipo diverso.
  // cogo_enu.js lavora con h = quota + N0: per quote ellissoidiche N0 = 0.
  function pianoAB() {
    var tipo = puntoA.tipo;
    var n0 = leggiN0(puntoA.lat, puntoA.lon);
    var HA = quotaNelTipo(puntoA, tipo);
    var HB = quotaNelTipo(puntoB, tipo);
    var o = Cogo.makeOrigin(puntoA.lat, puntoA.lon, HA, tipo === "h" ? 0 : n0.valore, n0.grigliato);
    return {
      o: o,
      n0: n0,
      tipo: tipo,
      a: Cogo.punto(puntoA.lat, puntoA.lon, HA, o),
      b: Cogo.punto(puntoB.lat, puntoB.lon, HB, o),
      p: puntoP ? Cogo.punto(puntoP.lat, puntoP.lon, quotaNelTipo(puntoP, tipo), o) : null,
      conQuote: puntoA.haZ && puntoB.haZ
    };
  }

  function aggiornaAB() {
    testoAB = "";
    if (!puntoA || !puntoB)
      return;
    try {
      var piano = pianoAB();
      var inv = Cogo.inversa(piano.a, piano.b);
      testoAB = "AB " + fmt(inv.d, 3) + " m al suolo · Δ" + piano.tipo + " " + (piano.conQuote ? fmt(piano.b.H - piano.a.H, 3) : "—") + "\nN₀ " + (piano.n0.letto ? fmt(piano.n0.valore, 3) + " m (" + piano.n0.grigliato + ")" : qsTr("non disponibile (0): ") + piano.n0.motivo);
    } catch (e) {
      testoAB = qsTr("Errore: ") + e.message;
    }
  }

  // Operazioni sulla retta A-B. "parametro"/"parametro2" vuoti = nessun valore da inserire;
  // "conP" = serve il punto P.
  readonly property var operazioni: [
    { codice: "medio", testo: qsTr("Punto medio"), parametro: "", parametro2: "", conP: false },
    { codice: "dist_A", testo: qsTr("Distanza x da A"), parametro: qsTr("x da A (m)"), parametro2: "", conP: false },
    { codice: "dist_B", testo: qsTr("Distanza x da B"), parametro: qsTr("x da B (m)"), parametro2: "", conP: false },
    { codice: "div_N", testo: qsTr("Divisione in N parti"), parametro: qsTr("N parti"), parametro2: "", conP: false },
    { codice: "passo_A", testo: qsTr("Un punto ogni x m da A"), parametro: qsTr("passo (m)"), parametro2: "", conP: false },
    { codice: "passo_B", testo: qsTr("Un punto ogni x m da B"), parametro: qsTr("passo (m)"), parametro2: "", conP: false },
    { codice: "prog_off", testo: qsTr("Progressiva e scostamento"), parametro: qsTr("x da A (m)"), parametro2: qsTr("scostamento y (m, + a destra di A→B)"), conP: false },
    { codice: "piede_P", testo: qsTr("Piede della perpendicolare da P"), parametro: "", parametro2: "", conP: true },
    { codice: "ang_dist", testo: qsTr("Angolo e distanza da A"), parametro: qsTr("α (%U, orario da A→B; negativo = antiorario)"), parametro2: qsTr("distanza d da A (m)"), conP: false, angolo: true },
    { codice: "dist_dist", testo: qsTr("Intersezione distanza-distanza"), parametro: qsTr("d₁ da A (m)"), parametro2: qsTr("d₂ da B (m)"), conP: false, conLato: true }
  ]

  // Quota di un punto fuori retta: interpolata sulla sua proiezione su A-B
  function quotaDaRetta(a, b, p) {
    var r = Cogo.piedePerpendicolare(a, b, p);
    p.H = r.piede.H;
    p.quota = r.interno ? "interpolata" : "da A/B (fuori segmento)";
    return r;
  }

  function lato(y) {
    return Math.abs(y) < 0.0005 ? qsTr("sulla retta") : fmt(Math.abs(y), 3) + " m " + (y > 0 ? qsTr("a destra") : qsTr("a sinistra"));
  }
  readonly property int massimoPunti: 1000

  // ---------- Unità angolari ----------
  // Il calcolo (cogo_enu.js) lavora sempre in gon: la conversione avviene solo in ingresso e in uscita.

  function nomeUnita() {
    return unitaAngoli === "gon" ? "gon" : unitaAngoli === "dms" ? qsTr("° ' \", es. 12 34 56.7") : "°";
  }

  // Sostituisce %U nelle etichette con l'unità angolare scelta
  function etichetta(testo) {
    return testo.replace("%U", nomeUnita());
  }

  // Angolo dal campo di testo nell'unità scelta → gon (NaN se non valido).
  // Sessagesimale: gradi, primi e secondi separati da spazi o da ° ' " : (es. 12 34 56.7 oppure 12°34'56.7").
  function leggiAngolo(testo) {
    if (unitaAngoli === "gon")
      return leggiNumero(testo);
    if (unitaAngoli === "deg")
      return leggiNumero(testo) * 400 / 360;
    var t = String(testo).trim().replace(/,/g, ".");
    var segno = 1;
    if (t.charAt(0) === "-") {
      segno = -1;
      t = t.substring(1);
    }
    var parti = t.split(/[\s°'"′″:;]+/).filter(function (x) { return x !== ""; });
    if (parti.length < 1 || parti.length > 3)
      return NaN;
    var g = Number(parti[0]), m = parti.length > 1 ? Number(parti[1]) : 0, sec = parti.length > 2 ? Number(parti[2]) : 0;
    if (!isFinite(g) || !isFinite(m) || !isFinite(sec) || m < 0 || m >= 60 || sec < 0 || sec >= 60)
      return NaN;
    if (parti.length > 1 && Math.floor(g) !== g)
      return NaN;
    if (parti.length > 2 && Math.floor(m) !== m)
      return NaN;
    return segno * (g + m / 60 + sec / 3600) * 400 / 360;
  }

  // Angolo in gon → testo nell'unità scelta; "preciso" per i valori inseriti, altrimenti arrotondato
  function testoAngolo(gon, preciso) {
    if (unitaAngoli === "gon")
      return fmt(gon, preciso ? 4 : 1) + " gon";
    var gradi = gon * 360 / 400;
    if (unitaAngoli === "deg")
      return fmt(gradi, preciso ? 5 : 1) + "°";
    var segno = gradi < 0 ? "-" : "";
    var decimi = preciso ? 10 : 1;  // secondi a 0.1" o interi
    var tot = Math.round(Math.abs(gradi) * 3600 * decimi);
    var g = Math.floor(tot / (3600 * decimi));
    var m = Math.floor((tot - g * 3600 * decimi) / (60 * decimi));
    var sec = (tot - g * 3600 * decimi - m * 60 * decimi) / decimi;
    return segno + g + "°" + (m < 10 ? "0" : "") + m + "'" + (sec < 10 ? "0" : "") + sec.toFixed(preciso ? 1 : 0) + "\"";
  }

  // Valore dell'angolo da salvare nel campo numerico "parametro": gon, oppure gradi decimali
  function angoloDaSalvare(gon) {
    return unitaAngoli === "gon" ? gon : gon * 360 / 400;
  }

  // Numero dal campo di testo, accettando anche la virgola decimale
  function leggiNumero(testo) {
    var t = String(testo).trim().replace(",", ".");
    return t === "" ? NaN : Number(t);
  }

  // Esegue l'operazione scelta e prepara "calcolo" per anteprima e salvataggio
  function calcola(codice, testoParametro, testoParametro2) {
    calcolo = null;
    if (!puntoA || !puntoB)
      return;
    try {
      var piano = pianoAB();
      var a = piano.a, b = piano.b;
      var L = Cogo.inversa(a, b).d;
      var v = leggiNumero(testoParametro);
      var fA = puntoA.fid, fB = puntoB.fid;
      var punti = [];  // {p (ENU), progressiva, descrizione}
      var nota = "";
      var scostamento = null;
      var k;

      if (codice === "medio") {
        punti.push({ p: Cogo.puntoMedio(a, b), progressiva: L / 2, descrizione: "punto medio tra " + fA + " e " + fB });
        v = null;
      } else if (codice === "dist_A" || codice === "dist_B") {
        if (!isFinite(v))
          throw new Error(qsTr("Inserisci la distanza x in metri"));
        var daA = codice === "dist_A";
        var p = daA ? Cogo.puntoSuAllineamento(a, b, v, 0) : Cogo.puntoSuAllineamento(b, a, v, 0);
        var prog = daA ? v : L - v;
        var fuori = prog < 0 || prog > L;
        punti.push({ p: p, progressiva: prog, descrizione: "a " + fmt(v, 3) + " m da " + (daA ? "A (" + fA + ") verso B (" + fB + ")" : "B (" + fB + ") verso A (" + fA + ")") + (fuori ? ", fuori segmento" : "") });
      } else if (codice === "div_N") {
        if (!(v >= 2) || Math.floor(v) !== v)
          throw new Error(qsTr("N deve essere un intero almeno 2"));
        if (v - 1 > massimoPunti)
          throw new Error(qsTr("Troppi punti (massimo %1)").arg(massimoPunti));
        var div = Cogo.dividi(a, b, v);
        for (k = 0; k < div.length; k++)
          punti.push({ p: div[k], progressiva: div[k].indice * L / v, descrizione: "divisione " + fA + "-" + fB + " in " + v + " parti: " + div[k].indice + "/" + v });
      } else if (codice === "passo_A" || codice === "passo_B") {
        if (!(v > 0))
          throw new Error(qsTr("Il passo deve essere maggiore di 0"));
        if (L / v > massimoPunti)
          throw new Error(qsTr("Troppi punti (massimo %1)").arg(massimoPunti));
        var daA2 = codice === "passo_A";
        var r = daA2 ? Cogo.dividiIntervallo(a, b, v) : Cogo.dividiIntervallo(b, a, v);
        for (k = 0; k < r.punti.length; k++) {
          var q = r.punti[k];
          punti.push({ p: q, progressiva: daA2 ? q.progressiva : L - q.progressiva, descrizione: "ogni " + fmt(v, 3) + " m da " + (daA2 ? "A (" + fA + ")" : "B (" + fB + ")") + ": n. " + q.indice + " a " + fmt(q.progressiva, 3) + " m" });
        }
        nota = qsTr("resto %1 m prima di %2").arg(fmt(r.resto, 3)).arg(daA2 ? "B" : "A");
        if (punti.length === 0)
          throw new Error(qsTr("Passo maggiore della distanza AB"));
      } else if (codice === "prog_off") {
        var y = leggiNumero(testoParametro2);
        if (!isFinite(v) || !isFinite(y))
          throw new Error(qsTr("Inserisci progressiva x e scostamento y in metri"));
        var po = Cogo.puntoSuAllineamento(a, b, v, y);
        punti.push({ p: po, progressiva: v, descrizione: "progressiva " + fmt(v, 3) + " m da A (" + fA + ") verso B (" + fB + "), " + lato(y) + ((v < 0 || v > L) ? ", fuori segmento" : "") });
        scostamento = y;
      } else if (codice === "piede_P") {
        if (!piano.p)
          throw new Error(qsTr("Scegli il punto P toccandolo sulla mappa"));
        var pp = Cogo.piedePerpendicolare(a, b, piano.p);
        if (!pp.interno)
          pp.piede.quota = "da A/B (fuori segmento)";
        punti.push({ p: pp.piede, progressiva: pp.progressiva, descrizione: "piede da P (" + puntoP.fid + ") su " + fA + "-" + fB + ": P a " + lato(pp.offset) + (pp.interno ? "" : ", fuori segmento") });
        nota = qsTr("P: progressiva %1 m, %2").arg(fmt(pp.progressiva, 3)).arg(lato(pp.offset));
        v = null;
        scostamento = pp.offset;
      } else if (codice === "ang_dist") {
        var alfa = leggiAngolo(testoParametro);
        var d = leggiNumero(testoParametro2);
        if (!isFinite(alfa) || !(d > 0))
          throw new Error(qsTr("Inserisci l'angolo α (%1) e la distanza d in metri").arg(nomeUnita()));
        var pa = Cogo.puntoAngoloDistanza(a, b, alfa, d);
        var ra = quotaDaRetta(a, b, pa);
        punti.push({ p: pa, progressiva: ra.progressiva, descrizione: "da A (" + fA + "): α " + testoAngolo(alfa, true) + " da A→B (" + fB + "), d " + fmt(d, 3) + " m, " + lato(ra.offset) });
        scostamento = ra.offset;
        v = angoloDaSalvare(alfa);
      } else if (codice === "dist_dist") {
        var d2 = leggiNumero(testoParametro2);
        if (!(v > 0) || !(d2 > 0))
          throw new Error(qsTr("Inserisci le distanze d₁ da A e d₂ da B in metri"));
        var sol = Cogo.intDistDist(a, v, b, d2);
        var latoScelto = sceltaLato.currentIndex === 0 ? "sinistra" : "destra";
        var pi = sol[latoScelto];
        var ri = quotaDaRetta(a, b, pi);
        punti.push({ p: pi, progressiva: ri.progressiva, descrizione: "intersezione d₁ " + fmt(v, 3) + " m da A (" + fA + "), d₂ " + fmt(d2, 3) + " m da B (" + fB + "), " + (latoScelto === "sinistra" ? "sx" : "dx") + " di A→B" });
        scostamento = ri.offset;
        // Angolo d'intersezione in P tra le direzioni verso A e verso B: ottimale vicino a 100 gon
        var gAng = Math.abs(Cogo.inversa(pi, a).az - Cogo.inversa(pi, b).az);
        var angolo = gAng > 200 ? 400 - gAng : gAng;
        nota = qsTr("angolo d'intersezione %1").arg(testoAngolo(angolo, false)) + ((angolo < 60 || angolo > 140) ? qsTr(" — sfavorevole") : "");
      }

      var risultati = [];
      for (k = 0; k < punti.length; k++) {
        var g = Cogo.aGeografiche(punti[k].p, piano.o);
        risultati.push({
          lat: g.lat,
          lon: g.lon,
          H: g.H,
          quota: piano.conQuote ? punti[k].p.quota : "da assegnare",
          progressiva: punti[k].progressiva,
          descrizione: punti[k].descrizione
        });
      }
      calcolo = { operazione: codice, parametro: v, scostamento: scostamento, n0: piano.n0, tipo: piano.tipo, conQuote: piano.conQuote, punti: risultati, nota: nota };
    } catch (e) {
      avviso(e.message);
    }
    aggiornaAnteprima();
  }

  function testoCalcolo() {
    if (!calcolo)
      return "";
    var n = calcolo.punti.length;
    var righe = [];
    for (var k = 0; k < Math.min(n, 4); k++) {
      var r = calcolo.punti[k];
      righe.push(r.descrizione + " · " + calcolo.tipo + " " + fmt(r.H, 3) + " (" + r.quota + ")");
    }
    if (n > 4)
      righe.push("… " + qsTr("altri %1 punti").arg(n - 4));
    if (calcolo.nota)
      righe.push(calcolo.nota);
    return (n === 1 ? qsTr("1 punto") : qsTr("%1 punti").arg(n)) + "\n" + righe.join("\n");
  }

  // ---------- Layer cogo_point ----------

  // Nel progetto, altrimenti dal file nella cartella del progetto, altrimenti lo crea
  function trovaOCreaCogoLayer(crs) {
    var layers = QfProjectUtils.mapLayers(qgisProject);
    for (var id in layers) {
      if (layers[id].name === nomeCogoLayer) {
        traccia("cogo_point trovato nel progetto");
        return layers[id];
      }
    }
    var percorso = qgisProject.homePath + "/" + nomeCogoLayer + ".gpkg";
    if (!QfFileUtils.fileExists(percorso)) {
      var campi = QfFeatureUtils.createFields([
        QfFeatureUtils.createField("descrizione", QfFeatureUtils.String, "", 254),
        QfFeatureUtils.createField("operazione", QfFeatureUtils.String, "", 20),
        QfFeatureUtils.createField("parametro", QfFeatureUtils.Double),
        QfFeatureUtils.createField("fid_A", QfFeatureUtils.Int),
        QfFeatureUtils.createField("fid_B", QfFeatureUtils.Int),
        QfFeatureUtils.createField("progressiva", QfFeatureUtils.Double),
        QfFeatureUtils.createField("scostamento", QfFeatureUtils.Double),
        QfFeatureUtils.createField("quota_tipo", QfFeatureUtils.String, "", 30),
        QfFeatureUtils.createField("quota_rif", QfFeatureUtils.String, "", 20),
        // Nomi distinti non solo per maiuscole: in GeoPackage (SQLite) quota_H e quota_h sarebbero la stessa colonna
        QfFeatureUtils.createField("H_elliss", QfFeatureUtils.Double),
        QfFeatureUtils.createField("Q_geoide", QfFeatureUtils.Double),
        QfFeatureUtils.createField("n0", QfFeatureUtils.Double),
        QfFeatureUtils.createField("gruppo", QfFeatureUtils.String, "", 40),
        QfFeatureUtils.createField("data", QfFeatureUtils.DateTime)]);
      var memoria = QfLayerUtils.createMemoryLayer(nomeCogoLayer, campi, Qgis.WkbType.PointZ, crs);
      var creato = QfLayerUtils.saveVectorLayerAs(memoria, percorso, "GPKG", "");
      traccia("creato: " + creato);
      if (!creato)
        return null;
    }
    var layer = QfLayerUtils.loadVectorLayer(percorso + "|layername=" + nomeCogoLayer, nomeCogoLayer, "ogr");
    traccia("caricato: " + percorso + " valido=" + (layer ? layer.isValid : "null"));
    if (!layer || !layer.isValid)
      return null;
    QfProjectUtils.addMapLayer(qgisProject, layer);
    return layer;
  }

  function traccia(messaggio) {
    iface.logMessage("[cogo_linea] " + messaggio);
  }

  function salva() {
    if (!calcolo || calcolo.punti.length === 0 || !puntoA || !puntoB)
      return;
    try {
      salvaCalcolo();
    } catch (e) {
      traccia("errore: " + e + (e.stack ? "\n" + e.stack : ""));
      avviso(qsTr("Errore nel salvataggio: ") + e.message);
    }
  }

  // Scrive tutti i punti del calcolo in una sola sessione di modifica:
  // o vengono salvati tutti, o nessuno.
  function salvaCalcolo() {
    var cogo = trovaOCreaCogoLayer(puntoA.layer.crs);
    if (!cogo) {
      avviso(qsTr("Impossibile aprire o creare cogo_point.gpkg"));
      return;
    }
    var ora = new Date();
    var gruppo = calcolo.operazione + "_" + ora.getTime();
    // cogo_point.gpkg creato da una versione precedente: i campi nuovi mancano e non vengono scritti
    var mancanti = ["quota_rif", "H_elliss", "Q_geoide"].filter(function (nome) { return cogo.fields.indexFromName(nome) < 0; });
    if (mancanti.length > 0)
      avviso(qsTr("cogo_point non ha i campi %1: per averli elimina cogo_point.gpkg, verrà ricreato").arg(mancanti.join(", ")));

    // Il layer va messo in modifica esplicitamente: alcune versioni di
    // QfLayerUtils.addFeature non lo fanno da sole e restituiscono false.
    var giaInModifica = !!cogo.editBuffer();
    if (!giaInModifica && !cogo.startEditing()) {
      traccia("startEditing non riuscito");
      avviso(qsTr("Impossibile modificare cogo_point"));
      return;
    }
    for (var k = 0; k < calcolo.punti.length; k++) {
      var r = calcolo.punti[k];
      var p = QfGeometryUtils.reprojectPoint(QfGeometryUtils.point(r.lon, r.lat), crs6706, cogo.crs);
      var H = r.quota === "da assegnare" ? 0 : r.H;
      // N del grigliato nel punto: permette di scrivere entrambe le quote H e h
      var nPunto = calcolo.conQuote ? leggiN0(r.lat, r.lon) : { letto: false, valore: 0 };
      // La Z ha il tipo configurato; l'altra quota si ricava solo con il grigliato (altrimenti null)
      var quotaGeoide = !calcolo.conQuote ? null : calcolo.tipo === "H" ? H : nPunto.letto ? H - nPunto.valore : null;
      var quotaElliss = !calcolo.conQuote ? null : calcolo.tipo === "h" ? H : nPunto.letto ? H + nPunto.valore : null;
      var f = QfFeatureUtils.createBlankFeature(cogo.fields, QfGeometryUtils.createGeometryFromWkt("PointZ (" + p.x + " " + p.y + " " + H + ")"));
      var valori = {
        "descrizione": r.descrizione,
        "operazione": calcolo.operazione,
        "parametro": calcolo.parametro,
        "fid_A": puntoA.fid,
        "fid_B": puntoB.fid,
        "progressiva": r.progressiva,
        "scostamento": calcolo.scostamento,
        "quota_tipo": r.quota,
        "quota_rif": nomeTipo(calcolo.tipo),
        "H_elliss": quotaElliss,
        "Q_geoide": quotaGeoide,
        "n0": nPunto.letto ? nPunto.valore : (calcolo.n0.letto ? calcolo.n0.valore : null),
        "gruppo": gruppo,
        "data": ora
      };
      for (var nome in valori) {
        var i = cogo.fields.indexFromName(nome);
        if (i >= 0 && valori[nome] !== null && valori[nome] !== undefined)
          f.setAttribute(i, valori[nome]);
      }
      if (!QfLayerUtils.addFeature(cogo, f)) {
        traccia("addFeature non riuscito al punto " + (k + 1) + ": " + r.descrizione);
        if (!giaInModifica)
          cogo.rollBack();
        avviso(qsTr("Scrittura in cogo_point non riuscita (vedi registro messaggi)"));
        return;
      }
    }
    if (!giaInModifica && !cogo.commitChanges()) {
      traccia("commitChanges non riuscito" + (typeof cogo.commitErrors === "function" ? ": " + cogo.commitErrors() : ""));
      cogo.rollBack();
      avviso(qsTr("Salvataggio in cogo_point non riuscito (vedi registro messaggi)"));
      return;
    }
    var n = calcolo.punti.length;
    traccia(n + " punti salvati, gruppo " + gruppo);
    avviso(n === 1 ? qsTr("Punto salvato in cogo_point") : qsTr("%1 punti salvati in cogo_point").arg(n));
    calcolo = null;
    aggiornaAnteprima();
  }

  // ---------- Anteprima sulla mappa ----------

  function aggiornaAnteprima() {
    var ab = [];
    if (puntoA)
      ab.push("(" + puntoA.lon + " " + puntoA.lat + ")");
    if (puntoB)
      ab.push("(" + puntoB.lon + " " + puntoB.lat + ")");
    if (ab.length > 0) {
      anteprimaAB.geometryWrapper.crs = crs6706;
      anteprimaAB.geometryWrapper.qgsGeometry = QfGeometryUtils.createGeometryFromWkt("MultiPoint (" + ab.join(",") + ")");
    } else {
      anteprimaAB.geometryWrapper.clear();
    }
    if (puntoP) {
      anteprimaP.geometryWrapper.crs = crs6706;
      anteprimaP.geometryWrapper.qgsGeometry = QfGeometryUtils.createGeometryFromWkt("MultiPoint ((" + puntoP.lon + " " + puntoP.lat + "))");
    } else {
      anteprimaP.geometryWrapper.clear();
    }
    if (calcolo && calcolo.punti.length > 0) {
      var pr = [];
      for (var k = 0; k < calcolo.punti.length; k++)
        pr.push("(" + calcolo.punti[k].lon + " " + calcolo.punti[k].lat + ")");
      anteprimaRisultato.geometryWrapper.crs = crs6706;
      anteprimaRisultato.geometryWrapper.qgsGeometry = QfGeometryUtils.createGeometryFromWkt("MultiPoint (" + pr.join(",") + ")");
    } else {
      anteprimaRisultato.geometryWrapper.clear();
    }
  }

  QfGeometryRenderer {
    id: anteprimaAB
    parent: plugin.mapCanvas
    visible: pannello.visible
    mapSettings: plugin.mapCanvas.mapSettings
    color: "#1e88e5"
    pointSize: 18
  }

  QfGeometryRenderer {
    id: anteprimaP
    parent: plugin.mapCanvas
    visible: pannello.visible && operazioni[sceltaOperazione.currentIndex].conP
    mapSettings: plugin.mapCanvas.mapSettings
    color: "#8e24aa"
    pointSize: 18
  }

  QfGeometryRenderer {
    id: anteprimaRisultato
    parent: plugin.mapCanvas
    visible: pannello.visible
    mapSettings: plugin.mapCanvas.mapSettings
    color: "#d81b60"
    pointSize: 14
  }

  // ---------- Interfaccia ----------

  QfToolButton {
    id: pulsantePlugin
    iconSource: Qt.resolvedUrl("icon.svg")
    iconColor: QfTheme.toolButtonColor
    bgcolor: QfTheme.toolButtonBackgroundColor
    round: true

    onPressAndHold: configure()

    onClicked: {
      pannello.visible = !pannello.visible;
      pannello.ridotto = false;
      if (pannello.visible && !puntoA)
        attendi("A");
      if (!pannello.visible)
        attesa = "";
    }
  }

  Rectangle {
    id: pannello
    parent: plugin.mainWindow.contentItem
    visible: false
    z: 1000
    width: Math.min(420, parent.width - 32)
    height: colonna.implicitHeight + 20
    // Altezza comune di pulsanti, combo e campi: più bassa dei 48 px standard per non coprire la mappa
    readonly property int altezzaControlli: 30
    // Ridotto: resta solo la barra del titolo
    property bool ridotto: false
    // Posizione iniziale: in alto al centro. Trascinandolo, il pannello resta dove lo si lascia.
    x: (parent.width - width) / 2
    y: 64
    radius: 8
    color: QfTheme.mainBackgroundColor
    border.color: QfTheme.controlBorderColor

    // Parte del pannello che resta sempre sullo schermo, per poterlo riprendere
    readonly property int margineVisibile: 60

    // Trascina il pannello toccando un punto libero; blocca anche i tocchi verso la mappa.
    // Può uscire in parte dallo schermo su ogni lato, lasciando visibili almeno margineVisibile px.
    MouseArea {
      anchors.fill: parent
      cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      drag.target: pannello
      drag.threshold: 4
      drag.minimumX: pannello.margineVisibile - pannello.width
      drag.maximumX: pannello.parent.width - pannello.margineVisibile
      drag.minimumY: pannello.margineVisibile - pannello.height
      drag.maximumY: pannello.parent.height - pannello.margineVisibile
    }

    ColumnLayout {
      id: colonna
      anchors.fill: parent
      anchors.margins: 10
      spacing: 4

      RowLayout {
        Layout.fillWidth: true
        // Riduci / ripristina il pannello per liberare la mappa. Icone disegnate: i glifi mancano nei font Android.
        // Aperto: barra orizzontale (riduci); ridotto: quadrato (ripristina).
        Item {
          implicitWidth: 32
          implicitHeight: 28
          Rectangle {
            visible: !pannello.ridotto
            anchors.centerIn: parent
            width: 16
            height: 3
            radius: 1
            color: QfTheme.mainTextColor
          }
          Rectangle {
            visible: pannello.ridotto
            anchors.centerIn: parent
            width: 15
            height: 13
            color: "transparent"
            border.width: 2
            border.color: QfTheme.mainTextColor
          }
          MouseArea {
            anchors.fill: parent
            onClicked: pannello.ridotto = !pannello.ridotto
          }
        }
        Label {
          Layout.fillWidth: true
          text: pannello.ridotto && attesa !== "" ? qsTr("Tocca il punto %1").arg(attesa) : qsTr("COGO linea A-B")
          font: QfTheme.strongFont
          color: pannello.ridotto && attesa !== "" ? QfTheme.mainColor : QfTheme.mainTextColor
          elide: Text.ElideRight
        }
        Button {
          flat: true
          Layout.preferredWidth: 40
          // Croce disegnata: "✕" non è nei font Android
          contentItem: Item {
            Repeater {
              model: [45, -45]
              Rectangle {
                anchors.centerIn: parent
                width: 18
                height: 2
                radius: 1
                rotation: modelData
                color: QfTheme.mainTextColor
              }
            }
          }
          onClicked: {
            pannello.visible = false;
            attesa = "";
          }
        }
      }

      // Tutto il resto del pannello, nascosto quando è ridotto
      ColumnLayout {
        Layout.fillWidth: true
        visible: !pannello.ridotto
        spacing: 4

        // Una sola riga di stato: durante la scelta di un punto dice cosa toccare, altrimenti il layer attivo
        Label {
          Layout.fillWidth: true
          text: attesa !== "" ? qsTr("Tocca sulla mappa il punto %1").arg(attesa) : !layerCorrente ? qsTr("Nessun layer attivo: sceglilo nella legenda") : qsTr("Layer attivo: %1").arg(layerCorrente.name) + (layerDiPunti(layerCorrente) ? " · " + testoConfigQuota(layerCorrente) : qsTr(" — non è un layer di punti"))
          font: QfTheme.tipFont
          color: attesa !== "" ? QfTheme.mainColor : layerDiPunti(layerCorrente) ? QfTheme.secondaryTextColor : QfTheme.errorColor
          wrapMode: Text.WordWrap
        }

        // A e B affiancati, con i riferimenti al punto sotto ciascun pulsante
        GridLayout {
          Layout.fillWidth: true
          columns: 2
          columnSpacing: 8
          rowSpacing: 0
          Button {
            Layout.fillWidth: true
            implicitHeight: pannello.altezzaControlli
            topInset: 0
            bottomInset: 0
            topPadding: 0
            bottomPadding: 0
            text: "A"
            highlighted: attesa === "A"
            onClicked: attendi("A")
          }
          Button {
            Layout.fillWidth: true
            implicitHeight: pannello.altezzaControlli
            topInset: 0
            bottomInset: 0
            topPadding: 0
            bottomPadding: 0
            text: "B"
            highlighted: attesa === "B"
            onClicked: attendi("B")
          }
          Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: testoPunto(puntoA)
            font: QfTheme.tipFont
            color: "#1e88e5"
            elide: Text.ElideRight
          }
          Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: testoPunto(puntoB)
            font: QfTheme.tipFont
            color: "#1e88e5"
            elide: Text.ElideRight
          }
        }

        Label {
          Layout.fillWidth: true
          visible: testoAB !== ""
          text: testoAB
          font: QfTheme.tipFont
          color: QfTheme.mainTextColor
          wrapMode: Text.WordWrap
        }

        ComboBox {
          id: sceltaOperazione
          Layout.fillWidth: true
          implicitHeight: pannello.altezzaControlli
          topInset: 0
          bottomInset: 0
          topPadding: 0
          bottomPadding: 0
          font: QfTheme.tipFont
          model: operazioni
          textRole: "testo"
          onActivated: {
            calcolo = null;
            if (operazioni[currentIndex].conP && !puntoP)
              attendi("P");
          }
        }

        // Parametri: etichetta a sinistra e campo stretto a destra (niente etichetta flottante, più bassa)
        RowLayout {
          Layout.fillWidth: true
          visible: operazioni[sceltaOperazione.currentIndex].parametro !== ""
          Label {
            Layout.fillWidth: true
            text: etichetta(operazioni[sceltaOperazione.currentIndex].parametro)
            font: QfTheme.tipFont
            color: QfTheme.mainTextColor
            wrapMode: Text.WordWrap
          }
          TextField {
            id: campoParametro
            Layout.preferredWidth: 120
            // In sessagesimale servono spazi o ° ' ": tastiera completa invece di quella numerica
            property bool angoloDms: !!operazioni[sceltaOperazione.currentIndex].angolo && unitaAngoli === "dms"
            implicitHeight: pannello.altezzaControlli
            topPadding: 2
            bottomPadding: 2
            font: QfTheme.tipFont
            horizontalAlignment: TextInput.AlignRight
            inputMethodHints: angoloDms ? Qt.ImhNoPredictiveText : Qt.ImhFormattedNumbersOnly
            onTextChanged: calcolo = null
            onAccepted: calcola(operazioni[sceltaOperazione.currentIndex].codice, text, campoParametro2.text)
          }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: operazioni[sceltaOperazione.currentIndex].parametro2 !== ""
          Label {
            Layout.fillWidth: true
            text: operazioni[sceltaOperazione.currentIndex].parametro2
            font: QfTheme.tipFont
            color: QfTheme.mainTextColor
            wrapMode: Text.WordWrap
          }
          TextField {
            id: campoParametro2
            Layout.preferredWidth: 120
            implicitHeight: pannello.altezzaControlli
            topPadding: 2
            bottomPadding: 2
            font: QfTheme.tipFont
            horizontalAlignment: TextInput.AlignRight
            inputMethodHints: Qt.ImhFormattedNumbersOnly
            onTextChanged: calcolo = null
            onAccepted: calcola(operazioni[sceltaOperazione.currentIndex].codice, campoParametro.text, text)
          }
        }

        ComboBox {
          id: sceltaLato
          Layout.fillWidth: true
          implicitHeight: pannello.altezzaControlli
          topInset: 0
          bottomInset: 0
          topPadding: 0
          bottomPadding: 0
          font: QfTheme.tipFont
          visible: !!operazioni[sceltaOperazione.currentIndex].conLato
          model: [qsTr("Soluzione a sinistra di A→B (sx)"), qsTr("Soluzione a destra di A→B (dx)")]
          // Cambiando lato si ricalcola subito, se c'era già un risultato
          onActivated: {
            if (calcolo)
              calcola(operazioni[sceltaOperazione.currentIndex].codice, campoParametro.text, campoParametro2.text);
          }
        }

        RowLayout {
          Layout.fillWidth: true
          visible: operazioni[sceltaOperazione.currentIndex].conP
          Button {
            implicitHeight: pannello.altezzaControlli
            topInset: 0
            bottomInset: 0
            topPadding: 0
            bottomPadding: 0
            text: "P"
            highlighted: attesa === "P"
            onClicked: attendi("P")
          }
          Label {
            Layout.fillWidth: true
            text: testoPunto(puntoP)
            font: QfTheme.tipFont
            color: "#8e24aa"
            elide: Text.ElideRight
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 8
          Button {
            Layout.fillWidth: true
            implicitHeight: pannello.altezzaControlli
            topInset: 0
            bottomInset: 0
            topPadding: 0
            bottomPadding: 0
            text: qsTr("Calcola")
            enabled: puntoA !== null && puntoB !== null
            onClicked: calcola(operazioni[sceltaOperazione.currentIndex].codice, campoParametro.text, campoParametro2.text)
          }
          Button {
            Layout.fillWidth: true
            implicitHeight: pannello.altezzaControlli
            topInset: 0
            bottomInset: 0
            topPadding: 0
            bottomPadding: 0
            text: qsTr("Salva")
            enabled: calcolo !== null && calcolo.punti.length > 0
            highlighted: true
            onClicked: salva()
          }
        }

        Label {
          Layout.fillWidth: true
          visible: calcolo !== null
          text: testoCalcolo()
          font: QfTheme.tipFont
          color: "#d81b60"
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ---------- Configurazione ----------

  // Chiamata da QField (pulsante di configurazione nel gestore plugin); anche pressione lunga sul pulsante
  function configure() {
    dialogoConfigurazione.open();
  }

  Dialog {
    id: dialogoConfigurazione
    parent: plugin.mainWindow.contentItem
    modal: true
    z: 1001
    width: Math.min(360, parent.width - 32)
    x: (parent.width - width) / 2
    y: (parent.height - height) / 2
    title: qsTr("COGO linea A-B — configurazione")
    standardButtons: Dialog.Close

    ColumnLayout {
      anchors.fill: parent
      spacing: 0
      Label {
        Layout.fillWidth: true
        text: qsTr("Unità di misura degli angoli")
        font: QfTheme.strongFont
        color: QfTheme.mainTextColor
      }
      Repeater {
        model: [
          { codice: "deg", testo: qsTr("Sessadecimale (12.58250°)") },
          { codice: "dms", testo: qsTr("Sessagesimale (12°34'57.0\")") },
          { codice: "gon", testo: qsTr("Centesimale (13.9806 gon)") }
        ]
        RadioButton {
          Layout.fillWidth: true
          text: modelData.testo
          font: QfTheme.tipFont
          checked: unitaAngoli === modelData.codice
          onClicked: {
            configurazione.unitaAngoli = modelData.codice;
            calcolo = null;
          }
        }
      }

      // Quota del layer attivo: sorgente (Z o campo) e tipo (H o h)
      Label {
        Layout.fillWidth: true
        Layout.topMargin: 12
        text: layerDiPunti(layerCorrente) ? qsTr("Quota del layer \"%1\"").arg(layerCorrente.name) : qsTr("Quota: scegli prima un layer di punti come layer attivo")
        font: QfTheme.strongFont
        color: QfTheme.mainTextColor
        wrapMode: Text.WordWrap
      }
      GridLayout {
        Layout.fillWidth: true
        visible: layerDiPunti(layerCorrente)
        columns: 2
        columnSpacing: 8
        Label {
          text: qsTr("Sorgente")
          font: QfTheme.tipFont
          color: QfTheme.mainTextColor
        }
        // Modificabile: se l'elenco dei campi non è disponibile si può scrivere il nome del campo
        ComboBox {
          id: sceltaSorgente
          Layout.fillWidth: true
          editable: true
          font: QfTheme.tipFont
          model: [qsTr("Z della geometria")].concat(nomiCampi(layerCorrente))
        }
        Label {
          text: qsTr("Tipo")
          font: QfTheme.tipFont
          color: QfTheme.mainTextColor
        }
        ComboBox {
          id: sceltaTipo
          Layout.fillWidth: true
          font: QfTheme.tipFont
          model: [qsTr("Ortometrica (H)"), qsTr("Ellissoidica (h)")]
        }
      }
      Button {
        Layout.alignment: Qt.AlignRight
        visible: layerDiPunti(layerCorrente)
        text: qsTr("Applica quota")
        onClicked: {
          var testo = sceltaSorgente.editText.trim();
          var sorgente = (sceltaSorgente.currentIndex === 0 && testo === sceltaSorgente.textAt(0)) || testo === "" ? "" : testo;
          if (sorgente !== "" && layerCorrente.fields.indexFromName(sorgente) < 0) {
            avviso(qsTr("Il campo \"%1\" non esiste nel layer").arg(sorgente));
            return;
          }
          impostaConfigQuota(layerCorrente, sorgente, sceltaTipo.currentIndex === 1 ? "h" : "H");
          avviso(qsTr("Quota di %1: %2. Scegli di nuovo A e B").arg(layerCorrente.name).arg(testoConfigQuota(layerCorrente)));
        }
      }
      Label {
        Layout.fillWidth: true
        visible: layerDiPunti(layerCorrente)
        text: qsTr("La quota dei punti calcolati è dello stesso tipo di A e B. Con il grigliato verticale impostato in QField cogo_point riceve anche entrambe le quote (H_elliss ellissoidica, Q_geoide ortometrica) e N nel punto.")
        font: QfTheme.tipFont
        color: QfTheme.secondaryTextColor
        wrapMode: Text.WordWrap
      }
    }

    // All'apertura mostra la configurazione attuale del layer attivo
    onAboutToShow: {
      if (!layerDiPunti(layerCorrente))
        return;
      var c = configQuota(layerCorrente);
      var i = c.sorgente === "" ? 0 : sceltaSorgente.find(c.sorgente);
      sceltaSorgente.currentIndex = i >= 0 ? i : 0;
      if (i < 0)
        sceltaSorgente.editText = c.sorgente;
      sceltaTipo.currentIndex = c.tipo === "h" ? 1 : 0;
    }
  }

  Component.onCompleted: {
    iface.addItemToPluginsToolbar(pulsantePlugin);
    var gestore = iface.findItemByObjectName("pointHandler");
    if (gestore)
      gestore.registerHandler(nomeGestoreTocchi, gestisciTocco, 100);
  }

  Component.onDestruction: {
    var gestore = iface.findItemByObjectName("pointHandler");
    if (gestore)
      gestore.deregisterHandler(nomeGestoreTocchi);
  }
}
