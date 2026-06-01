let toastTimer: number | undefined;

export async function copyToClipboard(text: string, label?: string) {
  try {
    await navigator.clipboard?.writeText(text);
    showToast(label ? `复制 ✓ ${label}` : `复制 ✓ ${text}`);
  } catch {
    showToast("clipboard unavailable");
  }
}

export function showToast(text: string, ttl = 1600) {
  let el = document.querySelector(".toast") as HTMLDivElement | null;
  if (!el) {
    el = document.createElement("div");
    el.className = "toast";
    document.body.appendChild(el);
  }
  el.textContent = text;
  if (toastTimer !== undefined) window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    el?.remove();
    toastTimer = undefined;
  }, ttl);
}
