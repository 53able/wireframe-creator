import { realpathSync } from 'node:fs';
import { isAbsolute, relative, resolve, sep } from 'node:path';

const skillDirectory = process.env.AGENT_WORKSPACE_SKILL_DIR;
delete process.env.AGENT_WORKSPACE_SKILL_DIR;

function isSkillReferenceRead(event) {
  if (event.toolName !== 'read' || typeof event.input?.path !== 'string' || !skillDirectory) return false;
  try {
    const root = realpathSync(skillDirectory);
    const target = realpathSync(resolve(process.cwd(), event.input.path));
    const pathFromRoot = relative(root, target);
    return pathFromRoot === '' || (pathFromRoot !== '..' && !pathFromRoot.startsWith(`..${sep}`) && !isAbsolute(pathFromRoot));
  } catch {
    return false;
  }
}

function describeArguments(input) {
  try {
    const text = JSON.stringify(input ?? {}, null, 2);
    return text.length > 2000 ? `${text.slice(0, 2000)}\n…（省略）` : text;
  } catch {
    return '（引数を表示できませんでした）';
  }
}

export default function (pi) {
  pi.on('tool_call', async (event, ctx) => {
    if (isSkillReferenceRead(event)) return;
    // RPCモードでは confirm は親プロセスのstdin/stdoutパイプ上で往復する。
    // 同一ユーザーで動く子プロセスからは触れないため、承認の偽装ができない。
    if (!ctx.hasUI) return { block: true, reason: 'アプリの操作確認を利用できません' };
    const confirmed = await ctx.ui.confirm(event.toolName, describeArguments(event.input), { timeout: 120_000 });
    if (confirmed === true) return;
    return { block: true, reason: '利用者が操作を許可しませんでした' };
  });
}
