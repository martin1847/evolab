/**
 * TEMPLATE — copy into the project's own e2e directory and adapt.
 *
 * Why this exists: an exploratory pass needs the app *running and signed in*
 * for as long as the pass takes. Most projects already have exactly that
 * machinery inside their e2e suite (server lifecycle, a migrated throwaway
 * database, a way to mint a fresh user) and nowhere else. Rather than
 * reimplement it, borrow it: log in the way the suite already logs in, write
 * the session out, then refuse to finish.
 *
 * The teardown you already have keeps working — Ctrl-C ends the case and the
 * suite's normal cleanup runs. From a script: launch this case in its OWN process
 * group (`setsid`, remember that pgid) and end it with `kill -INT -- -<pgid>`;
 * signalling only the wrapper PID does nothing, because bash runs its trap after
 * the foreground child exits.
 *
 * Three things to adapt (marked ADAPT below):
 *   1. the import + call that produces a signed-in page,
 *   2. the base URL the app is served on,
 *   3. nothing else.
 *
 * This file must never join the assertion suite: it has no assertions, it
 * never terminates on its own, and any "executed floor" / required-test check
 * the project runs should exclude it.
 */
import fs from "node:fs";
import path from "node:path";

import { test } from "@playwright/test";

// ADAPT 1: whatever your suite already uses to get an authenticated page.
import { signInAsFreshUser } from "./your-auth-helper";

/** Everything this case emits, in one gitignored directory. */
const OUT_DIR = process.env.EXPLORE_DIR ?? path.resolve(__dirname, "../../.explore");

/** How long the stack stays up. Ctrl-C ends it sooner. */
const HOLD_MS = Number(process.env.EXPLORE_HOLD_MS ?? 45 * 60_000);

// ADAPT 2: the origin the app is served on for this run.
const BASE_URL = process.env.EXPLORE_BASE_URL ?? "http://127.0.0.1:3000";

test("explore hold: sign in and keep the stack alive", async ({ page, context }) => {
  // No timeout at all: the point is to outlive a normal test.
  test.setTimeout(0);

  const user = await signInAsFreshUser(page);

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const statePath = path.join(OUT_DIR, "storage-state.json");
  await context.storageState({ path: statePath });

  // The explorer reads session.json; the config's auth.session_file points here.
  const session = {
    baseUrl: BASE_URL,
    storageState: statePath,
    login: user.login,
    entry: `${BASE_URL}/`, // ADAPT: the first screen of the journey.
    holdMinutes: HOLD_MS / 60_000,
  };
  fs.writeFileSync(path.join(OUT_DIR, "session.json"), `${JSON.stringify(session, null, 2)}\n`);

  console.log(`explore-hold: ready at ${session.entry}`);
  console.log(`explore-hold: storage state -> ${statePath}`);
  console.log(`explore-hold: holding ${session.holdMinutes} min — Ctrl-C to tear down`);

  await page.waitForTimeout(HOLD_MS);
});
