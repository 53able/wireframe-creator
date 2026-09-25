#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

const OPERATION_KINDS = new Set([
  "navigate",
  "reflect-value",
  "static-display",
  "save",
  "content-switch"
]);

const fail = (message) => { throw new Error(`Invalid operation data: ${message}`); };
const nonEmpty = (value) => typeof value === "string" && value.trim().length > 0;

function indexScreen(screen, screenIndex) {
  const blocks = [];
  for (const [index, block] of (screen.blocks || []).entries()) {
    const ref = block.id || block.key || `${screen.id}-block-${index + 1}`;
    blocks.push({ ...block, ref, index });
  }
  const actions = [];
  for (const [index, action] of (screen.actions || []).entries()) {
    const ref = action.id || `${screen.id}-action-${index + 1}`;
    actions.push({ ...action, ref, index });
  }
  return { ...screen, screenIndex, blocks, actions };
}

function findRef(indexed, ref) {
  if (!nonEmpty(ref)) return undefined;
  return indexed.blocks.find((block) => block.ref === ref || block.key === ref)
    || indexed.actions.find((action) => action.ref === ref)
    || (indexed.id === ref ? indexed : undefined);
}

// navigate / save のtriggerRefはscreen.actionsからのみ解決する。
// screen.blocksを対象に含めると、targetプロパティを持つ任意のblock
// （paragraph/panel/list等）が誤って遷移トリガーとして成立してしまう。
function findActionRef(indexed, ref) {
  if (!nonEmpty(ref)) return undefined;
  return indexed.actions.find((action) => action.ref === ref);
}

function analyzeOperations(input, sourceText = JSON.stringify(input)) {
  if (!input || typeof input !== "object" || !Array.isArray(input.screens)) {
    fail("screens must be an array");
  }
  const screens = input.screens.map(indexScreen);
  const byId = new Map(screens.map((screen) => [screen.id, screen]));
  const allBlocks = screens.flatMap((screen) => screen.blocks.map((block) => ({ ...block, screenId: screen.id })));
  const operations = [];
  const operationIds = new Set();
  const declaredClaims = new Set();
  const claimedActions = new Set();
  let declaredCount = 0;

  const add = (operation) => {
    if (operationIds.has(operation.id)) fail(`duplicate operation id: ${operation.id}`);
    operationIds.add(operation.id);
    operations.push(operation);
  };
  const claim = (screenId, triggerRef, targetRef = "") => `${screenId}|${triggerRef || ""}|${targetRef || ""}`;

  // Explicit declarations take precedence over inferred legacy behavior.
  for (const screen of screens) {
    if (screen.operations === undefined) continue;
    if (!Array.isArray(screen.operations)) fail(`screens[${screen.screenIndex}].operations must be an array`);
    declaredCount += screen.operations.length;
    for (const [index, operation] of screen.operations.entries()) {
      const label = `screens[${screen.screenIndex}].operations[${index}]`;
      if (!operation || typeof operation !== "object") fail(`${label} must be an object`);
      if (!nonEmpty(operation.id)) fail(`${label}.id must be a non-empty string`);
      if (!nonEmpty(operation.label)) fail(`${label}.label must be a non-empty string`);
      if (!nonEmpty(operation.kind)) fail(`${label}.kind must be a non-empty string`);
      if (operation.triggerRef !== undefined && !nonEmpty(operation.triggerRef)) fail(`${label}.triggerRef must be a non-empty string`);
      if (operation.targetRef !== undefined && !nonEmpty(operation.targetRef)) fail(`${label}.targetRef must be a non-empty string`);
      if (operation.expectedResult !== undefined && !nonEmpty(operation.expectedResult)) fail(`${label}.expectedResult must be a non-empty string`);

      const trigger = (operation.kind === "navigate" || operation.kind === "save")
        ? findActionRef(screen, operation.triggerRef)
        : findRef(screen, operation.triggerRef);
      const target = operation.targetRef
        ? (operation.kind === "reflect-value"
          ? allBlocks.find((block) => block.type === "value" && (block.ref === operation.targetRef || block.key === operation.targetRef))
          : (findRef(screen, operation.targetRef) || allBlocks.find((block) => block.ref === operation.targetRef || block.key === operation.targetRef)))
        : undefined;
      let status = "unsupported";
      let reason = "参照先が見つからないため、プレビューでは確認できません。";
      if (!OPERATION_KINDS.has(operation.kind)) {
        reason = "操作種別が未対応のため、プレビューでは確認できません。";
      } else if (operation.kind === "navigate") {
        if (trigger?.target && byId.has(trigger.target)) {
          status = "navigation-only";
          reason = "画面遷移として確認できます。遷移先の内容変更は含みません。";
        }
      } else if (operation.kind === "reflect-value") {
        if ((trigger?.type === "field" || trigger?.type === "select") && target?.type === "value" && trigger.key === target.key) {
          status = "working";
          reason = "入力値を同じキーの表示へ反映します。";
        }
      } else if (operation.kind === "static-display") {
        if (target?.type === "panel" || target?.type === "paragraph" || target?.type === "list") {
          status = "display-only";
          reason = "固定された表示として確認できます。";
        }
      } else if (operation.kind === "save") {
        if (trigger?.target && byId.has(trigger.target)) {
          status = "navigation-only";
          reason = "保存操作は遷移として確認できます。保存処理自体は実行しません。";
        }
      } else if (operation.kind === "content-switch") {
        if (trigger?.type === "select" && (target?.type === "panel" || target?.type === "paragraph")) {
          reason = "選択値による本文の切り替えは未対応です。";
        }
      }
      add({ id: operation.id, screenId: screen.id, label: operation.label, expectedResult: operation.expectedResult || null, status, reason });
      if (operation.kind === "navigate" || operation.kind === "save" || operation.kind === "content-switch") {
        declaredClaims.add(claim(screen.id, operation.triggerRef, operation.targetRef));
        if ((operation.kind === "navigate" || operation.kind === "save") && trigger?.target) {
          claimedActions.add(claim(screen.id, trigger.ref));
        }
      } else if (operation.kind === "reflect-value") {
        // 重複判定は仕様の生文字列ではなく、解決済みの正規化キー(block.ref/value.ref = id||key)で行う。
        // triggerを id、targetを key（またはその逆）で書いても同一操作として一致させるため。
        declaredClaims.add(claim(screen.id, trigger?.ref || operation.triggerRef, target?.ref || operation.targetRef));
      }
    }
  }

  for (const screen of screens) {
    for (const [index, action] of screen.actions.entries()) {
      const id = `${screen.id}-${action.ref}`;
      if (claimedActions.has(claim(screen.id, action.ref))) continue;
      add({
        id,
        screenId: screen.id,
        label: action.label,
        status: byId.has(action.target) ? "navigation-only" : "unsupported",
        reason: byId.has(action.target) ? "画面遷移として確認できます。" : "遷移先の画面が見つかりません。"
      });
    }
    for (const block of screen.blocks) {
      if (block.type !== "field" && block.type !== "select") continue;
      const value = allBlocks.find((candidate) => candidate.type === "value" && candidate.key === block.key);
      if (!value) {
        add({ id: `${screen.id}-${block.key}-input`, screenId: screen.id, label: `${block.label}を入力する`, status: "display-only", reason: "入力欄内で選択・入力できます。ほかの表示や保存処理には反映しません。" });
        continue;
      }
      const generatedId = `${screen.id}-${block.key}-reflect`;
      if (declaredClaims.has(claim(screen.id, block.ref, value.ref)) || declaredClaims.has(claim(screen.id, block.key, block.key))) continue;
      add({ id: generatedId, screenId: screen.id, label: `${block.label}の入力を表示に反映する`, status: "working", reason: "入力値を同じキーの表示へ反映します。" });
    }
  }
  return { version: 1, sourceDigest: createHash("sha256").update(sourceText).digest("hex"), declaredCount, operations };
}

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  const inputPath = process.argv[2];
  if (!inputPath) {
    console.error("Usage: node builder/analyze-operations.mjs INPUT.json");
    process.exit(2);
  }
  try {
    const sourceText = await readFile(inputPath, "utf8");
    const input = JSON.parse(sourceText);
    process.stdout.write(`${JSON.stringify(analyzeOperations(input, sourceText))}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(2);
  }
}

export { analyzeOperations };
