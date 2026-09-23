import { ModelRuntime } from '@earendil-works/pi-coding-agent';
import readline from 'node:readline';

const providerIds = ['openai-codex', 'anthropic'];
const emit = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

async function catalog(runtime) {
  return Promise.all(providerIds.map(async (id) => {
    const provider = runtime.getProvider(id);
    const auth = await runtime.checkAuth(id);
    return {
      id,
      name: provider?.name ?? id,
      connected: Boolean(auth),
      models: (auth ? await runtime.getAvailable(id) : []).map((model) => ({
        id: model.id,
        name: model.name,
        supportsImages: model.input?.includes('image') ?? false,
      })),
    };
  }));
}

async function login(runtime, providerId) {
  if (!providerIds.includes(providerId)) throw new Error('Unsupported provider');
  const input = readline.createInterface({ input: process.stdin });
  const waiting = new Map();
  input.on('line', (line) => {
    try {
      const reply = JSON.parse(line);
      const resolve = waiting.get(reply.id);
      if (resolve && typeof reply.value === 'string') {
        waiting.delete(reply.id);
        resolve(reply.value);
      }
    } catch { /* Ignore malformed UI replies. */ }
  });
  let nextId = 0;
  try {
    await runtime.login(providerId, 'oauth', {
      notify(event) {
        emit({ kind: 'event', event });
      },
      prompt(prompt) {
        const id = String(++nextId);
        emit({
          kind: 'prompt', id, prompt: {
            type: prompt.type,
            message: prompt.message,
            placeholder: prompt.placeholder,
            options: prompt.type === 'select' ? prompt.options : undefined,
          },
        });
        return new Promise((resolve, reject) => {
          waiting.set(id, resolve);
          prompt.signal?.addEventListener('abort', () => {
            if (waiting.delete(id)) reject(new Error('Prompt cancelled'));
          }, { once: true });
        });
      },
    });
    emit({ kind: 'complete', providers: await catalog(runtime) });
  } finally {
    input.close();
  }
}

async function logout(runtime, providerId) {
  if (!providerIds.includes(providerId)) throw new Error('Unsupported provider');
  await runtime.logout(providerId);
  emit({ kind: 'complete', providers: await catalog(runtime) });
}

try {
  const runtime = await ModelRuntime.create({ allowModelNetwork: false });
  const [command, providerId] = process.argv.slice(2);
  if (command === 'catalog') {
    emit({ kind: 'complete', providers: await catalog(runtime) });
  } else if (command === 'login') {
    await login(runtime, providerId);
  } else if (command === 'logout') {
    await logout(runtime, providerId);
  } else {
    throw new Error('Unsupported command');
  }
} catch (error) {
  emit({ kind: 'error', message: error instanceof Error ? error.message : String(error) });
  process.exitCode = 1;
}
