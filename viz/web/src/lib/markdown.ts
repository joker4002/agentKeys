import MarkdownIt from "markdown-it";

const md = new MarkdownIt({
  html: false,
  linkify: false,
  typographer: false,
});

const PATH_LINE_RE = /\b([\w./~-]+\.[a-zA-Z0-9]{1,8}):(\d+)\b/g;
const PATH_BARE_RE = /(?<=^|[\s(`])((?:\.\.\/|\.\/|\/|~\/|[a-z][\w-]+\/)[\w./~-]+\.(?:md|rs|ts|tsx|js|jsx|toml|json|sol|sh|py|yml|yaml))(?=[\s)`]|$)/g;

md.core.ruler.push("path-pills", (state) => {
  for (const block of state.tokens) {
    if (block.type !== "inline" || !block.children) continue;
    const out: typeof block.children = [];
    for (const tok of block.children) {
      if (tok.type !== "text") {
        out.push(tok);
        continue;
      }
      const text = tok.content;
      const matches: { idx: number; len: number; html: string }[] = [];
      PATH_LINE_RE.lastIndex = 0;
      let m: RegExpExecArray | null;
      while ((m = PATH_LINE_RE.exec(text)) !== null) {
        const ref = m[0];
        const isMd = ref.toLowerCase().endsWith(".md") || /\.md:\d+$/.test(ref);
        matches.push({
          idx: m.index,
          len: ref.length,
          html: pillHtml(ref, isMd),
        });
      }
      // bare paths (no :line)
      PATH_BARE_RE.lastIndex = 0;
      while ((m = PATH_BARE_RE.exec(text)) !== null) {
        if (matches.some((x) => m!.index >= x.idx && m!.index < x.idx + x.len)) continue;
        const ref = m[1];
        const isMd = ref.toLowerCase().endsWith(".md");
        matches.push({ idx: m.index, len: ref.length, html: pillHtml(ref, isMd) });
      }
      matches.sort((a, b) => a.idx - b.idx);

      let lastIdx = 0;
      for (const match of matches) {
        if (match.idx > lastIdx) {
          const t = new state.Token("text", "", 0);
          t.content = text.slice(lastIdx, match.idx);
          out.push(t);
        }
        const html = new state.Token("html_inline", "", 0);
        html.content = match.html;
        out.push(html);
        lastIdx = match.idx + match.len;
      }
      if (lastIdx < text.length) {
        const t = new state.Token("text", "", 0);
        t.content = text.slice(lastIdx);
        out.push(t);
      }
    }
    block.children = out;
  }
});

function pillHtml(ref: string, isMd: boolean): string {
  const action = isMd ? "open" : "copy";
  return `<button class="copy-pill" type="button" data-ref="${escAttr(ref)}" data-action="${action}">${escAttr(ref)}</button>`;
}

function escAttr(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// Add id="slug" attribute to every heading so the TOC can scroll to them.
md.core.ruler.push("heading-ids", (state) => {
  for (let i = 0; i < state.tokens.length; i++) {
    const t = state.tokens[i];
    if (t.type !== "heading_open") continue;
    const inline = state.tokens[i + 1];
    if (!inline || inline.type !== "inline") continue;
    const id = slugify(inline.content);
    if (id) t.attrSet("id", id);
  }
});

// Wrap every code block with a hover-revealed copy button positioned top-right.
// Covers both fenced (```lang … ```) and indented (4-space) code blocks.
const defaultFence = md.renderer.rules.fence!;
md.renderer.rules.fence = function (tokens, idx, options, env, self) {
  const original = defaultFence(tokens, idx, options, env, self);
  return wrapWithCopy(tokens[idx].content, tokens[idx].info, original);
};
const defaultCodeBlock = md.renderer.rules.code_block!;
md.renderer.rules.code_block = function (tokens, idx, options, env, self) {
  const original = defaultCodeBlock(tokens, idx, options, env, self);
  return wrapWithCopy(tokens[idx].content, "", original);
};

function wrapWithCopy(code: string, info: string, rendered: string): string {
  const lang = (info || "").trim().split(/\s+/)[0];
  const langTag = lang ? `<span class="md-code-lang">${escAttr(lang)}</span>` : "";
  return `<div class="md-code-wrap">${langTag}<button class="md-code-copy" type="button" data-code="${escAttr(code)}" aria-label="copy code" title="Copy code"><span class="md-code-copy-glyph">⎘</span><span class="md-code-copy-done">✓</span></button>${rendered}</div>`;
}

export function renderMarkdown(text: string): string {
  return md.render(text);
}

export interface TocEntry {
  level: number;
  text: string;
  id: string;
}

export function extractToc(markdown: string): TocEntry[] {
  // Strip fenced code blocks first so headings inside ``` don't get picked up.
  const stripped = markdown.replace(/^```[\s\S]*?^```/gm, "");
  const out: TocEntry[] = [];
  for (const line of stripped.split("\n")) {
    const m = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (!m) continue;
    const level = m[1].length;
    const text = m[2].trim();
    const id = slugify(text);
    if (id) out.push({ level, text, id });
  }
  return out;
}

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/`/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
}
