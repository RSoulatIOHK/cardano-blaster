'use strict';

function prettyHaskell(value) {
  let result = '';
  let depth = 0;
  const stack = [];
  let quoted = false;
  let escaped = false;
  let skipSpace = false;
  const newline = () => {
    result = result.trimEnd();
    result += `\n${'  '.repeat(depth)}`;
    skipSpace = true;
  };
  for (let i = 0; i < value.length; i += 1) {
    const char = value[i];
    if (skipSpace && char === ' ') continue;
    skipSpace = false;
    if (quoted) {
      result += char;
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') quoted = false;
      continue;
    }
    if (char === '"') { quoted = true; result += char; continue; }
    if ((char === '{' || char === '[') && value[i + 1] !== (char === '{' ? '}' : ']')) {
      stack.push(char);
      result += char;
      depth += 1;
      newline();
    } else if (char === '{' || char === '[') {
      stack.push(char);
      result += char;
    } else if (char === '}' || char === ']') {
      const opening = stack.pop();
      if (opening && result.trimEnd().at(-1) !== opening) {
        depth = Math.max(0, depth - 1);
        newline();
      }
      result += char;
    } else if (char === ',' && stack.length) {
      result += char;
      newline();
    } else {
      result += char;
    }
  }
  return result.trimEnd();
}

function renderCounterexample(stdout, choice, fileName) {
  const lines = stdout.trim().split(/\r?\n/);
  if (!lines[0]) throw new Error('Haskell decoder produced no value');
  const pretty = prettyHaskell(lines[0]).split('\n').map((line) => `  ${line}`).join('\n');
  const type = choice.inputs.length === 1 ? choice.inputs[0].sourceType : undefined;
  const value = [...(type ? [`counterexample :: ${type}`] : []), 'counterexample =', pretty].join('\n');
  const content = [
    `-- Blaster counterexample: ${choice.property}`,
    `-- Compiled UPLC replay: ${choice.replay}`,
    `-- Decoded with Plutus FromData from ${fileName}`,
    '',
    value,
    ...(lines.length > 1 ? ['', '-- Original input bindings:', ...lines.slice(1).map((line) => `-- ${line}`)] : [])
  ].join('\n');
  return { value, content };
}

module.exports = { prettyHaskell, renderCounterexample };
