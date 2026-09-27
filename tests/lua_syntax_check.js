// A focused Lua 5.1 syntax validator: lexes the source (strings, long strings,
// comments, numbers) and then verifies block structure word-by-word.
//
// It is not a full parser, but it catches the failure modes that actually break
// a Neovim config: unbalanced end/do/then, unterminated strings, stray text.

const fs = require('fs');
const path = require('path');

const OPEN_BLOCKS = new Set(['function', 'do']);
const IF_START = 'if';
const LOOP_START = new Set(['while', 'for']);
const CLOSERS = new Set(['end', 'until']);

// Reserved words may not be used as a bare table key: `{ function = 1 }` is a
// syntax error and must be written `{ ['function'] = 1 }`. This check exists
// because a bare `function = 'x'` slipped past an earlier version of this file
// and was only caught by a real Lua 5.1 parser.
const RESERVED = new Set([
  'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function',
  'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return', 'then',
  'true', 'until', 'while',
]);

function lex(src) {
  const tokens = [];
  const errors = [];
  let i = 0;
  let line = 1;
  const n = src.length;

  const longBracket = (pos) => {
    // At src[pos] === '[', check for [=*[ form. Returns {end, level} or null.
    let j = pos + 1;
    let level = 0;
    while (src[j] === '=') { level++; j++; }
    if (src[j] === '[') return { bodyStart: j + 1, level };
    return null;
  };

  while (i < n) {
    const c = src[i];

    // Newlines
    if (c === '\n') { line++; i++; continue; }
    if (c === '\r') { i++; continue; }

    // Long comments --[[ ... ]] and short comments -- ...
    if (c === '-' && src[i + 1] === '-') {
      const lb = src[i + 2] === '[' ? longBracket(i + 2) : null;
      if (lb) {
        const close = ']' + '='.repeat(lb.level) + ']';
        const end = src.indexOf(close, lb.bodyStart);
        if (end < 0) { errors.push(`line ${line}: unterminated long comment`); break; }
        for (let k = i; k < end + close.length; k++) if (src[k] === '\n') line++;
        i = end + close.length;
        continue;
      }
      // short comment to end of line
      while (i < n && src[i] !== '\n') i++;
      continue;
    }

    // Long strings
    if (c === '[') {
      const lb = longBracket(i);
      if (lb) {
        const close = ']' + '='.repeat(lb.level) + ']';
        const end = src.indexOf(close, lb.bodyStart);
        if (end < 0) { errors.push(`line ${line}: unterminated long string`); break; }
        for (let k = i; k < end + close.length; k++) if (src[k] === '\n') line++;
        i = end + close.length;
        tokens.push({ type: 'string', line });
        continue;
      }
    }

    // Quoted strings
    if (c === '"' || c === "'") {
      const startLine = line;
      const quote = c;
      i++;
      let closed = false;
      while (i < n) {
        const ch = src[i];
        if (ch === '\\') {
          if (src[i + 1] === '\n') line++;
          i += 2;
          continue;
        }
        if (ch === '\n') { errors.push(`line ${startLine}: unterminated string`); closed = true; break; }
        if (ch === quote) { i++; closed = true; break; }
        i++;
      }
      if (!closed) errors.push(`line ${startLine}: unterminated string at EOF`);
      tokens.push({ type: 'string', line: startLine });
      continue;
    }

    // Identifiers / keywords
    if (/[A-Za-z_]/.test(c)) {
      const start = i;
      while (i < n && /[A-Za-z0-9_]/.test(src[i])) i++;
      const value = src.slice(start, i);
      // `name =` is a table-constructor key, not the keyword statement form:
      // { function = 1 } must not be read as opening a function block.
      let j = i;
      while (j < n && (src[j] === ' ' || src[j] === '\t')) j++;
      const isTableKey = src[j] === '=' && src[j + 1] !== '=';
      tokens.push({ type: 'name', value, line, isTableKey });
      continue;
    }

    // Numbers (skip; only need to consume them so digits never look like names)
    if (/[0-9]/.test(c)) {
      while (i < n && /[0-9a-fA-FxXeE\.\+_]/.test(src[i])) {
        // Do not swallow a following `..` concatenation operator.
        if (src[i] === '.' && src[i + 1] === '.') break;
        i++;
      }
      tokens.push({ type: 'number', line });
      continue;
    }

    // Operators / punctuation we care about
    if ('(){}[]=,;.'.includes(c) || '+-*/%^#<>~:'.includes(c)) {
      tokens.push({ type: 'punct', value: c, line });
      i++;
      continue;
    }

    // Anything else (whitespace, etc.)
    i++;
  }

  return { tokens, errors };
}

function validate(src, file) {
  const { tokens, errors } = lex(src);
  const problems = [...errors];

  // Block stack. Each entry: { kind, line }
  const stack = [];
  let expectBlock = null; // set when a construct needs a following `do`

  for (const tok of tokens) {
    if (tok.type !== 'name') continue;
    if (tok.isTableKey) {
      // `name =` is a table key. That is legal for identifiers but a syntax
      // error for reserved words, which need the ['name'] form.
      if (RESERVED.has(tok.value)) {
        problems.push(`line ${tok.line}: reserved word '${tok.value}' used as a bare table key (write ['${tok.value}'])`);
      }
      continue;
    }
    const w = tok.value;

    if (w === 'function') {
      stack.push({ kind: 'function', line: tok.line });
      expectBlock = null;
      continue;
    }
    if (w === 'if') {
      stack.push({ kind: 'if', line: tok.line });
      expectBlock = null;
      continue;
    }
    if (w === 'then') {
      // `then` closes the condition of the nearest if on top (or an elseif).
      const top = stack[stack.length - 1];
      if (!top || (top.kind !== 'if' && top.kind !== 'elseif')) {
        problems.push(`line ${tok.line}: 'then' without a matching if`);
      }
      continue;
    }
    if (w === 'elseif') {
      // A chain of elseif clauses keeps rewriting the same frame, so the top may
      // already read 'elseif' or 'else' from a previous clause.
      const top = stack[stack.length - 1];
      if (!top || (top.kind !== 'if' && top.kind !== 'elseif')) {
        problems.push(`line ${tok.line}: 'elseif' without a matching if`);
      } else {
        top.kind = 'elseif';
      }
      continue;
    }
    if (w === 'else') {
      const top = stack[stack.length - 1];
      if (!top || (top.kind !== 'if' && top.kind !== 'elseif')) {
        problems.push(`line ${tok.line}: 'else' without a matching if`);
      } else {
        top.kind = 'else';
      }
      continue;
    }
    if (LOOP_START.has(w)) {
      // `while`/`for` need a `do`; remember and confirm it appears.
      stack.push({ kind: w, line: tok.line, sawDo: false });
      continue;
    }
    if (w === 'do') {
      // A bare `do` opens a block; a `do` after while/for completes that header.
      const top = stack[stack.length - 1];
      if (top && (top.kind === 'while' || top.kind === 'for') && !top.sawDo) {
        top.sawDo = true;
      } else {
        stack.push({ kind: 'do', line: tok.line });
      }
      continue;
    }
    if (w === 'repeat') {
      stack.push({ kind: 'repeat', line: tok.line });
      continue;
    }
    if (w === 'until') {
      const top = stack[stack.length - 1];
      if (!top || top.kind !== 'repeat') {
        problems.push(`line ${tok.line}: 'until' without a matching repeat`);
      } else {
        stack.pop();
      }
      continue;
    }
    if (w === 'end') {
      const top = stack[stack.length - 1];
      if (!top) {
        problems.push(`line ${tok.line}: 'end' with nothing open`);
        continue;
      }
      if ((top.kind === 'while' || top.kind === 'for') && !top.sawDo) {
        problems.push(`line ${top.line}: '${top.kind}' missing its 'do'`);
      }
      stack.pop();
      continue;
    }
  }

  for (const open of stack) {
    problems.push(`line ${open.line}: '${open.kind}' is never closed`);
  }

  return { problems, tokens: tokens.length };
}

// ---------------------------------------------------------------------------

const root = process.argv[2];
if (!root) {
  console.error('usage: node lua_syntax_check.js <dir>');
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
let bad = 0;
let totalTokens = 0;
for (const file of files) {
  const src = fs.readFileSync(file, 'utf8');
  const { problems, tokens } = validate(src, file);
  totalTokens += tokens;
  const rel = path.relative(root, file);
  if (problems.length === 0) {
    console.log(`OK    ${rel}  (${tokens} tokens, ${src.split('\n').length} lines)`);
  } else {
    bad++;
    console.log(`FAIL  ${rel}`);
    for (const p of problems.slice(0, 12)) console.log(`        ${p}`);
    if (problems.length > 12) console.log(`        … ${problems.length - 12} more`);
  }
}
console.log('');
console.log(`${files.length} files, ${totalTokens} tokens, ${bad} with problems`);
process.exit(bad === 0 ? 0 : 1);
