// dsh-crypto-polyfill.cjs
// =============================================================================
// 修复：crypto.randomUUID is not a function
// -----------------------------------------------------------------------------
// 现象：DeepSeek Harness Web 设置页报
//   "加载提供方目录失败: crypto.randomUUID is not a function"
//   "无法加载 Agent 预设" / "crypto.randomUUID is not a function"
//
// 根因：服务端 Node 进程内，某些依赖（如 @hono/node-server、各 LLM/MCP SDK）会在
//   运行期访问 globalThis.crypto 或 import { webcrypto as crypto }，并在特定条件下
//   把它替换 / 引用成一个【缺少 randomUUID】的 crypto 对象（Node 24 自带的默认
//   globalThis.crypto 本应带有 randomUUID，但被上述替换覆盖后即消失）。
//   于是任何调用 crypto.randomUUID() 的代码抛 "crypto.randomUUID is not a function"。
//
// 修复策略（与具体调用方解耦，根治而非打补丁）：
//   1) 把 globalThis.crypto 定义为【访问器】：读取时始终返回一个已补齐 randomUUID
//      的真实 crypto 对象；任何外部对该属性的【赋值/替换】都被 setter 忽略，
//      从而保证全局 crypto 永远可用。
//   2) 同时补齐 node:crypto.webcrypto.randomUUID（防御
//      import { webcrypto as crypto } 后调用 crypto.randomUUID() 的依赖）。
// =============================================================================
"use strict";
const nodeCrypto = require("node:crypto");

// 给任意 crypto 对象补齐 randomUUID（若缺失），返回原对象
function ensureRandomUUID(obj) {
  if (!obj || typeof obj.randomUUID === "function") return obj;
  try {
    Object.defineProperty(obj, "randomUUID", {
      value: nodeCrypto.randomUUID,
      configurable: true,
      writable: true,
    });
  } catch (_) {
    try { obj.randomUUID = nodeCrypto.randomUUID; } catch (_) {}
  }
  return obj;
}

// 选基准对象：优先用当前 globalThis.crypto（已是真实 crypto），否则退回 webcrypto
const base =
  globalThis.crypto && typeof globalThis.crypto === "object"
    ? globalThis.crypto
    : nodeCrypto.webcrypto;
const patched = ensureRandomUUID(base);

try {
  Object.defineProperty(globalThis, "crypto", {
    configurable: true,
    enumerable: true,
    // 读取时永远返回已补齐 randomUUID 的真实 crypto
    get() { return patched; },
    // 忽略任何外部替换（@hono/node-server 等），始终保证可用
    set() {},
  });
  console.log("[dsh-polyfill] globalThis.crypto 已设为始终带 randomUUID 的访问器（修复 crypto.randomUUID is not a function）。");
} catch (_) {
  // 极少数环境不允许重定义，则退化为直接赋值
  globalThis.crypto = patched;
  console.log("[dsh-polyfill] 已直接补齐 globalThis.crypto.randomUUID。");
}

// 防御 import { webcrypto as crypto } 后调用 crypto.randomUUID()
ensureRandomUUID(nodeCrypto.webcrypto);
