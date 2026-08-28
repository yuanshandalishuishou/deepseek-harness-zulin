/**
 * tfg-capture.ts —— 非交互式「一键捕获」脚本（由管理端口 16688 的按钮触发）。
 *
 * 行为：
 *   遍历全部 13 家 provider，对【当前 RDP 桌面浏览器中已登录】的账号调用网关官方的
 *   loginFn 捕获凭证，并写入 /root/.token-free-gateway/auth-profiles.json
 *   （即 dsh-tfg-auth 数据卷）。网关每次请求都会重读该文件，无需重启。
 *
 * 关于「未登录」provider 的 5 分钟等待陷阱：
 *   loginFn 在检测到无会话时会导航到登录页并阻塞等待用户登录（最长 5 分钟）。
 *   这里用 types.ts 的 withTimeout 将单次尝试限为 15s，超时即视为「未登录」跳过，
 *   从而整批捕获不会卡死。已登录的 provider 通常 1~3s 内即可完成。
 *
 * 用法：/root/.bun/bin/bun /opt/token-free-gateway/src/cli/tfg-capture.ts
 */
import { listProviderDefinitions } from "../providers/registry.ts";
import { saveCredentials } from "../providers/auth-store.ts";
import { withTimeout } from "../providers/types.ts";

const PER_PROVIDER_MS = 15000;

async function main() {
  const defs = await listProviderDefinitions();
  const summary: Record<string, string> = {};
  console.log(`开始捕获，共 ${defs.length} 家 provider（仅捕获浏览器中已登录的账号）\n`);

  for (const def of defs) {
    console.log(`━━━ ${def.name} (${def.id}) ━━━`);
    try {
      const creds = await withTimeout(
        def.loginFn({
          onProgress: (m) => console.log(`  > ${m}`),
          openUrl: async () => true,
        }),
        PER_PROVIDER_MS,
        def.name,
      );
      if (creds && typeof creds === "object") {
        saveCredentials(def.id, creds);
        summary[def.id] = "ok";
        console.log(`  ✓ ${def.name} 已捕获并保存`);
      } else {
        summary[def.id] = "no-session";
        console.log(`  · ${def.name} 未检测到已登录会话，跳过`);
      }
    } catch (e) {
      summary[def.id] = "skipped";
      console.log(`  · ${def.name} 未登录或超时，跳过 (${(e as Error)?.message ?? e})`);
    }
  }

  const ok = Object.values(summary).filter((v) => v === "ok").length;
  console.log(`\n=== 捕获完成：${ok}/${defs.length} 家成功 ===`);
  console.log("SUMMARY_JSON:" + JSON.stringify(summary));
  // 给 stdout 一点刷新时间再强制退出（避免未登录 provider 残留的 5 分钟定时器挂起进程）
  setTimeout(() => process.exit(0), 300);
}

main().catch((e) => {
  console.error("捕获脚本异常:", e);
  process.exit(1);
});
