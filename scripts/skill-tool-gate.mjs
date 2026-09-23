import { existsSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, relative, resolve, sep } from 'node:path';
import { randomUUID } from 'node:crypto';

const approvalDirectory = process.env.AGENT_WORKSPACE_APPROVAL_DIR;
const skillDirectory = process.env.AGENT_WORKSPACE_SKILL_DIR;
delete process.env.AGENT_WORKSPACE_APPROVAL_DIR;
delete process.env.AGENT_WORKSPACE_SKILL_DIR;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

export default function (pi) {
  pi.on('tool_call', async (event, ctx) => {
    if (isSkillReferenceRead(event)) return;
    if (!approvalDirectory) return { block: true, reason: 'アプリの操作確認を利用できません' };
    const id = randomUUID();
    const requestPath = join(approvalDirectory, `request-${id}.json`);
    const responsePath = join(approvalDirectory, `response-${id}.json`);
    writeFileSync(requestPath, JSON.stringify({ id, toolName: event.toolName, arguments: event.input }), { mode: 0o600 });
    const deadline = Date.now() + 120_000;
    while (!ctx.signal?.aborted && Date.now() < deadline) {
      if (existsSync(responsePath)) {
        try {
          const response = JSON.parse(readFileSync(responsePath, 'utf8'));
          if (response.approved === true) return;
        } catch { /* An invalid response is a denial. */ }
        return { block: true, reason: '利用者が操作を許可しませんでした' };
      }
      await wait(100);
    }
    return { block: true, reason: '操作確認が中断または時間切れになりました' };
  });
}
