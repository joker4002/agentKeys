import React, { useEffect, useMemo, useRef, useState } from "react";
import type { Battle, MapData, MapTile, ModuleTile, Region, Selection } from "../types";

const HEX_SIZE = 64;
const WILDERNESS_FILL = "#cfc4a8";
const WILDERNESS_INK = "#8d7a5e";

// Pointy-top hex layout (north faces up — flat side is on the left/right).
function hexToPixel(q: number, r: number) {
  const x = HEX_SIZE * Math.sqrt(3) * (q + r / 2);
  const y = HEX_SIZE * 1.5 * r;
  return { x, y };
}

function hexCorners(cx: number, cy: number, size: number) {
  const pts: [number, number][] = [];
  for (let i = 0; i < 6; i++) {
    const a = (Math.PI / 3) * i + Math.PI / 6; // pointy-top: rotate 30°
    pts.push([cx + size * Math.cos(a), cy + size * Math.sin(a)]);
  }
  return pts;
}

interface ModuleCellProps {
  mod: ModuleTile;
  region: Region;
  isActive: boolean;
  isHover: boolean;
  isDimmed: boolean;
  onClick: (mod: ModuleTile) => void;
  onHover: (id: string | null) => void;
  battle: Battle | null;
}

function ModuleCell({ mod, region, isActive, isHover, isDimmed, onClick, onHover, battle }: ModuleCellProps) {
  const { x, y } = hexToPixel(mod.q, mod.r);
  const corners = hexCorners(x, y, HEX_SIZE - 2);
  const dPath = "M " + corners.map(([px, py]) => `${px.toFixed(2)},${py.toFixed(2)}`).join(" L ") + " Z";
  const opacity = isDimmed ? 0.45 : 1;

  return (
    <g
      style={{ cursor: "pointer", opacity, transition: "opacity 0.2s" }}
      onClick={(e) => {
        e.stopPropagation();
        onClick(mod);
      }}
      onMouseEnter={() => onHover(mod.id)}
      onMouseLeave={() => onHover(null)}
    >
      <path d={dPath} transform="translate(2,3)" fill="rgba(60,40,20,0.22)" />
      <path
        d={dPath}
        fill={region.color}
        stroke={region.ink}
        strokeWidth={isActive || isHover ? 3.5 : 2.4}
        strokeLinejoin="round"
      />
      {battle && (
        <g style={{ pointerEvents: "none" }}>
          <circle cx={x + HEX_SIZE - 18} cy={y + HEX_SIZE - 26} r="7" fill="#D9534F" stroke="#fdfaf0" strokeWidth="2">
            <animate attributeName="r" values="7;9;7" dur="1.5s" repeatCount="indefinite" />
          </circle>
          <circle cx={x + HEX_SIZE - 18} cy={y + HEX_SIZE - 26} r="3" fill="#fdfaf0" />
        </g>
      )}
    </g>
  );
}

// Text overlay drawn last so neither BackgroundCell nor ModuleCell hides it.
interface TileLabelProps {
  tile: MapTile;
  region: Region | null;
  isRegionActive: boolean;
  module: ModuleTile | null;
}

function TileLabel({ tile, region, isRegionActive, module }: TileLabelProps) {
  if (!tile.townName) return null;
  const { x, y } = hexToPixel(tile.q, tile.r);
  const hasModule = !!module;

  // Color & weight tier: lit (has module) > active region (no module) > inactive region > wilderness.
  let nameFill: string;
  let nameOpacity: number;
  let nameWeight: number;
  let nameSize: number;
  let pinyinFill: string;
  let pinyinOpacity: number;
  let modSize = 9;
  let modOpacity = 0.85;

  if (hasModule) {
    // Saturated module tile — ink color over saturated fill.
    nameFill = region!.ink;
    nameOpacity = 1;
    nameWeight = 900;
    nameSize = 17;
    pinyinFill = region!.ink;
    pinyinOpacity = 0.85;
  } else if (isRegionActive && region) {
    // Active region but no module — town name visible but slightly muted.
    nameFill = region.ink;
    nameOpacity = 0.78;
    nameWeight = 700;
    nameSize = 14;
    pinyinFill = region.ink;
    pinyinOpacity = 0.6;
  } else {
    // Inactive region — greyed name.
    nameFill = "#5a4d36";
    nameOpacity = 0.6;
    nameWeight = 600;
    nameSize = 13;
    pinyinFill = "#5a4d36";
    pinyinOpacity = 0.45;
  }

  return (
    <g style={{ pointerEvents: "none" }}>
      {tile.isCapital && (
        <polygon
          points={`${x},${y - HEX_SIZE + 6} ${x + 5},${y - HEX_SIZE + 12} ${x - 5},${y - HEX_SIZE + 12}`}
          fill={hasModule ? region!.ink : "#5a4d36"}
          opacity={hasModule ? 1 : 0.55}
        />
      )}
      <text
        x={x}
        y={hasModule ? y - 4 : y - 2}
        textAnchor="middle"
        fontFamily="'Noto Serif SC', serif"
        fontSize={nameSize}
        fontWeight={nameWeight}
        fill={nameFill}
        opacity={nameOpacity}
      >
        {tile.townName}
      </text>
      {hasModule ? (
        <text
          x={x}
          y={y + 12}
          textAnchor="middle"
          fontFamily="'JetBrains Mono', monospace"
          fontSize={modSize}
          fontWeight="700"
          fill={region!.ink}
          opacity={modOpacity}
          letterSpacing="0.02em"
        >
          {module!.name}
        </text>
      ) : (
        tile.townPinyin && (
          <text
            x={x}
            y={y + 11}
            textAnchor="middle"
            fontFamily="'Inter', sans-serif"
            fontSize="9"
            fill={pinyinFill}
            opacity={pinyinOpacity}
            letterSpacing="0.04em"
          >
            {tile.townPinyin}
          </text>
        )
      )}
    </g>
  );
}

interface BackgroundCellProps {
  tile: MapTile;
  region: Region | null;
  isActive: boolean; // region is backed by a real crate
}

function BackgroundCell({ tile, region, isActive }: BackgroundCellProps) {
  const { x, y } = hexToPixel(tile.q, tile.r);
  const corners = hexCorners(x, y, HEX_SIZE - 1);
  const dPath = "M " + corners.map(([px, py]) => `${px.toFixed(2)},${py.toFixed(2)}`).join(" L ") + " Z";
  // Rule: a tile is colored ONLY IF it has a town name. Anything else (Voronoi
  // padding, wilderness ring) renders as grey, regardless of regionId.
  const hasName = !!tile.townName;
  let fill: string;
  let stroke: string;
  let fillOpacity: number;
  let strokeOpacity: number;
  if (!hasName) {
    fill = WILDERNESS_FILL;
    stroke = WILDERNESS_INK;
    fillOpacity = 0.5;
    strokeOpacity = 0.4;
  } else if (!isActive || !region) {
    // Has a name but the region isn't backed by a crate → muted grey-tan.
    fill = "#b9ad8e";
    stroke = "#7d6f54";
    fillOpacity = 0.72;
    strokeOpacity = 0.45;
  } else {
    // Active region + named town → soft region color (the brighter overlay
    // for module tiles is drawn separately by ModuleCell).
    fill = region.colorSoft;
    stroke = region.ink;
    fillOpacity = 0.88;
    strokeOpacity = 0.6;
  }
  return (
    <path
      d={dPath}
      fill={fill}
      stroke={stroke}
      strokeWidth={1.2}
      strokeLinejoin="round"
      strokeOpacity={strokeOpacity}
      fillOpacity={fillOpacity}
    />
  );
}

function TerritoryHull({
  region,
  tiles,
  isActive,
  crateName,
}: {
  region: Region;
  tiles: MapTile[];
  isActive: boolean;
  crateName: string | null;
}) {
  const mine = tiles.filter((t) => t.regionId === region.id);
  if (mine.length === 0) return null;
  const positions = mine.map((t) => hexToPixel(t.q, t.r));
  const cx = positions.reduce((s, p) => s + p.x, 0) / positions.length;
  const minY = Math.min(...positions.map((p) => p.y));
  const inkColor = isActive ? region.ink : "#5a4d36";
  return (
    <g style={{ pointerEvents: "none" }}>
      <text
        x={cx}
        y={minY - HEX_SIZE * 0.6}
        textAnchor="middle"
        fontFamily="'Noto Serif SC', serif"
        fontSize={isActive ? 18 : 14}
        fontWeight="700"
        fill={inkColor}
        opacity={isActive ? 0.92 : 0.55}
        letterSpacing="0.18em"
      >
        {isActive ? `◆ ${region.name} ◆` : region.name}
      </text>
      {isActive && crateName && (
        <text
          x={cx}
          y={minY - HEX_SIZE * 0.6 + 14}
          textAnchor="middle"
          fontFamily="'JetBrains Mono', monospace"
          fontSize="10"
          fill={inkColor}
          opacity="0.6"
          letterSpacing="0.12em"
        >
          crates/{crateName}
        </text>
      )}
    </g>
  );
}

interface Props {
  data: MapData;
  battles: Battle[];
  selected: Selection;
  hoverModule: string | null;
  setHoverModule: (id: string | null) => void;
  onSelectModule: (id: string) => void;
  matchSet: Set<string> | null;
}

export function HexMap({
  data,
  battles,
  selected,
  hoverModule,
  setHoverModule,
  onSelectModule,
  matchSet,
}: Props) {
  const { modules, regions, edges } = data;
  const regionById = useMemo(
    () => Object.fromEntries(regions.map((r) => [r.id, r])),
    [regions],
  );
  const activeSet = useMemo(() => new Set(data.activeRegionIds), [data.activeRegionIds]);
  const crateByRegion = useMemo(() => {
    const m = new Map<string, string>();
    for (const mod of modules) {
      if (mod.isCapital) {
        // path is "crates/<crate-name>"
        const crate = mod.path.split("/")[1] ?? "";
        m.set(mod.territory, crate);
      }
    }
    return m;
  }, [modules]);

  // Derive battle markers from running ps battles. We attach a battle to a
  // module if its crate_name matches the crate prefix.
  const battleByModule = useMemo(() => {
    const map = new Map<string, Battle>();
    for (const b of battles) {
      if (!b.crate_name) continue;
      const target = modules.find(
        (m) => m.path.includes(b.crate_name!) && m.isCapital,
      );
      if (target) map.set(target.id, b);
    }
    return map;
  }, [battles, modules]);

  // Use the full tile grid (not just modules) for the bounding box so the
  // continuous patchwork map fits the viewport.
  const positions = data.tiles.map((t) => hexToPixel(t.q, t.r));
  const minX = positions.length === 0 ? -200 : Math.min(...positions.map((p) => p.x)) - HEX_SIZE - 40;
  const maxX = positions.length === 0 ? 200 : Math.max(...positions.map((p) => p.x)) + HEX_SIZE + 40;
  const minY = positions.length === 0 ? -200 : Math.min(...positions.map((p) => p.y)) - HEX_SIZE - 40;
  const maxY = positions.length === 0 ? 200 : Math.max(...positions.map((p) => p.y)) + HEX_SIZE + 40;
  const W = maxX - minX;
  const H = maxY - minY;

  const activeId = selected?.kind === "module" ? selected.id : hoverModule;
  const connected = new Set<string>();
  if (activeId) {
    edges.forEach((e) => {
      if (e.from === activeId) connected.add(e.to);
      if (e.to === activeId) connected.add(e.from);
    });
    connected.add(activeId);
  }
  const dimming = !!activeId || !!matchSet;

  // ─── Pan & zoom ───
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [view, setView] = useState({ x: 0, y: 0, scale: 3.75 });
  const initialised = useRef(false);
  const drag = useRef<{ sx: number; sy: number; vx: number; vy: number } | null>(null);

  // On first paint, center the view on Luoyang (司隶 capital — the imperial heart).
  useEffect(() => {
    if (initialised.current) return;
    if (!containerRef.current) return;
    const luoyang = data.tiles.find((t) => t.regionId === "sili" && t.isCapital);
    if (!luoyang) return;
    const lx = HEX_SIZE * Math.sqrt(3) * (luoyang.q + luoyang.r / 2);
    const ly = HEX_SIZE * 1.5 * luoyang.r;
    const rect = containerRef.current.getBoundingClientRect();
    const cw = rect.width;
    const ch = rect.height;
    if (!cw || !ch) return;
    // viewBox-to-screen scale (preserveAspectRatio="xMidYMid meet")
    const k = Math.min(cw / W, ch / H);
    const screenX = (cw - k * W) / 2 + k * (lx - minX);
    const screenY = (ch - k * H) / 2 + k * (ly - minY);
    const s = view.scale;
    setView({ x: cw / 2 - s * screenX, y: ch / 2 - s * screenY, scale: s });
    initialised.current = true;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data.tiles, W, H, minX, minY]);

  const onMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    drag.current = { sx: e.clientX, sy: e.clientY, vx: view.x, vy: view.y };
    (e.currentTarget as HTMLDivElement).style.cursor = "grabbing";
  };
  const onMouseMove = (e: React.MouseEvent) => {
    const d = drag.current;
    if (!d) return;
    const dx = e.clientX - d.sx;
    const dy = e.clientY - d.sy;
    setView((v) => ({ ...v, x: d.vx + dx, y: d.vy + dy }));
  };
  const endDrag = (e: React.MouseEvent) => {
    drag.current = null;
    if (e.currentTarget) (e.currentTarget as HTMLDivElement).style.cursor = "grab";
  };
  const onWheel = (e: React.WheelEvent) => {
    e.preventDefault();
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect) return;
    const mx = e.clientX - rect.left;
    const my = e.clientY - rect.top;
    const factor = e.deltaY < 0 ? 1.1 : 1 / 1.1;
    setView((v) => {
      const nextScale = Math.min(8, Math.max(0.4, v.scale * factor));
      const k = nextScale / v.scale;
      return { scale: nextScale, x: mx - k * (mx - v.x), y: my - k * (my - v.y) };
    });
  };
  const reset = () => setView({ x: 0, y: 0, scale: 1 });
  const zoom = (delta: number) =>
    setView((v) => {
      const next = Math.min(8, Math.max(0.4, v.scale + delta));
      return { ...v, scale: next };
    });

  return (
    <div
      ref={containerRef}
      className="map-canvas"
      onMouseDown={onMouseDown}
      onMouseMove={onMouseMove}
      onMouseUp={endDrag}
      onMouseLeave={endDrag}
      onWheel={onWheel}
      style={{ cursor: "grab" }}
    >
      <div className="map-bg" />
      <svg
        viewBox={`${minX} ${minY} ${W} ${H}`}
        preserveAspectRatio="xMidYMid meet"
        style={{
          width: "100%",
          height: "100%",
          display: "block",
          transform: `translate(${view.x}px, ${view.y}px) scale(${view.scale})`,
          transformOrigin: "0 0",
          transition: drag.current ? "none" : "transform 0.12s ease-out",
        }}
      >
        <defs>
          <pattern id="grid-ink" width="40" height="40" patternUnits="userSpaceOnUse">
            <circle cx="1" cy="1" r="0.6" fill="#3a2a1a" opacity="0.08" />
          </pattern>
        </defs>
        <rect x={minX} y={minY} width={W} height={H} fill="#f6efde" />
        <rect x={minX} y={minY} width={W} height={H} fill="url(#grid-ink)" />

        {/* Background tile pass — every grid cell. Active regions get their
            color; inactive regions are muted grey; cells past the wilderness
            ring are full grey. */}
        <g>
          {data.tiles.map((tile) => {
            const region = tile.regionId ? regionById[tile.regionId] : null;
            const isActive = !!(tile.regionId && activeSet.has(tile.regionId));
            return (
              <BackgroundCell
                key={`bg-${tile.q}-${tile.r}`}
                tile={tile}
                region={region ?? null}
                isActive={isActive}
              />
            );
          })}
        </g>

        {regions.map((r) => (
          <TerritoryHull
            key={r.id}
            region={r}
            tiles={data.tiles}
            isActive={activeSet.has(r.id)}
            crateName={crateByRegion.get(r.id) ?? null}
          />
        ))}

        <g>
          {edges.map((e, i) => {
            const ma = modules.find((m) => m.id === e.from);
            const mb = modules.find((m) => m.id === e.to);
            if (!ma || !mb) return null;
            const pa = hexToPixel(ma.q, ma.r);
            const pb = hexToPixel(mb.q, mb.r);
            const isActive = activeId && (e.from === activeId || e.to === activeId);
            return (
              <line
                key={i}
                x1={pa.x}
                y1={pa.y}
                x2={pb.x}
                y2={pb.y}
                stroke={isActive ? "#7A2E1E" : "#5b4a32"}
                strokeWidth={isActive ? 3 : 1.6}
                strokeOpacity={dimming && !isActive ? 0.1 : isActive ? 0.92 : 0.36}
                strokeDasharray={isActive ? "none" : "4 4"}
              />
            );
          })}
        </g>

        {modules.map((mod) => {
          const region = regionById[mod.territory];
          if (!region) return null;
          const isMatch = matchSet ? matchSet.has(mod.id) : true;
          const isActive = activeId === mod.id || connected.has(mod.id);
          const isHover = hoverModule === mod.id;
          const isDimmed =
            (matchSet ? !isMatch : false) || (activeId ? !connected.has(mod.id) : false);
          return (
            <ModuleCell
              key={mod.id}
              mod={mod}
              region={region}
              isActive={isActive}
              isHover={isHover}
              isDimmed={isDimmed}
              onClick={(m) => onSelectModule(m.id)}
              onHover={setHoverModule}
              battle={battleByModule.get(mod.id) ?? null}
            />
          );
        })}

        {/* Text overlay — drawn last so neither bg fills nor module overlays hide labels. */}
        <g>
          {data.tiles.map((tile) => {
            if (!tile.townName) return null;
            const region = tile.regionId ? regionById[tile.regionId] : null;
            const isRegionActive = !!(tile.regionId && activeSet.has(tile.regionId));
            const module = tile.moduleId
              ? modules.find((m) => m.id === tile.moduleId) ?? null
              : null;
            return (
              <TileLabel
                key={`label-${tile.q}-${tile.r}`}
                tile={tile}
                region={region}
                isRegionActive={isRegionActive}
                module={module}
              />
            );
          })}
        </g>

        {/* Compass */}
        <g transform={`translate(${minX + 60}, ${minY + 60})`} style={{ pointerEvents: "none" }}>
          <circle r="32" fill="#fdfaf0" stroke="#7A2E1E" strokeWidth="2" />
          <text textAnchor="middle" y="-14" fontSize="11" fontFamily="'Noto Serif SC', serif" fontWeight="700" fill="#7A2E1E">北</text>
          <text textAnchor="middle" y="22" fontSize="11" fontFamily="'Noto Serif SC', serif" fontWeight="700" fill="#7A2E1E">南</text>
          <text textAnchor="end" x="-10" y="4" fontSize="11" fontFamily="'Noto Serif SC', serif" fontWeight="700" fill="#7A2E1E">西</text>
          <text textAnchor="start" x="10" y="4" fontSize="11" fontFamily="'Noto Serif SC', serif" fontWeight="700" fill="#7A2E1E">东</text>
          <path d="M 0,-22 L 4,0 L 0,22 L -4,0 Z" fill="#D9534F" stroke="#7A2E1E" strokeWidth="1" />
        </g>
      </svg>

      <div className="map-controls" onClick={(e) => e.stopPropagation()} onMouseDown={(e) => e.stopPropagation()}>
        <button onClick={() => zoom(0.15)} title="Zoom in">+</button>
        <button onClick={() => zoom(-0.15)} title="Zoom out">−</button>
        <button onClick={reset} title="Reset view">⌖</button>
        <div className="map-zoom-pct">{Math.round(view.scale * 100)}%</div>
      </div>
      <div className="map-hint">drag to pan · scroll to zoom</div>
    </div>
  );
}
