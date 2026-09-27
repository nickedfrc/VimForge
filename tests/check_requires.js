// Verifies that every `require('dshstudio.*')` in the project resolves to a real
// file, and reports modules that are never required (dead code candidates).
//
// This is the integration check that catches a typo'd module path before Neovim
// ever loads the config.

const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) {
  console.error('usage: node check_requires.js <config-root>');
  process.exit(2);
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.git' || entry.name === 'node_modules') continue;
      walk(full, out);
    } else if (entry.name.endsWith('.lua')) {
      out.push(full);
    }
  }
  return out;
}

const files = walk(root).sort();

// Map module name -> file path, using Lua package.path semantics.
const modules = new Map();
for (const file of files) {
  const rel = path.relative(root, file).replace(/\\/g, '/');
  const m = /^(?:lua\/)?(.+)\.lua$/.exec(rel);
  if (!m) continue;
  let name = m[1].replace(/\//g, '.');
  if (name.endsWith('.init')) name = name.slice(0, -'.init'.length);
  modules.set(name, file);
}

// Modules that legitimately may not exist, or that are loaded by name rather
// than by `require`, so the checker must not treat them as broken.
const OPTIONAL_MODULES = new Set([
  'dshstudio.user',          // personal overrides: created by copying user.example.lua
]);

const TEMPLATE_MODULES = new Set([
  'dshstudio.user.example',  // a template, never loaded
]);

// init.lua loads first-party modules through local helpers instead of `require`.
const INDIRECT_LOADERS = [
  /load_module\(\s*['"]([%w_\.\-]+)['"]/g,
  /setup\(\s*['"]([%w_\.\-]+)['"]/g,
];

const requires = new Map(); // module -> [referencing files]
const unresolved = [];

for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const lines = src.split('\n');
  lines.forEach((line, index) => {
    // Locate requires without relying on escaped parentheses in a regex, which
    // is fragile across shells and editors. Both `require('x')` and the
    // defensive `pcall(require, 'x')` form are handled: find `require`, then the
    // first quoted string after it.
    let from = 0;
    for (;;) {
      const at = line.indexOf('require', from);
      if (at < 0) break;
      from = at + 'require'.length;
      // The character right after `require` must be `(` or `,`, otherwise this
      // is a different identifier such as `required`.
      let cursor = from;
      while (cursor < line.length && (line[cursor] === ' ' || line[cursor] === '\t')) cursor++;
      const sep = line[cursor];
      if (sep !== '(' && sep !== ',') continue;

      const quoteAt = (() => {
        for (let i = cursor; i < line.length; i++) {
          if (line[i] === "'" || line[i] === '"') return i;
          // Stop if we clearly left the call.
          if (line[i] === ')') return -1;
        }
        return -1;
      })();
      if (quoteAt < 0) continue;
      const quote = line[quoteAt];
      const end = line.indexOf(quote, quoteAt + 1);
      if (end < 0) continue;
      const name = line.slice(quoteAt + 1, end);
      if (!name.startsWith('dshstudio')) continue;
      if (!requires.has(name)) requires.set(name, []);
      requires.get(name).push(`${path.relative(root, file)}:${index + 1}`);
      if (!modules.has(name) && !OPTIONAL_MODULES.has(name) && !TEMPLATE_MODULES.has(name)) {
        unresolved.push(`${path.relative(root, file)}:${index + 1}  -> ${name}`);
      }
    }

    // Indirect loads: load_module('x') / setup('x', 'setup') in init.lua.
    for (const pattern of INDIRECT_LOADERS) {
      pattern.lastIndex = 0;
      let match;
      while ((match = pattern.exec(line)) !== null) {
        const name = match[1];
        if (!name.startsWith('dshstudio')) continue;
        if (!requires.has(name)) requires.set(name, []);
        requires.get(name).push(`${path.relative(root, file)}:${index + 1}`);
        if (!modules.has(name)) {
          unresolved.push(`${path.relative(root, file)}:${index + 1}  -> ${name} (indirect)`);
        }
      }
    }
  });
}

console.log(`Lua files:            ${files.length}`);
console.log(`First-party modules:  ${modules.size}`);
console.log(`Distinct requires:    ${requires.size}`);
console.log('');

let bad = 0;
if (unresolved.length > 0) {
  bad = 1;
  console.log('UNRESOLVED REQUIRES:');
  for (const line of unresolved) console.log('  ' + line);
} else {
  console.log('All first-party requires resolve.');
}

// Report modules nothing loads and that are not entries/tests/templates.
const neverUsed = [];
for (const [name, file] of modules) {
  const rel = path.relative(root, file).replace(/\\/g, '/');
  const isEntry = rel === 'init.lua' || rel.startsWith('plugin/');
  if (isEntry) continue;
  if (OPTIONAL_MODULES.has(name) || TEMPLATE_MODULES.has(name)) continue;
  if (!requires.has(name)) neverUsed.push(name);
}
if (neverUsed.length > 0) {
  console.log('');
  console.log('Not required anywhere (check these are loaded some other way):');
  for (const name of neverUsed.sort()) console.log('  ' + name);
}

// Every module should declare it exists in a way that survives a missing file.
console.log('');
console.log(bad === 0 ? 'RESULT: OK' : 'RESULT: PROBLEMS FOUND');
process.exit(bad);
