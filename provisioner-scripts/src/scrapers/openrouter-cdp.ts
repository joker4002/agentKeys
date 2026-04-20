// Stage 5b CDP scraper — connects to a user-launched Chrome via CDP, drives
// OpenRouter signup through Clerk + Turnstile, retrieves the OTP from Gmail
// IMAP, mints a new API key, outputs the sk-or-v1-* value on stdout.
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

const log = (msg: string) => console.error(`[cdp] ${new Date().toISOString().slice(11, 19)} ${msg}`);

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

    // Watch for either (a) OTP form appears, (b) Turnstile surfaces visible challenge, or (c) redirect to dashboard
    log("waiting for Turnstile + form to advance (up to 180s; user may need to click a visible challenge)");
    const started = Date.now();
    while (Date.now() - started < 180_000) {
      const url = page.url();
      if (!url.includes("/sign-up")) {
        log(`URL advanced to ${url.slice(0, 60)}`);
        break;
      }
      // Look for a Clerk OTP input (appears on the "verify your email" step)
      const otpPresent = await page.locator('input[name="code"], input[inputmode="numeric"], input[autocomplete="one-time-code"]').count();
      if (otpPresent > 0) {
        log("OTP input appeared");
        break;
      }
      // Check for an explicit error
      const err = await page.locator('[role="alert"], .cl-formFieldError, .cl-alertText').allInnerTexts();
      const realErr = err.find(t => t && !/password meets/i.test(t));
      if (realErr) {
        throw new Error(`form error: ${realErr}`);
      }
      await page.waitForTimeout(2500);
    }

    // If still on /sign-up and no OTP input, Turnstile never resolved.
    const otpSel = 'input[name="code"], input[inputmode="numeric"], input[autocomplete="one-time-code"]';
    if (page.url().includes("/sign-up")) {
      const otpCount = await page.locator(otpSel).count();
      if (otpCount === 0) {
        throw new Error(
          "form still on /sign-up after 180s AND no OTP input — Turnstile likely never resolved. " +
          "Check the Chrome window: is the Turnstile checkbox visible and waiting? " +
          "Or did the page navigate elsewhere (e.g. /terms if the ToS link was accidentally clicked)?"
        );
      }
      log("OTP step is embedded on sign-up page (polling Gmail IMAP)");
      await page.waitForSelector(otpSel, { timeout: 10_000 });

      log("fetching code from Gmail IMAP");
      const code = await fetchVerificationCode({
        from: /noreply@openrouter\.ai/,
        subject: /openrouter/i,
        codeRegex: /(\d{6})/,
        timeoutMs: 90_000,
      });
      log(`got OTP: ${code}`);

      // Clerk OTP is usually split into 6 single-char inputs, but some versions are one input.
      const otpInputs = await page.locator(otpSel).all();
      if (otpInputs.length === 1) {
        await otpInputs[0].fill(code);
      } else if (otpInputs.length === 6) {
        for (let i = 0; i < 6; i++) await otpInputs[i].fill(code[i]);
      } else {
        throw new Error(`unexpected OTP input count: ${otpInputs.length}`);
      }

      // Submit button on verify step
      const verifyBtn = page.locator('button[data-localization-key="formButtonPrimary"]');
      if (await verifyBtn.isEnabled({ timeout: 3000 })) {
        await verifyBtn.click();
      }

      log("waiting for redirect away from /sign-up");
      await page.waitForURL(u => !u.toString().includes("/sign-up"), { timeout: 30_000 });
    }

    log("navigating to /keys");
    await page.goto("https://openrouter.ai/keys", { waitUntil: "networkidle", timeout: 20_000 });

    log("looking for Create Key button");
    const createBtn = page.locator('button:has-text("Create Key"), button:has-text("Create API Key"), [data-testid="create-key-btn"]').first();
    await createBtn.waitFor({ timeout: 15_000 });
    await createBtn.click();

    log("filling key name");
    const nameInput = page.locator('input[placeholder*="name" i], input[name="name"]').first();
    if (await nameInput.count()) {
      await nameInput.fill(`agentkeys-stage5b-${Date.now()}`);
    }

    log("confirming create");
    const confirm = page.locator('button:has-text("Create"), button[type="submit"]').last();
    await confirm.click();

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

main().catch(err => {
  log(`FATAL: ${err.message}`);
  console.error(err.stack);
  process.exit(1);
});
