import React, { useState } from "react";

export function CopyChip({ text, label }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      className="copy-chip"
      onClick={(e) => {
        e.stopPropagation();
        navigator.clipboard?.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1100);
      }}
      title="Copy path"
    >
      <span className="copy-chip-text">{label ?? text}</span>
      <span className="copy-chip-icon">{copied ? "✓" : "⎘"}</span>
    </button>
  );
}

export function Breadcrumb({ parts }: { parts: string[] }) {
  return (
    <div className="breadcrumb">
      {parts.map((p, i) => (
        <React.Fragment key={i}>
          {i > 0 && <span className="breadcrumb-sep">›</span>}
          <span className={i === parts.length - 1 ? "breadcrumb-here" : "breadcrumb-step"}>{p}</span>
        </React.Fragment>
      ))}
    </div>
  );
}

export function StatRow({
  label,
  value,
  accent,
}: {
  label: string;
  value: React.ReactNode;
  accent?: string;
}) {
  return (
    <div className="stat-row">
      <span className="stat-label">{label}</span>
      <span className="stat-value" style={accent ? { color: accent } : undefined}>
        {value}
      </span>
    </div>
  );
}

export function SectionTitle({
  children,
  count,
}: {
  children: React.ReactNode;
  count?: number;
}) {
  return (
    <div className="section-title">
      <span className="section-rule" />
      <span className="section-text">{children}</span>
      {count != null && <span className="section-count">{count}</span>}
      <span className="section-rule" />
    </div>
  );
}

export function EmptyNote({ children }: { children: React.ReactNode }) {
  return <div className="empty-note">{children}</div>;
}

export function ErrorBanner({ children }: { children: React.ReactNode }) {
  return <div className="md-error">{children}</div>;
}
