import { mkdir, readFile, writeFile } from 'node:fs/promises';

const source = await readFile(new URL('../interact.html', import.meta.url), 'utf8');
const styleMatch = source.match(/<style>([\s\S]*?)<\/style>/);
const scriptMatch = source.match(/<script>([\s\S]*?)<\/script>/);

if (!styleMatch || !scriptMatch) {
  throw new Error('原始原型缺少 style 或 script 标签');
}

const html = source
  .replace(/<style>[\s\S]*?<\/style>/, '<link rel="stylesheet" href="/src/styles.css">')
  .replace(/<script>[\s\S]*?<\/script>/, '<script src="/src/api.js"></script><script src="/src/main.js"></script>');

await mkdir(new URL('../src/', import.meta.url), { recursive: true });
await Promise.all([
  writeFile(new URL('../index.html', import.meta.url), `${html}\n`),
  writeFile(new URL('../src/styles.css', import.meta.url), `${styleMatch[1].trim()}\n`),
  writeFile(new URL('../src/main.js', import.meta.url), `${scriptMatch[1].trim()}\n`)
]);

console.log('原型已拆分为 index.html、src/styles.css 和 src/main.js');
