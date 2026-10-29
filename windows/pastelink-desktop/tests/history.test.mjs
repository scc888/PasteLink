import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";

// Exercise the production TypeScript without another test framework or runtime dependency.
const source = await readFile(new URL("../src/history.ts", import.meta.url), "utf8");
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.ES2020 },
});
const { mergeHistoryItem, filterHistoryItems, shouldUseHistoryShortcut, trimHistory } =
  await import(`data:text/javascript;base64,${Buffer.from(outputText).toString("base64")}`);

const item = (id, overrides = {}) => ({
  id, sha256: id, content: id, preview: id, source: "windows", timestamp: 0,
  char_count: id.length, item_type: "text", is_pinned: false, ...overrides,
});

test("an incoming repeat keeps the existing pin with the latest content metadata", () => {
  const result = mergeHistoryItem([item("old", { sha256: "same", is_pinned: true })],
    item("new", { sha256: "same", source: "iphone" }));
  assert.equal(result.length, 1);
  assert.equal(result[0].id, "new");
  assert.equal(result[0].source, "iphone");
  assert.equal(result[0].is_pinned, true);
});

test("incoming events retain every pin and the latest thirty unpinned entries", () => {
  let items = Array.from({ length: 55 }, (_, i) => item(`pin-${i}`, { is_pinned: true }));
  for (let i = 0; i < 35; i++) items = mergeHistoryItem(items, item(`recent-${i}`));
  assert.equal(items.filter((i) => i.is_pinned).length, 55);
  assert.equal(items.filter((i) => !i.is_pinned).length, 30);
  assert.equal(items[0].id, "recent-34");
  assert.ok(!items.some((i) => i.id === "recent-0"));
});

test("unpinning an old entry reapplies the ordinary quota without dropping other pins", () => {
  const items = Array.from({ length: 30 }, (_, i) => item(`recent-${i}`));
  items.push(item("still-pinned", { is_pinned: true }), item("old-unpinned"));
  const retained = trimHistory(items);
  assert.equal(retained.length, 31);
  assert.ok(retained.some((i) => i.id === "still-pinned"));
  assert.ok(!retained.some((i) => i.id === "old-unpinned"));
});

test("search ignores surrounding spaces and letter case while preserving pin order", () => {
  const items = [item("first", { content: "HELLO world", timestamp: 10 }),
    item("pin", { content: "hello", is_pinned: true }), item("unrelated")];
  assert.deepEqual(filterHistoryItems(items, "all", "  Hello  ").map((i) => i.id), ["pin", "first"]);
  assert.equal(items[0].id, "first");
});

test("source, image and pinned filters describe only their own empty or populated set", () => {
  const items = [item("phone", { source: "iphone" }), item("image", { item_type: "image" }),
    item("pin", { is_pinned: true })];
  assert.deepEqual(filterHistoryItems(items, "iphone", "").map((i) => i.id), ["phone"]);
  assert.deepEqual(filterHistoryItems(items, "image", "").map((i) => i.id), ["image"]);
  assert.deepEqual(filterHistoryItems(items, "pinned", "").map((i) => i.id), ["pin"]);
  assert.deepEqual(filterHistoryItems(items, "windows", "missing"), []);
});

const key = { isComposing: false, keyCode: 13, ctrlKey: false, altKey: false,
  metaKey: false, shiftKey: false, defaultPrevented: false };

test("confirming an IME candidate never copies history or closes the window", () => {
  assert.equal(shouldUseHistoryShortcut({ ...key, isComposing: true }, false), false);
  assert.equal(shouldUseHistoryShortcut({ ...key, keyCode: 229 }, false), false);
});

test("buttons and modified or consumed keys keep their native behavior", () => {
  assert.equal(shouldUseHistoryShortcut(key, true), false);
  for (const flag of ["ctrlKey", "altKey", "metaKey", "shiftKey", "defaultPrevented"]) {
    assert.equal(shouldUseHistoryShortcut({ ...key, [flag]: true }, false), false, flag);
  }
  assert.equal(shouldUseHistoryShortcut(key, false), true);
});
