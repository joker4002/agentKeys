import { api } from "./api";
import type {
  Character,
  Edge,
  GraphPayload,
  MapData,
  MapTile,
  ModuleTile,
  Region,
  Town,
} from "./types";

import regionsJson from "../../threeKingdoms/regions.json";
import townsJson from "../../threeKingdoms/towns.json";
import charactersJson from "../../threeKingdoms/characters.json";

interface RegionsFile {
  regions: Region[];
}
interface TownsFile {
  towns: Record<string, Town[]>;
}
interface CharactersFile {
  characters: Character[];
}

export const REGIONS: Region[] = (regionsJson as RegionsFile).regions;
export const TOWNS: Record<string, Town[]> = (townsJson as TownsFile).towns;
export const CHARACTERS: Character[] = (charactersJson as CharactersFile).characters;

// ─── Hex helpers ───
function hexDistance(a: { q: number; r: number }, b: { q: number; r: number }): number {
  return (Math.abs(a.q - b.q) + Math.abs(a.q + a.r - b.q - b.r) + Math.abs(a.r - b.r)) / 2;
}

// Region seeds in offset (col, row) coords. Specified as col/row so the layout
// reads top-to-bottom (north → south) and left-to-right (west → east) like
// the reference map. We convert to axial for the pointy-top hex grid.
//
// row 0–1: 凉/并/幽 northern frontier
// row 2  : 雍/司隶/冀/青 imperial belt
// row 3  : 兖
// row 4  : 汉中/豫/徐
// row 5–6: 益/荆/扬
// row 7–8: 南中/交州
const REGION_SEEDS_OFFSET: Record<string, { col: number; row: number }> = {
  liang:    { col:  0, row:  0 },   // 凉州 — far NW
  bing:     { col:  5, row:  0 },   // 并州 — N
  you:      { col: 11, row:  0 },   // 幽州 — far NE
  yong:     { col:  3, row:  2 },   // 雍州
  sili:     { col:  6, row:  2 },   // 司隶 — capital
  ji:       { col:  9, row:  1 },   // 冀州
  qing:     { col: 12, row:  2 },   // 青州
  yan:      { col:  8, row:  3 },   // 兖州 — central plain
  hanzhong: { col:  3, row:  4 },   // 汉中
  yu:       { col:  7, row:  4 },   // 豫州
  xu:       { col: 11, row:  4 },   // 徐州
  yi:       { col:  1, row:  6 },   // 益州
  jing:     { col:  7, row:  6 },   // 荆州
  yang:     { col: 11, row:  6 },   // 扬州
  nanzhong: { col:  2, row:  8 },   // 南中
  jiao:     { col:  9, row:  8 },   // 交州
};

// odd-r offset → axial conversion (pointy-top hexes).
function offsetToAxial(col: number, row: number): { q: number; r: number } {
  return { q: col - Math.floor(row / 2), r: row };
}

const REGION_SEEDS: Record<string, { q: number; r: number }> = Object.fromEntries(
  Object.entries(REGION_SEEDS_OFFSET).map(([id, off]) => [id, offsetToAxial(off.col, off.row)]),
);

// Per-town offset pattern: a radius-1 ring around the seed (capital + 6
// neighbours). Capped at distance 1 so that any two seeds at axial distance ≥ 3
// cannot share cells. Distance-2 seeds may still collide on a single cell —
// the placement loop dedup'd by coord and lets the first region win.
const TOWN_OFFSETS: { q: number; r: number }[] = [
  { q:  0, r:  0 },  // capital
  { q:  1, r:  0 },  // E
  { q:  1, r: -1 },  // NE
  { q:  0, r: -1 },  // N
  { q: -1, r:  0 },  // W
  { q: -1, r:  1 },  // SW
  { q:  0, r:  1 },  // S
];

// Crate → region assignment, adjacency-aware.
//   sili     ← types       (the imperial heart — every kingdom pays tribute)
//   yan      ← core        (adjacent to sili — main dependency chain)
//   ji       ← broker      (NE — strategic outpost)
//   yong     ← mcp         (W — protocol corridor)
//   hanzhong ← provisioner (W mountains — between yong & yi)
//   yi       ← daemon      (SW basin — long-lived stronghold)
//   jing     ← cli         (S — gateway crate)
//   yu       ← mock-server (S of sili — overflow / disposable)
const CRATE_REGION_ASSIGNMENT: Record<string, string> = {
  "agentkeys-types": "sili",
  "agentkeys-core": "yan",
  "agentkeys-broker-server": "ji",
  "agentkeys-mcp": "yong",
  "agentkeys-provisioner": "hanzhong",
  "agentkeys-daemon": "yi",
  "agentkeys-cli": "jing",
  "agentkeys-mock-server": "yu",
};

const TILE_GRID_BOUNDS = { qMin: -7, qMax: 19, rMin: -8, rMax: 14 };
const WILDERNESS_RING = 2; // cells beyond the nearest seed → grey wilderness

function generateGrid(): { q: number; r: number }[] {
  const cells: { q: number; r: number }[] = [];
  for (let q = TILE_GRID_BOUNDS.qMin; q <= TILE_GRID_BOUNDS.qMax; q++) {
    for (let r = TILE_GRID_BOUNDS.rMin; r <= TILE_GRID_BOUNDS.rMax; r++) {
      cells.push({ q, r });
    }
  }
  return cells;
}

interface RawCrate {
  name: string;
  shortName: string;
  layer: number;
}

export async function loadMapData(): Promise<MapData> {
  const graph: GraphPayload = await api.graph();
  const crates: RawCrate[] = graph.nodes.map((n) => ({
    name: n.id,
    shortName: n.id.replace(/^agentkeys-/, ""),
    layer: n.layer,
  }));

  // Step 1: assign each crate to its region (adjacency-aware via static map +
  // overflow fallback for crates that don't have an explicit assignment).
  const usedRegions = new Set<string>();
  const cratesWithRegion = crates.map((c) => {
    let regionId = CRATE_REGION_ASSIGNMENT[c.name];
    if (!regionId || usedRegions.has(regionId)) {
      const fallback = REGIONS.find((r) => !usedRegions.has(r.id) && REGION_SEEDS[r.id]);
      if (fallback) regionId = fallback.id;
    }
    if (!regionId) regionId = "yu";
    usedRegions.add(regionId);
    return { ...c, regionId };
  });
  const activeRegionIds = [...usedRegions];

  // Step 2: build the BASE map. Every region in regions.json gets every town
  // from towns.json laid out around its seed. Town placements are deduped by
  // (q, r) so distance-2 seed pairs can't double-stamp a cell; first region
  // to claim a coord wins.
  const tilesByKey = new Map<string, MapTile>();
  for (const region of REGIONS) {
    const seed = REGION_SEEDS[region.id];
    if (!seed) continue;
    const towns = TOWNS[region.id] ?? [];
    towns.forEach((town, idx) => {
      if (idx >= TOWN_OFFSETS.length) return;
      const off = TOWN_OFFSETS[idx];
      const q = seed.q + off.q;
      const r = seed.r + off.r;
      const key = `${q},${r}`;
      if (tilesByKey.has(key)) return; // dedupe: first region wins
      tilesByKey.set(key, {
        q,
        r,
        regionId: region.id,
        moduleId: null,
        townName: town.name,
        townPinyin: town.pinyin,
        townKind: town.kind,
        isCapital: town.kind === "capital",
      });
    });
  }
  const tiles: MapTile[] = [...tilesByKey.values()];

  // Step 3: fill the surrounding land via Voronoi assignment so the map looks
  // continuous. Each free cell joins its nearest seed; anything farther than
  // WILDERNESS_RING beyond the nearest town becomes grey wilderness (no region).
  const occupied = new Set(tiles.map((t) => `${t.q},${t.r}`));
  for (const cell of generateGrid()) {
    const key = `${cell.q},${cell.r}`;
    if (occupied.has(key)) continue;
    let bestRegion: string | null = null;
    let bestDist = Infinity;
    for (const region of REGIONS) {
      const seed = REGION_SEEDS[region.id];
      if (!seed) continue;
      const d = hexDistance(cell, seed);
      if (d < bestDist) {
        bestDist = d;
        bestRegion = region.id;
      }
    }
    // Distance to the nearest TOWN (not just seed) — wilderness is anything
    // beyond a small ring around any settled cell.
    let nearestTown = Infinity;
    for (const t of tiles) {
      const d = hexDistance(cell, t);
      if (d < nearestTown) nearestTown = d;
    }
    const filler = {
      q: cell.q,
      r: cell.r,
      moduleId: null,
      townName: null,
      townPinyin: null,
      townKind: null,
      isCapital: false,
    };
    if (nearestTown > WILDERNESS_RING) {
      tiles.push({ ...filler, regionId: null });
    } else {
      tiles.push({ ...filler, regionId: bestRegion });
    }
  }

  // Step 4: light up active regions — stamp each crate's modules onto the
  // tiles that actually belong to its assigned region (post-dedup), capital
  // first then by axial distance from the seed.
  const modules: ModuleTile[] = [];
  for (const c of cratesWithRegion) {
    const seed = REGION_SEEDS[c.regionId];
    if (!seed) continue;

    const outgoingSet = new Set<string>();
    for (const e of graph.edges) {
      if (e.from === c.name) outgoingSet.add(e.to);
    }
    const outgoing = [...outgoingSet];
    const subModules = ["lib", ...outgoing.slice(0, 4).map((d) => d.replace(/^agentkeys-/, ""))];

    // Tiles owned by this region, sorted: capital first, then by distance from seed.
    const regionTiles = tiles
      .map((t, i) => ({ t, i }))
      .filter(({ t }) => t.regionId === c.regionId && t.townName)
      .sort((a, b) => {
        if (a.t.isCapital && !b.t.isCapital) return -1;
        if (!a.t.isCapital && b.t.isCapital) return 1;
        return (
          hexDistance({ q: a.t.q, r: a.t.r }, seed) -
          hexDistance({ q: b.t.q, r: b.t.r }, seed)
        );
      });

    subModules.forEach((subName, idx) => {
      if (idx >= regionTiles.length) return;
      const { t: tile, i: tileIdx } = regionTiles[idx];
      const id = `${c.shortName}-${subName}`;
      modules.push({
        id,
        name: subName,
        cn: tile.townName!,
        pinyin: tile.townPinyin ?? "",
        territory: c.regionId,
        q: tile.q,
        r: tile.r,
        path: idx === 0 ? `crates/${c.name}` : `crates/${c.name}/src/${subName}`,
        files: 0,
        loc: 0,
        desc:
          idx === 0
            ? `Crate root — depended on by ${graph.edges.filter((e) => e.to === c.name).length} crates.`
            : `Town for inter-crate edge → ${subName}`,
        isCapital: idx === 0,
      });
      tiles[tileIdx] = { ...tile, moduleId: id };
    });
  }

  // Step 5: dedup'd inter-crate edges.
  const moduleByCrate = new Map<string, string>();
  cratesWithRegion.forEach((c) => {
    moduleByCrate.set(c.name, `${c.shortName}-lib`);
  });
  const edgeSet = new Set<string>();
  const edges: Edge[] = [];
  for (const e of graph.edges) {
    const from = moduleByCrate.get(e.from);
    const to = moduleByCrate.get(e.to);
    if (!from || !to || from === to) continue;
    const key = `${from}->${to}`;
    if (edgeSet.has(key)) continue;
    edgeSet.add(key);
    edges.push({ from, to });
  }

  return {
    regions: REGIONS,
    modules,
    tiles,
    edges,
    characters: CHARACTERS,
    activeRegionIds,
  };
}
