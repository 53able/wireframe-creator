import { loadSkills } from '@earendil-works/pi-coding-agent';
import { homedir } from 'node:os';
import { join } from 'node:path';

const root = join(homedir(), '.agents', 'skills');
const result = loadSkills({ cwd: process.cwd(), skillPaths: [root], includeDefaults: false });
process.stdout.write(JSON.stringify(result.skills.map(({ name, description, filePath }) => ({ name, description, filePath }))));
