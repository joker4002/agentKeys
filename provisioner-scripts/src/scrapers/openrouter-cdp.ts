// Stage 5b CDP scraper — connects to a user-launched Chrome via CDP, drives
// OpenRouter signup through Clerk + Turnstile, retrieves verification (either
// a 6-digit OTP or a magic-link URL, whichever Clerk is currently serving)
// from the configured email backend, mints a new API key, outputs the
// sk-or-v1-* value on stdout.
//
// Why this exists:
// Playwright's bundled Chromium launches with --enable-automation baked in
// by the Playwright library. Cloudflare Turnstile detects this at runtime
// (error 600010: "browser execution environment suspicious") and refuses
// to issue a token even when a human clicks the checkbox. Connecting via
// CDP to a user-launched real Chrome bypasses this because the browser
// process has no automation flags.
//
// How to use:
//   # 1. User launches a fresh real Chrome with remote-debugging enabled:
//   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
//     --remote-debugging-port=9222 \
//     --user-data-dir=/tmp/agentkeys-chrome-profile &
//   # 2. Export env — SIGNUP_EMAIL must be a local-part OpenRouter hasn't seen;
//   #    Clerk normalizes Gmail/Workspace plus-aliases so +suffix reuse is rejected.
//   export AGENTKEYS_SIGNUP_EMAIL="<fresh-local-part>@<your-domain>"
//   export AGENTKEYS_SIGNUP_PASSWORD="<strong-random>"
//   export AGENTKEYS_EMAIL_USER="you@gmail.com"            # canonical IMAP login
//   export AGENTKEYS_EMAIL_PASSWORD="<gmail app password>"
//   export AGENTKEYS_EMAIL_HOST="imap.gmail.com"
//   export AGENTKEYS_EMAIL_PORT="993"
//   # 3. Run:
//   node --import tsx/esm provisioner-scripts/src/scrapers/openrouter-cdp.ts
//
// Waits up to 180s for Turnstile to resolve + form to advance. If Turnstile
// surfaces a visible challenge, the user must click it on screen within that
// window. Final line on stdout is the sk-or-v1-* key; progress logs go to stderr.

import { chromium, type Browser, type Page } from "playwright";
import { fetchVerificationCode } from "../lib/email.js";

const CDP_URL = process.env.CDP_URL ?? "http://localhost:9222";
const SIGNUP_EMAIL = process.env.AGENTKEYS_SIGNUP_EMAIL ?? "";
const SIGNUP_PASSWORD = process.env.AGENTKEYS_SIGNUP_PASSWORD ?? "";

// Real sender observed in Stage 6: "OpenRouter <notifications@openrouter.ai>".
// Matches any @openrouter.ai mailbox plus generic clerk-hosted senders.
const OPENROUTER_VERIFICATION_FROM = /@openrouter\.ai|clerk/i;

// Subjects observed in Stage 6 across runs: "Your sign up link", "Verify your
// email for OpenRouter". Matches authentication-flow phrases so non-auth
// traffic from the same sender (credit summaries, marketing) is skipped.
const OPENROUTER_VERIFICATION_SUBJECT = /sign[\s-]?up.*link|sign[\s-]?in.*link|magic.*link|verify|verification|confirm/i;

// Clerk magic-link URLs typically include "clerk", "/verify", or "ticket=".
// The codeRegex runs against a QP-decoded body so reserved chars are already
// normalized back to =/? by the ses-s3 backend.
const OPENROUTER_VERIFICATION_URL = /(https:\/\/[^\s<>"'\)]*(?:clerk|\/verify|ticket=|verification)[^\s<>"'\)]*)/i;

const log = (msg: string) => console.error(`[cdp] ${new Date().toISOString().slice(11, 19)} ${msg}`);

// Shared so the FATAL handler can snapshot the live page on crash.
let livePage: Page | null = null;

// HTML entities that may appear in URLs extracted from plain-text email parts.
// &amp; is the breaking one — query-param separators silently mis-parse.
function decodeHtmlEntitiesInUrl(url: string): string {
  return url
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#x27;/g, "'");
}

async function main() {
  if (!SIGNUP_EMAIL || !SIGNUP_PASSWORD) {
    throw new Error("AGENTKEYS_SIGNUP_EMAIL and AGENTKEYS_SIGNUP_PASSWORD env vars are required");
  }
  if (!process.env.AGENTKEYS_EMAIL_USER || !process.env.AGENTKEYS_EMAIL_PASSWORD) {
    throw new Error("AGENTKEYS_EMAIL_USER + AGENTKEYS_EMAIL_PASSWORD required for OTP retrieval");
  }

  log(`connecting to CDP at ${CDP_URL}`);
  const browser: Browser = await chromium.connectOverCDP(CDP_URL);
  const contexts = browser.contexts();
  const ctx = contexts[0] ?? await browser.newContext();
  const page: Page = ctx.pages()[0] ?? await ctx.newPage();
  livePage = page;

  try {
    log("navigating to openrouter.ai/auth");
    await page.goto("https://openrouter.ai/auth", { waitUntil: "networkidle", timeout: 30_000 });

    log("waiting for email input");
    await page.waitForSelector("#emailAddress-field", { timeout: 15_000 });

    log(`filling email = ${SIGNUP_EMAIL}`);
    await page.fill("#emailAddress-field", SIGNUP_EMAIL);

    log("filling password");
    await page.fill("#password-field", SIGNUP_PASSWORD);

    log("checking TOS checkbox");
    // DO NOT click the <label> — it wraps both the checkbox AND a "Terms of
    // Service" link; clicking the label text often lands on the link and
    // navigates to /terms. Click the checkbox input directly instead.
    await page.locator('#legalAccepted-field').check({ force: true, timeout: 3000 });

    log("clicking Continue");
    await page.locator('button[data-localization-key="formButtonPrimary"]').first().click({ timeout: 5_000 });

    // Watch for one of:
    //   (a) URL leaves /sign-up (Turnstile advanced the form, or magic-link already clicked)
    //   (b) OTP input appears (legacy 6-digit flow)
    //   (c) "Verify your email" link screen appears (current Clerk magic-link flow)
    //   (d) Turnstile surfaces a visible challenge — user clicks it in Chrome
    const OTP_SEL = 'input[name="code"], input[inputmode="numeric"], input[autocomplete="one-time-code"]';
    const MAGIC_LINK_SEL = 'text=/verification link|use the link/i';
    type VerifyMode = "url-advanced" | "otp" | "magic-link";

    log("waiting for Turnstile + form to advance (up to 180s; user may need to click a visible challenge)");
    const started = Date.now();
    let mode: VerifyMode | null = null;
    while (Date.now() - started < 180_000) {
      const url = page.url();
      if (!url.includes("/sign-up")) {
        log(`URL advanced to ${url.slice(0, 60)}`);
        mode = "url-advanced";
        break;
      }
      const otpPresent = await page.locator(OTP_SEL).count();
      if (otpPresent > 0) {
        log("OTP input appeared (legacy 6-digit flow)");
        mode = "otp";
        break;
      }
      const magicLinkPresent = await page.locator(MAGIC_LINK_SEL).count();
      if (magicLinkPresent > 0) {
        log("magic-link verification screen detected");
        mode = "magic-link";
        break;
      }
      const err = await page.locator('[role="alert"], .cl-formFieldError, .cl-alertText').allInnerTexts();
      const realErr = err.find(t => t && !/password meets/i.test(t));
      if (realErr) {
        throw new Error(`form error: ${realErr}`);
      }
      await page.waitForTimeout(2500);
    }

    if (mode === null) {
      throw new Error(
        "form still on /sign-up after 180s AND no OTP/magic-link screen — Turnstile likely never resolved. " +
        "Check the Chrome window: is the Turnstile checkbox visible and waiting? " +
        "Or did the page navigate elsewhere (e.g. /terms if the ToS link was accidentally clicked)?"
      );
    }

    if (mode === "otp") {
      log("fetching 6-digit OTP from email");
      const code = await fetchVerificationCode({
        from: OPENROUTER_VERIFICATION_FROM,
        subject: OPENROUTER_VERIFICATION_SUBJECT,
        codeRegex: /(\d{6})/,
        timeoutMs: 90_000,
      });
      log(`got OTP: ${code}`);

      // Clerk OTP is usually split into 6 single-char inputs, but some versions are one input.
      const otpInputs = await page.locator(OTP_SEL).all();
      if (otpInputs.length === 1) {
        await otpInputs[0].fill(code);
      } else if (otpInputs.length === 6) {
        for (let i = 0; i < 6; i++) await otpInputs[i].fill(code[i]);
      } else {
        throw new Error(`unexpected OTP input count: ${otpInputs.length}`);
      }

      const verifyBtn = page.locator('button[data-localization-key="formButtonPrimary"]');
      if (await verifyBtn.isEnabled({ timeout: 3000 })) {
        await verifyBtn.click();
      }

      log("waiting for redirect away from /sign-up");
      await page.waitForURL(u => !u.toString().includes("/sign-up"), { timeout: 30_000 });
    }

    if (mode === "magic-link") {
      log("fetching verification link from email");
      const verifyUrlRaw = await fetchVerificationCode({
        from: OPENROUTER_VERIFICATION_FROM,
        subject: OPENROUTER_VERIFICATION_SUBJECT,
        codeRegex: OPENROUTER_VERIFICATION_URL,
        timeoutMs: 90_000,
      });
      // OpenRouter's plain-text part HTML-encodes ampersands (`&amp;`) inside
      // the verification URL. Passing that to page.goto() makes Clerk's query
      // parser treat `&amp;token=X` as a single param literally named
      // `amp;token`; Clerk's token lookup fails, verification silently hangs.
      // Decode common HTML entities before navigation.
      const verifyUrl = decodeHtmlEntitiesInUrl(verifyUrlRaw);
      if (verifyUrl !== verifyUrlRaw) {
        log("decoded HTML entities in URL (e.g. &amp; -> &)");
      }
      log(`got verify URL: ${verifyUrl.slice(0, 80)}${verifyUrl.length > 80 ? "..." : ""}`);

      log("navigating current tab to verify URL");
      await page.goto(verifyUrl, { waitUntil: "networkidle", timeout: 30_000 });

      log("waiting for redirect away from /sign-up");
      await page.waitForURL(u => !u.toString().includes("/sign-up"), { timeout: 30_000 });
    }

    log("navigating to /keys");
    await page.goto("https://openrouter.ai/keys", { waitUntil: "networkidle", timeout: 20_000 });

    // First-run onboarding: OpenRouter shows a "Where did you first hear about
    // OpenRouter?" modal before exposing the API Keys UI. The Create Key
    // button sits behind the modal and fails to become visible. Dismiss the
    // modal by selecting a neutral option and clicking Continue. No-op on
    // subsequent visits (modal already answered).
    log("checking for first-run onboarding modal");
    const onboardingHeader = page.locator('text=/where did you first hear/i').first();
    const modalPresent = await onboardingHeader.isVisible({ timeout: 3_000 }).catch(() => false);
    if (modalPresent) {
      log("onboarding modal detected — selecting 'Other / Not sure'");
      const otherOption = page
        .getByRole("radio", { name: /other.*not sure/i })
        .or(page.getByLabel(/other.*not sure/i))
        .or(page.getByText(/^other.*not sure$/i))
        .first();
      await otherOption.click({ timeout: 5_000 });

      log("clicking Continue");
      const continueBtn = page.getByRole("button", { name: /^continue$/i }).first();
      await continueBtn.click({ timeout: 5_000 });

      log("waiting for onboarding modal to dismiss");
      await onboardingHeader.waitFor({ state: "hidden", timeout: 10_000 }).catch(() => {
        log("onboarding modal did not dismiss cleanly — continuing anyway");
      });
    } else {
      log("no onboarding modal (existing account or already dismissed)");
    }

    log("looking for Create Key button");
    // Current OpenRouter empty state: plain "Create" button. Older UI used
    // "Create Key" / "Create API Key". Accept all; `/^create$/i` matches the
    // exact-text button. `[data-testid]` kept as belt-and-suspenders.
    const createBtn = page
      .getByRole("button", { name: /^create$/i })
      .or(page.getByRole("button", { name: /create.*api.*key/i }))
      .or(page.getByRole("button", { name: /create.*key/i }))
      .or(page.locator('[data-testid="create-key-btn"]'))
      .first();
    await createBtn.waitFor({ state: "visible", timeout: 15_000 });
    await createBtn.click();

    log("filling key name (if name dialog opened)");
    const nameInput = page.locator('input[placeholder*="name" i], input[name="name"]').first();
    if (await nameInput.count()) {
      await nameInput.fill(`agentkeys-stage5b-${Date.now()}`);
    }

    log("confirming create");
    // Find the submit/create button inside the dialog. Prefer the visible one
    // with "Create" text, fall back to any submit button.
    const confirm = page
      .getByRole("button", { name: /^create$/i })
      .or(page.locator('button[type="submit"]'))
      .last();
    await confirm.click({ timeout: 5_000 });

    log("waiting for key to appear");
    const keyEl = page.locator('code:has-text("sk-or-v1-"), pre:has-text("sk-or-v1-"), input[value^="sk-or-v1-"]').first();
    await keyEl.waitFor({ timeout: 15_000 });

    const tag = await keyEl.evaluate(n => n.tagName.toLowerCase());
    const raw =
      tag === "input"
        ? await keyEl.inputValue()
        : (await keyEl.textContent()) ?? "";

    const key = raw.trim();
    log(`extracted key: ${key.slice(0, 12)}****...${key.slice(-4)}`);
    if (!/^sk-or-v1-[a-zA-Z0-9]{20,}$/.test(key)) {
      throw new Error(`extracted value doesn't match sk-or-v1-* format: ${key.slice(0, 40)}...`);
    }
    process.stdout.write(key + "\n");
  } finally {
    // Don't close the browser — user may want to keep their session.
  }
}

main().catch(async err => {
  const msg = err?.message ?? err?.toString?.() ?? JSON.stringify(err);
  log(`FATAL: ${msg}`);
  if (err?.stack) console.error(err.stack);
  else console.error(JSON.stringify(err, Object.getOwnPropertyNames(err ?? {}), 2));
  if (livePage) {
    try {
      const url = livePage.url();
      const shotPath = `/tmp/cdp-fatal-${Date.now()}.png`;
      await livePage.screenshot({ path: shotPath, fullPage: true });
      log(`page snapshot on fatal — url=${url} screenshot=${shotPath}`);
    } catch (screenshotErr) {
      log(`could not capture fatal screenshot: ${(screenshotErr as Error).message}`);
    }
  }
  process.exit(1);
});
