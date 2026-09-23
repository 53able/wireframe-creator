#!/usr/bin/env node
import { readFile, writeFile, mkdtemp, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { createServer } from "vite";
import marko from "@marko/vite";
import { analyzeOperations } from "./analyze-operations.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const [sourceArg, outputArg] = process.argv.slice(2);
if (!sourceArg || !outputArg) {
  console.error("Usage: node builder/build-wireframe.mjs INPUT.json OUTPUT.html");
  process.exit(2);
}

function fail(message) {
  console.error(`画面仕様を生成できません: ${message}`);
  process.exit(2);
}
function fieldInputType(value, label, fieldLabel) {
  if (value == null || value === "" || (typeof value === "string" && !value.trim())) {
    return /本文|内容|メモ|説明|コメント|diary|body|description|message/i.test(fieldLabel) ? "textarea" : "text";
  }
  if (typeof value !== "string") fail(`${label}は文字列で指定してください`);
  const type = value.trim().toLowerCase();
  if (["textarea", "multiline", "multi-line", "long-text"].includes(type)) return "textarea";
  if (["text", "email", "number", "search", "date", "time", "datetime-local", "tel", "url"].includes(type)) return type;
  fail(`${label}「${value}」は未対応です。text、textarea、email、number、search、date、time、datetime-local、tel、urlから選んでください`);
}
function palette(value) {
  const name = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (name === "gray" || name === "grey") return "slate";
  if (["slate", "indigo", "teal"].includes(name)) return name;
  fail(`配色「${value ?? "未指定"}」は未対応です。slate、indigo、tealから選んでください`);
}
function string(value, label) {
  if (typeof value !== "string" || !value.trim()) fail(`${label} must be a non-empty string`);
}
function strings(value, label) {
  if (!Array.isArray(value)) fail(`${label} must be an array`);
  value.forEach((item, index) => string(item, `${label}[${index}]`));
}
function validate(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) fail("root must be an object");
  string(input.title, "title");
  string(input.status, "status");
  input.palette = palette(input.palette);
  if (!input.brief || typeof input.brief !== "object") fail("brief must be an object");
  for (const key of ["targetUser", "problem", "userOutcome", "businessOutcome", "solutionBoundary", "hypothesis", "riskiestAssumption", "learningGoal"]) string(input.brief[key], `brief.${key}`);
  for (const key of ["decisions", "assumptions", "openQuestions"]) strings(input[key], key);
  if (!Array.isArray(input.screens) || input.screens.length < 1) fail("screens must contain at least one screen");
  const ids = new Set();
  const fieldKeys = new Set();
  const selectKeys = new Set();
  const valueKeys = new Set();
  input.screens.forEach((screen, index) => {
    const label = `screens[${index}]`;
    if (!screen || typeof screen !== "object") fail(`${label} must be an object`);
    string(screen.id, `${label}.id`);
    if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(screen.id)) fail(`${label}.id must be kebab-case`);
    if (ids.has(screen.id)) fail(`duplicate screen id: ${screen.id}`);
    ids.add(screen.id);
    for (const key of ["name", "purpose", "testNote"]) string(screen[key], `${label}.${key}`);
    if (!Array.isArray(screen.blocks)) fail(`${label}.blocks must be an array`);
    screen.blocks.forEach((block, blockIndex) => {
      const blockLabel = `${label}.blocks[${blockIndex}]`;
      if (!block || typeof block !== "object") fail(`${blockLabel} must be an object`);
      if (block.id !== undefined) string(block.id, `${blockLabel}.id`);
      if (block.type === "paragraph") string(block.text, `${blockLabel}.text`);
      else if (block.type === "panel") { string(block.title, `${blockLabel}.title`); string(block.text, `${blockLabel}.text`); }
      else if (block.type === "field") {
        string(block.label, `${blockLabel}.label`);
        string(block.key, `${blockLabel}.key`);
        if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(block.key)) fail(`${blockLabel}.key must be kebab-case`);
        if (fieldKeys.has(block.key)) fail(`duplicate field key: ${block.key}`);
        fieldKeys.add(block.key);
        block.inputType = fieldInputType(block.inputType, `「${screen.name}」の「${block.label}」の入力形式`, block.label);
        if (block.placeholder !== undefined && typeof block.placeholder !== "string") fail(`${blockLabel}.placeholder must be a string`);
      } else if (block.type === "select") {
        string(block.key, `${blockLabel}.key`);
        string(block.label, `${blockLabel}.label`);
        if (!/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(block.key)) fail(`${blockLabel}.key must be kebab-case`);
        if (fieldKeys.has(block.key)) fail(`duplicate field key: ${block.key}`);
        fieldKeys.add(block.key);
        selectKeys.add(block.key);
        strings(block.options, `${blockLabel}.options`);
        if (block.options.length < 2) fail(`${blockLabel}.options needs at least two choices`);
      } else if (block.type === "value") {
        string(block.key, `${blockLabel}.key`);
        string(block.label, `${blockLabel}.label`);
        string(block.emptyText, `${blockLabel}.emptyText`);
        valueKeys.add(block.key);
      } else if (block.type === "list") strings(block.items, `${blockLabel}.items`);
      else fail(`${blockLabel}.type is unsupported`);
    });
    if (!Array.isArray(screen.actions)) fail(`${label}.actions must be an array`);
    screen.actions.forEach((action, actionIndex) => {
      const actionLabel = `${label}.actions[${actionIndex}]`;
      if (action.id !== undefined) string(action.id, `${actionLabel}.id`);
      string(action.label, `${actionLabel}.label`);
      string(action.target, `${actionLabel}.target`);
      if (!["primary", "secondary"].includes(action.variant)) fail(`${actionLabel}.variant must be primary or secondary`);
    });
  });
  input.screens.forEach((screen) => screen.actions.forEach((action) => {
    if (!ids.has(action.target)) fail(`unknown action target: ${action.target}`);
  }));
  for (const key of valueKeys) if (!fieldKeys.has(key)) fail(`value block references unknown field key: ${key}`);
  for (const key of selectKeys) if (!valueKeys.has(key)) fail(`select block needs a matching value block: ${key}`);
}

function run(command, args) {
  return new Promise((done, reject) => {
    const child = spawn(command, args, { cwd: root, stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? done() : reject(new Error(`${command} exited with ${code}`)));
  });
}

const inputPath = resolve(sourceArg);
const outputPath = resolve(outputArg);
let input;
let sourceText;
try { sourceText = await readFile(inputPath, "utf8"); input = JSON.parse(sourceText); }
catch { fail("JSONの形式を読み取れません。チャットで仕様案を作り直してください"); }
validate(input);
let operationReport;
try { operationReport = analyzeOperations(input, sourceText); }
catch (error) { fail(error instanceof Error ? error.message.replace(/^Invalid operation data: /, "") : String(error)); }
input.operationReport = operationReport;
input.operationReportJson = JSON.stringify(operationReport).replace(/</g, "\\u003c");
const temporary = await mkdtemp(join(tmpdir(), "wireframe-marko-"));
try {
  const cssPath = join(temporary, "wireframe.css");
  await run(join(root, "node_modules", ".bin", "tailwindcss"), ["-i", join(root, "builder", "wireframe.css"), "-o", cssPath, "--minify"]);
  const css = await readFile(cssPath, "utf8");
  const license = (await readFile(join(root, "assets", "tailwind.LICENSE.md"), "utf8")).trim();
  if (license.includes("*/")) throw new Error("Tailwind license cannot be embedded in a CSS comment");
  const inlineCss = `/*!\n${license}\n*/\n${css}`;
  const vite = await createServer({
    root,
    cacheDir: join(temporary, "vite-cache"),
    optimizeDeps: { noDiscovery: true, include: [] },
    plugins: [marko()],
    server: { middlewareMode: true },
    appType: "custom",
    logLevel: "error"
  });
  let markup;
  try {
    const template = (await vite.ssrLoadModule("./builder/wireframe.marko?marko-server-entry")).default;
    markup = await template.render(input);
  } finally { await vite.close(); }
  if (markup.split("__INLINE_CSS__").length !== 2) throw new Error("Marko template must contain exactly one CSS insertion point");
  const runtime = await readFile(join(root, "builder", "wireframe-runtime.js"), "utf8");
  if (runtime.includes("</script")) throw new Error("Runtime cannot contain a closing script tag");
  const html = `<!doctype html>\n${markup.replace("__INLINE_CSS__", inlineCss).replace("</body>", `<script data-wireframe-runtime>\n${runtime}\n</script>\n</body>`)}\n`;
  await mkdir(dirname(outputPath), { recursive: true });
  await writeFile(outputPath, html, { encoding: "utf8", flag: "wx" });
  console.log(`Wrote ${outputPath}`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}
