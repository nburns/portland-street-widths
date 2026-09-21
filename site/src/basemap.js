import { Protocol } from "pmtiles";
import maplibregl from "maplibre-gl";
import { layers, namedFlavor } from "@protomaps/basemaps";


// A PMTiles archive is a single file read with HTTP range requests: no tile
// server, no API key, no vendor account. That is the only arrangement in which
// "static site" and "basemap" are both true at once.
//
// The archive is a build artifact, not a repository blob - `make basemap`
// writes it, and .gitignore keeps it out. So the site has to work without it:
// absent a basemap it draws the same way the canvas version always did, on a
// flat ground with the city boundary for orientation. That is a degraded
// render, never a broken one.
const BASEMAP_URL = import.meta.env.VITE_BASEMAP_URL ?? "./basemap.pmtiles";

export function registerPmtilesProtocol() {
  const protocol = new Protocol();
  maplibregl.addProtocol("pmtiles", protocol.tile);
}

// Checking the archive magic rather than the status code, because a static
// host answering a missing file with an SPA fallback returns 200 text/html -
// and MapLibre then hangs forever trying to read HTML as a tile archive, which
// surfaces as a blank panel rather than as an error. A 200 is not a success
// here; the seven bytes "PMTiles" are.
//
// Only the first chunk is read and the stream is then cancelled, so this costs
// one request and a few bytes even when the archive is tens of megabytes.
export async function basemapAvailable() {
  try {
    const res = await fetch(BASEMAP_URL, { headers: { Range: "bytes=0-6" } });
    if (!res.ok) return false;
    if ((res.headers.get("content-type") ?? "").includes("text/html")) return false;
    const reader = res.body.getReader();
    const { value } = await reader.read();
    reader.cancel();
    return new TextDecoder().decode(value?.slice(0, 7) ?? new Uint8Array()) === "PMTiles";
  } catch {
    return false;
  }
}

export function baseStyle(withBasemap) {
  const style = {
    version: 8,
    glyphs: "https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf",
    sprite: "https://protomaps.github.io/basemaps-assets/sprites/v4/light",
    sources: {},
    layers: [{ id: "ground", type: "background", paint: { "background-color": "#f6f5f3" } }],
  };

  if (withBasemap) {
    style.sources.protomaps = {
      type: "vector",
      url: `pmtiles://${BASEMAP_URL}`,
      attribution: '© <a href="https://openstreetmap.org">OpenStreetMap</a>',
    };
    // "light" keeps the basemap as ground rather than as a competing subject:
    // the width ramp is what the page is about.
    style.layers.push(...layers("protomaps", namedFlavor("light"), { lang: "en" }));
  }

  return style;
}
