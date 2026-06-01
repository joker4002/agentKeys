import React, { useEffect, useMemo, useState } from "react";
import {
  Background,
  Controls,
  MiniMap,
  ReactFlow,
  type Edge,
  type Node,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import { api } from "../api";
import type { JjEntry, JjPayload } from "../types";
import { copyToClipboard } from "../lib/copy";

const NODE_W = 380;
const NODE_H = 88;
const NODE_VGAP = 36;

interface ChangeNodeData extends Record<string, unknown> {
  entry: JjEntry;
}

function ChangeNode({ data }: { data: ChangeNodeData }) {
  const { entry } = data;
  return (
    <div
      className={`jj-node ${entry.is_working_copy ? "is-current" : ""}`}
      onClick={() => void copyToClipboard(entry.change_id)}
      title="click to copy change_id"
    >
      <div className="jj-node-row1">
        {entry.is_working_copy && <span className="jj-current-dot">@</span>}
        <code className="jj-change-id">{entry.change_id}</code>
        <div className="jj-bookmarks">
          {entry.bookmarks.map((bm) => (
            <span key={bm} className={`jj-bm ${bm.includes("@") ? "is-remote" : ""}`}>
              {bm}
            </span>
          ))}
        </div>
      </div>
      <div className="jj-node-desc">{entry.description || <em>(no description)</em>}</div>
    </div>
  );
}

const nodeTypes = { change: ChangeNode };

export function JjBody() {
  const [data, setData] = useState<JjPayload | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [tab, setTab] = useState<"graph" | "bookmarks">("graph");

  useEffect(() => {
    api.jj().then(setData).catch((e) => setErr(String(e)));
  }, []);

  const { nodes, edges } = useMemo(() => {
    if (!data) return { nodes: [] as Node[], edges: [] as Edge[] };
    const ns: Node[] = data.log.map((entry, i) => ({
      id: entry.change_id,
      type: "change",
      position: { x: 0, y: i * (NODE_H + NODE_VGAP) },
      data: { entry } as ChangeNodeData,
      draggable: false,
      selectable: false,
      width: NODE_W,
      height: NODE_H,
    }));
    const es: Edge[] = [];
    for (let i = 0; i < data.log.length - 1; i++) {
      es.push({
        id: `e-${i}`,
        source: data.log[i].change_id,
        target: data.log[i + 1].change_id,
        type: "step",
        style: { stroke: "#5b4a32", strokeWidth: 1.5 },
      });
    }
    return { nodes: ns, edges: es };
  }, [data]);

  if (err) return <div className="md-error">{err}</div>;
  if (!data) return <div className="empty-note">Loading…</div>;

  return (
    <>
      <div className="char-tabs">
        <button
          className={`char-tab ${tab === "graph" ? "is-active" : ""}`}
          onClick={() => setTab("graph")}
        >
          Log graph
          <span className="char-tab-count">{data.log.length}</span>
        </button>
        <button
          className={`char-tab ${tab === "bookmarks" ? "is-active" : ""}`}
          onClick={() => setTab("bookmarks")}
        >
          Bookmarks
          <span className="char-tab-count">{data.bookmarks.length}</span>
        </button>
      </div>

      {data.error && <div className="md-error">{data.error}</div>}

      {tab === "graph" && (
        <div className="jj-flow-wrap">
          <ReactFlow
            nodes={nodes}
            edges={edges}
            nodeTypes={nodeTypes}
            fitView
            fitViewOptions={{ padding: 0.15 }}
            minZoom={0.3}
            maxZoom={1.6}
            proOptions={{ hideAttribution: true }}
          >
            <MiniMap pannable zoomable />
            <Controls showInteractive={false} />
            <Background gap={16} size={1} color="#cfc4a8" />
          </ReactFlow>
        </div>
      )}

      {tab === "bookmarks" && (
        <div className="jj-bm-list">
          {data.bookmarks.length === 0 && <div className="empty-note">no bookmarks</div>}
          {data.bookmarks.map((b, i) => (
            <div key={`${b.name}-${i}`} className="jj-bm-row">
              <div className="jj-bm-row-head">
                <span className={`jj-bm ${b.remote ? "is-remote" : ""}`}>
                  {b.name}
                  {b.remote ? `@${b.remote}` : ""}
                </span>
                <code className="jj-change-id">{b.change_id}</code>
              </div>
              <div className="jj-bm-row-desc">{b.description || <em>(empty)</em>}</div>
            </div>
          ))}
        </div>
      )}
    </>
  );
}
