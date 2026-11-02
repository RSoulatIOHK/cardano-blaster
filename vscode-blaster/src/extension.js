'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');
const {
  collectResultFiles,
  mergeResults,
  propertyBlocks,
  propertyForSource,
  sourceState
} = require('./results');
const {
  collectNativeReportFiles,
  counterexamples,
  fileState,
  inputState,
  loadNativeReports,
  readNativeReport
} = require('./native');

let state = mergeResults([]);
let nativeReports = [];
let diagnostics;
let decoration;
let status;
let lenses;

function configuredPath(name) {
  const value = vscode.workspace.getConfiguration('blaster').get(name, '');
  if (!value) return '';
  const folders = vscode.workspace.workspaceFolders || [];
  const root = folders.length ? folders[0].uri.fsPath : process.cwd();
  return path.resolve(value.replace(/^\$\{workspaceFolder\}/, root));
}

function plutusCheckout() {
  const configured = configuredPath('plutusPath');
  if (configured) return configured;
  return (vscode.workspace.workspaceFolders || [])
    .map((folder) => folder.uri.fsPath)
    .find((folder) => fs.existsSync(path.join(folder, 'cabal.project'))) || '';
}

function resultFiles() {
  return collectResultFiles(resultsRoot());
}

function resultsRoot() {
  const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
  return configuredPath('outputPath') || path.join(folder || path.resolve(__dirname, '../..'), 'cardano-blaster-results');
}

function loadFiles(files, nativeFiles = [], announce = true) {
  state = mergeResults(files);
  const native = loadNativeReports(nativeFiles);
  nativeReports = native.reports;
  refreshEditors();
  lenses.refresh();
  const verified = state.allProperties.filter((item) => item.outcome === 'verified').length;
  const nativeVerified = nativeReports.reduce((n, report) =>
    n + report.results.filter((result) => result.outcome === 'verified').length, 0);
  const cexCount = counterexamples(nativeReports).length;
  status.text = `$(beaker) Blaster: ${verified + nativeVerified} verified · ${cexCount} Haskell CEX`;
  status.tooltip = state.files.length || nativeFiles.length
    ? [...state.files, ...nativeFiles].join('\n')
    : 'No assurance results loaded';
  status.show();
  if (state.errors.length || native.errors.length) {
    vscode.window.showWarningMessage(`Blaster could not read ${state.errors.length + native.errors.length} result file(s).`);
  } else if (announce) {
    vscode.window.showInformationMessage(`Blaster loaded ${state.allProperties.length} legacy properties and ${nativeReports.length} native reports.`);
  }
}

function refreshResults(announce = true) {
  loadFiles(resultFiles(), collectNativeReportFiles(resultsRoot()), announce);
}

function rangeOf(block) {
  return new vscode.Range(
    block.start.line,
    block.start.character,
    block.end.line,
    block.end.character
  );
}

function idRangeOf(block) {
  return new vscode.Range(
    block.idStart.line,
    block.idStart.character,
    block.idEnd.line,
    block.idEnd.character
  );
}

function detail(property) {
  const parts = [property.label];
  if (property.method) parts.push(property.method);
  if (property.date) parts.push(property.date);
  return parts.join(' · ');
}

function counterexampleText(property) {
  const entries = Object.entries(property.counterexample || {});
  return entries.length ? entries.map(([name, value]) => `${name} = ${value}`).join(', ') : '';
}

function freshnessOf(document, property) {
  try {
    return sourceState(document.uri.fsPath, state.sourceHashes, document.getText(), property);
  } catch (_) {
    return { tracked: false, stale: false };
  }
}

function updateEditor(editor) {
  if (!editor || editor.document.languageId !== 'haskell' || editor.document.uri.scheme !== 'file') return;
  const document = editor.document;
  const blocks = propertyBlocks(document.getText());
  const shown = [];
  const problems = [];
  for (const block of blocks) {
    const property = propertyForSource(state, document.uri.fsPath, block.id);
    const freshness = freshnessOf(document, property);
    if (!property) {
      shown.push({
        range: idRangeOf(block),
        renderOptions: { after: { contentText: '  ○ no Blaster result', color: new vscode.ThemeColor('descriptionForeground') } }
      });
      continue;
    }
    if (freshness.stale) {
      shown.push({
        range: idRangeOf(block),
        renderOptions: { after: { contentText: '  ⚠ stale Blaster result', color: new vscode.ThemeColor('editorWarning.foreground') } }
      });
      const diagnostic = new vscode.Diagnostic(rangeOf(block), freshness.reason || 'Blaster evidence predates the current Haskell source.', vscode.DiagnosticSeverity.Warning);
      diagnostic.source = 'Blaster';
      diagnostic.code = 'stale-evidence';
      problems.push(diagnostic);
    } else if (property.outcome === 'verified') {
      shown.push({
        range: idRangeOf(block),
        hoverMessage: property.notes || detail(property),
        renderOptions: { after: { contentText: '  ✓ Blaster verified', color: new vscode.ThemeColor('testing.iconPassed') } }
      });
    } else {
      shown.push({
        range: idRangeOf(block),
        hoverMessage: property.notes || detail(property),
        renderOptions: { after: { contentText: `  ✗ ${property.outcome}`, color: new vscode.ThemeColor('testing.iconFailed') } }
      });
      const model = counterexampleText(property);
      const diagnostic = new vscode.Diagnostic(rangeOf(block),
        model ? `${detail(property)}. Counterexample: ${model}` : detail(property),
        property.outcome === 'inconclusive' ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error);
      diagnostic.source = 'Blaster';
      diagnostic.code = property.outcome;
      problems.push(diagnostic);
    }
  }
  editor.setDecorations(decoration, shown);
  diagnostics.set(document.uri, problems);
}

function refreshEditors() {
  for (const editor of vscode.window.visibleTextEditors) updateEditor(editor);
}

class LensProvider {
  constructor() {
    this.emitter = new vscode.EventEmitter();
    this.onDidChangeCodeLenses = this.emitter.event;
  }

  refresh() {
    this.emitter.fire();
  }

  provideCodeLenses(document) {
    return propertyBlocks(document.getText()).flatMap((block) => {
      const property = propertyForSource(state, document.uri.fsPath, block.id);
      const freshness = freshnessOf(document, property);
      let title = '$(circle-outline) No Blaster evidence';
      let command = 'blaster.loadResults';
      let args = [];
      if (property) {
        title = freshness.stale
          ? '$(warning) Blaster evidence is stale — rerun'
          : property.outcome === 'verified'
            ? `$(pass) ${detail(property)}`
            : `$(error) ${detail(property)}`;
        command = freshness.stale ? 'blaster.runProperty' : 'blaster.openResult';
        args = freshness.stale ? [document.uri, block.id] : [property.logFile || property.resultFile];
      }
      return [
        new vscode.CodeLens(idRangeOf(block), { title, command, arguments: args }),
        new vscode.CodeLens(idRangeOf(block), {
          title: '$(debug-rerun) Rerun this property',
          command: 'blaster.runProperty',
          arguments: [document.uri, block.id]
        })
      ];
    });
  }
}

class NativeReportLensProvider {
  provideCodeLenses(document) {
    if (path.basename(document.uri.fsPath) !== 'report.json') return [];
    try {
      const choices = counterexamples([readNativeReport(document.uri.fsPath)]);
      const range = new vscode.Range(0, 0, 0, 0);
      return choices.flatMap((choice) => [
        new vscode.CodeLens(range, {
          title: `$(file-code) Open Haskell CEX: ${choice.property}`,
          command: 'blaster.openHaskellCounterexample', arguments: [choice]
        }),
        new vscode.CodeLens(range, {
          title: `$(terminal) Decode Haskell CEX: ${choice.property}`,
          command: 'blaster.decodeHaskellCounterexample', arguments: [choice]
        })
      ]);
    } catch (_) {
      return [];
    }
  }
}

class HoverProvider {
  provideHover(document, position) {
    for (const block of propertyBlocks(document.getText())) {
      if (!idRangeOf(block).contains(position)) continue;
      const property = propertyForSource(state, document.uri.fsPath, block.id);
      if (!property) return new vscode.Hover('No Blaster evidence is loaded for this property.');
      const freshness = freshnessOf(document, property);
      if (freshness.stale) return new vscode.Hover(
        freshness.reason || 'Blaster evidence predates the current Haskell source.', idRangeOf(block));
      const markdown = new vscode.MarkdownString();
      markdown.appendMarkdown(`**${property.label}**\n\n`);
      if (property.method) markdown.appendMarkdown(`Method: \`${property.method}\`  \n`);
      if (property.date) markdown.appendMarkdown(`Date: ${property.date}  \n`);
      if (property.scriptHash) markdown.appendMarkdown(`Script: \`${property.scriptHash}\`  \n`);
      const model = counterexampleText(property);
      if (model) markdown.appendMarkdown(`\n**Counterexample**\n\n${model.replaceAll('|', '\\|')}\n`);
      if (property.replay) markdown.appendText(`\nReplay: ${property.replay.status}\n`);
      if (property.haskell) markdown.appendCodeblock(property.haskell, 'haskell');
      if (property.notes) markdown.appendText(`\n${property.notes}`);
      return new vscode.Hover(markdown, idRangeOf(block));
    }
  }
}

async function chooseResults() {
  const selection = await vscode.window.showOpenDialog({
    canSelectFiles: true,
    canSelectFolders: true,
    canSelectMany: true,
    filters: { JSON: ['json'] },
    title: 'Select Blaster report.json, verified-assurance.json, or a result directory'
  });
  if (!selection) return;
  const files = [];
  const nativeFiles = [];
  for (const uri of selection) {
    const stat = fs.statSync(uri.fsPath);
    if (stat.isDirectory()) {
      files.push(...collectResultFiles(uri.fsPath));
      nativeFiles.push(...collectNativeReportFiles(uri.fsPath));
    } else if (path.basename(uri.fsPath) === 'report.json') nativeFiles.push(uri.fsPath);
    else files.push(uri.fsPath);
  }
  loadFiles([...new Set(files)], [...new Set(nativeFiles)]);
}

async function chooseCounterexample() {
  const choices = counterexamples(nativeReports).sort((a, b) =>
    String(b.report.created || '').localeCompare(String(a.report.created || '')));
  if (!choices.length) {
    vscode.window.showInformationMessage('Load a native report with a confirmed, exported Haskell counterexample first.');
    return undefined;
  }
  if (choices.length === 1) return choices[0];
  const picked = await vscode.window.showQuickPick(choices.map((choice) => ({
    label: choice.property,
    description: `replay ${choice.replay}`,
    detail: choice.report.file,
    choice
  })), { placeHolder: 'Select a confirmed Haskell counterexample' });
  return picked?.choice;
}

function counterexampleFile(choice) {
  const source = fileState(choice.sourceFile, choice.sourceHash);
  if (!source.matches) {
    vscode.window.showErrorMessage(`Counterexample source is missing or differs from its report: ${choice.sourceFile}`);
    return undefined;
  }
  const changed = inputState(choice.report);
  if (changed.length) {
    vscode.window.showWarningMessage(`This is a historical counterexample: ${changed.length} checked input file(s) have changed or disappeared.`);
  }
  return choice.sourceFile;
}

async function openHaskellCounterexample(selected) {
  const choice = selected?.sourceFile ? selected : await chooseCounterexample();
  if (!choice) return;
  const file = counterexampleFile(choice);
  if (file) await openResult(file);
}

async function decodeHaskellCounterexample(selected) {
  const choice = selected?.sourceFile ? selected : await chooseCounterexample();
  if (!choice) return;
  const file = counterexampleFile(choice);
  if (!file) return;
  const plutus = plutusCheckout();
  if (!plutus || !fs.existsSync(path.join(plutus, 'cabal.project'))) {
    vscode.window.showErrorMessage('Set blaster.plutusPath to a Plutus checkout with cabal.project to run Haskell FromData.');
    return;
  }
  await openResult(file);
  const config = vscode.workspace.getConfiguration('blaster');
  const environment = config.get('haskellEnvironment', {});
  const task = new vscode.Task(
    { type: 'blaster', task: `decode-${choice.property}` }, vscode.TaskScope.Workspace,
    `Decode Haskell CEX: ${choice.property}`, 'Blaster',
    new vscode.ProcessExecution(config.get('cabalPath', 'cabal'),
      ['exec', '--disable-tests', '--disable-benchmarks', '--',
        'ghci', '-ignore-dot-ghci', '-package', 'plutus-ledger-api', file, '-e', 'main'],
      { cwd: plutus, env: environment })
  );
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, panel: vscode.TaskPanelKind.Dedicated, clear: true };
  await vscode.tasks.executeTask(task);
}

async function chooseCheckInputs() {
  const active = vscode.window.activeTextEditor?.document.uri.fsPath;
  let blueprint = active && path.basename(active) === 'plutus.json' ? active : undefined;
  let assurance = active && path.basename(active) === 'assurance.json' ? active : undefined;
  if (blueprint && fs.existsSync(path.join(path.dirname(blueprint), 'assurance.json'))) {
    assurance = path.join(path.dirname(blueprint), 'assurance.json');
  }
  if (assurance && fs.existsSync(path.join(path.dirname(assurance), 'plutus.json'))) {
    blueprint = path.join(path.dirname(assurance), 'plutus.json');
  }
  if (!blueprint) {
    const selected = await vscode.window.showOpenDialog({ canSelectMany: false, filters: { JSON: ['json'] }, title: 'Select plutus.json' });
    blueprint = selected?.[0]?.fsPath;
  }
  if (!blueprint) return undefined;
  if (!assurance) {
    const selected = await vscode.window.showOpenDialog({ canSelectMany: false, filters: { JSON: ['json'] },
      defaultUri: vscode.Uri.file(path.dirname(blueprint)), title: 'Select assurance.json' });
    assurance = selected?.[0]?.fsPath;
  }
  return assurance ? { blueprint, assurance } : undefined;
}

async function runNativeCheck() {
  const inputs = await chooseCheckInputs();
  if (!inputs) return;
  const local = path.resolve(__dirname, '../../.lake/build/bin/cardano-blaster');
  const executable = configuredPath('executablePath') || (fs.existsSync(local) ? local : 'cardano-blaster');
  const output = resultsRoot();
  const args = ['check', inputs.blueprint, inputs.assurance];
  args.push('--output', output);
  if (vscode.workspace.getConfiguration('blaster').get('refreshEnvironment', false)) args.push('--refresh-environment');
  const task = new vscode.Task(
    { type: 'blaster', task: 'native-check' }, vscode.TaskScope.Workspace,
    'Check blueprint and assurance', 'Blaster',
    new vscode.ProcessExecution(executable, args, { cwd: path.dirname(inputs.blueprint) })
  );
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, panel: vscode.TaskPanelKind.Dedicated, clear: true };
  const execution = await vscode.tasks.executeTask(task);
  const subscription = vscode.tasks.onDidEndTaskProcess(async (event) => {
    if (event.execution !== execution) return;
    subscription.dispose();
    refreshResults(false);
    if (event.exitCode === 1 && counterexamples(nativeReports).length) {
      const action = await vscode.window.showInformationMessage('Blaster found a falsified property with a confirmed Haskell CEX.', 'Open Haskell CEX');
      if (action) await openHaskellCounterexample();
    } else if (event.exitCode === 0) {
      vscode.window.showInformationMessage('All selected properties were verified.');
    } else if (event.exitCode !== 1) {
      vscode.window.showErrorMessage(`Cardano Blaster exited with code ${event.exitCode}. See the task terminal.`);
    }
  });
}

function requiredRunConfiguration() {
  const values = {
    core: configuredPath('corePath'),
    plutus: configuredPath('plutusPath'),
    cips: configuredPath('cipsPath'),
    ual: configuredPath('ualPath'),
    z3: configuredPath('z3Path'),
    output: configuredPath('outputPath'),
    ghc: vscode.workspace.getConfiguration('blaster').get('ghcPath', 'ghc'),
    python: vscode.workspace.getConfiguration('blaster').get('pythonPath', 'python3'),
    nixShell: vscode.workspace.getConfiguration('blaster').get('nixShell', false),
    skipBuild: vscode.workspace.getConfiguration('blaster').get('skipBuild', false)
  };
  const missing = ['core', 'plutus', 'cips', 'z3', 'output'].filter((key) => !values[key]);
  return { values, missing };
}

async function runVerification() {
  const { values, missing } = requiredRunConfiguration();
  if (missing.length) {
    const action = await vscode.window.showErrorMessage(`Configure Blaster paths first: ${missing.join(', ')}.`, 'Open Settings');
    if (action === 'Open Settings') vscode.commands.executeCommand('workbench.action.openSettings', 'blaster');
    return;
  }
  const script = path.join(values.core, 'scripts', 'verify_assurance_workspace.py');
  if (!fs.existsSync(script)) {
    vscode.window.showErrorMessage(`Blaster verifier not found: ${script}`);
    return;
  }
  const args = [script, '--plutus', values.plutus, '--cips', values.cips, '--z3', values.z3, '--ghc', values.ghc, '--output', values.output];
  if (values.ual) args.push('--ual', values.ual);
  if (values.skipBuild) args.push('--skip-build');
  const process = values.nixShell ? 'nix' : values.python;
  const processArgs = values.nixShell
    ? ['develop', `${values.plutus}#ghc96`, '--command', values.python, ...args]
    : args;
  const task = new vscode.Task(
    { type: 'blaster', task: 'assurance-demo' },
    vscode.TaskScope.Workspace,
    'Assurance demo',
    'Blaster',
    new vscode.ProcessExecution(process, processArgs, { cwd: values.core })
  );
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, panel: vscode.TaskPanelKind.Dedicated, clear: true };
  const execution = await vscode.tasks.executeTask(task);
  const subscription = vscode.tasks.onDidEndTaskProcess((event) => {
    if (event.execution !== execution) return;
    subscription.dispose();
    if (event.exitCode === 0) {
      refreshResults(false);
      vscode.window.showInformationMessage('Blaster assurance verification passed.');
    } else {
      refreshResults(false);
      vscode.window.showErrorMessage(`Blaster assurance verification failed (exit ${event.exitCode}). See the Assurance demo terminal.`);
    }
  });
}

async function runProperty(uri, propertyId) {
  const document = uri ? await vscode.workspace.openTextDocument(uri) : vscode.window.activeTextEditor?.document;
  if (!document || document.languageId !== 'haskell') {
    vscode.window.showErrorMessage('Open a Haskell UAL specification to rerun a property.');
    return;
  }
  const id = propertyId || propertyBlocks(document.getText()).find((block) =>
    block.start.line <= vscode.window.activeTextEditor.selection.active.line &&
    block.end.line >= vscode.window.activeTextEditor.selection.active.line)?.id;
  if (!id) {
    vscode.window.showErrorMessage('Put the cursor inside a UAL PROPERTY block.');
    return;
  }
  if (document.isDirty && !(await document.save())) {
    vscode.window.showErrorMessage('Save the Haskell specification before rerunning Blaster.');
    return;
  }
  const { values, missing } = requiredRunConfiguration();
  if (missing.length) {
    vscode.window.showErrorMessage(`Configure Blaster paths first: ${missing.join(', ')}.`);
    return;
  }
  const example = path.basename(path.dirname(document.uri.fsPath)).toLowerCase();
  if (!['auction', 'recursive', 'game', 'parameters'].includes(example)) {
    vscode.window.showErrorMessage('Focused replay supports Auction, Recursive, Game and Parameters examples.');
    return;
  }
  const ledger = path.resolve(values.core, '../CardanoLedgerApiBlaster');
  const repo = example === 'auction' ? ledger : values.core;
  const resultDir = path.join(values.output, 'property-runs', example, id);
  const script = path.resolve(__dirname, '../scripts/run_property.py');
  const args = [script, '--plutus', values.plutus, '--core', values.core,
    '--ledger', ledger, '--z3', values.z3, '--ghc', values.ghc,
    '--source', document.uri.fsPath, '--property', id, '--output', resultDir];
  const baseline = example === 'auction' ? configuredPath('auctionBaselinePath') : '';
  if (baseline) args.push('--reuse-bundle', baseline);
  const needsNix = values.nixShell && !baseline;
  const process = needsNix ? 'nix' : 'lake';
  const processArgs = needsNix
    ? ['develop', `${values.plutus}#ghc96`, '--command', 'lake', 'env', values.python, ...args]
    : ['env', values.python, ...args];
  const task = new vscode.Task(
    { type: 'blaster', task: `property-${id}` }, vscode.TaskScope.Workspace,
    `Property: ${id}`, 'Blaster',
    new vscode.ProcessExecution(process, processArgs, { cwd: repo })
  );
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Always, panel: vscode.TaskPanelKind.Dedicated, clear: true };
  const execution = await vscode.tasks.executeTask(task);
  const subscription = vscode.tasks.onDidEndTaskProcess(async (event) => {
    if (event.execution !== execution) return;
    subscription.dispose();
    refreshResults(false);
    const resultFile = path.join(resultDir, 'property-result.json');
    if (fs.existsSync(resultFile)) {
      const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
      const model = Object.entries(result.counterexample || {});
      const summary = result.outcome === 'falsified' && model.length
        ? `${id} falsified: ${model.map(([key, value]) => `${key}=${value}`).join(', ')}`
        : `${id}: ${result.outcome}`;
      vscode.window.showInformationMessage(summary, 'Open proof log').then((choice) => {
        if (choice === 'Open proof log') openResult(result.log);
      });
      if (result.outcome === 'falsified') await openResult(result.log);
    } else {
      vscode.window.showErrorMessage(`Property replay failed before Blaster checked ${id}. See the task terminal and build.log.`);
    }
  });
}

async function openResult(file) {
  if (!file) return;
  const document = await vscode.workspace.openTextDocument(vscode.Uri.file(file));
  await vscode.window.showTextDocument(document, { preview: true, viewColumn: vscode.ViewColumn.Beside });
}

function activate(context) {
  diagnostics = vscode.languages.createDiagnosticCollection('blaster');
  decoration = vscode.window.createTextEditorDecorationType({ rangeBehavior: vscode.DecorationRangeBehavior.ClosedClosed });
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 50);
  status.command = 'blaster.refreshResults';
  lenses = new LensProvider();

  context.subscriptions.push(
    diagnostics,
    decoration,
    status,
    lenses.emitter,
    vscode.commands.registerCommand('blaster.loadResults', chooseResults),
    vscode.commands.registerCommand('blaster.refreshResults', () => refreshResults()),
    vscode.commands.registerCommand('blaster.runWorkspaceVerification', runVerification),
    vscode.commands.registerCommand('blaster.runNativeCheck', runNativeCheck),
    vscode.commands.registerCommand('blaster.runProperty', runProperty),
    vscode.commands.registerCommand('blaster.openResult', openResult),
    vscode.commands.registerCommand('blaster.openHaskellCounterexample', openHaskellCounterexample),
    vscode.commands.registerCommand('blaster.decodeHaskellCounterexample', decodeHaskellCounterexample),
    vscode.languages.registerCodeLensProvider({ language: 'haskell', scheme: 'file' }, lenses),
    vscode.languages.registerCodeLensProvider({ language: 'json', scheme: 'file' }, new NativeReportLensProvider()),
    vscode.languages.registerHoverProvider({ language: 'haskell', scheme: 'file' }, new HoverProvider()),
    vscode.window.onDidChangeVisibleTextEditors(refreshEditors),
    vscode.workspace.onDidChangeTextDocument((event) => {
      const editor = vscode.window.visibleTextEditors.find((candidate) => candidate.document === event.document);
      if (editor) updateEditor(editor);
    }),
    vscode.workspace.onDidSaveTextDocument((document) => {
      const editor = vscode.window.visibleTextEditors.find((candidate) => candidate.document === document);
      if (editor) updateEditor(editor);
      lenses.refresh();
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('blaster')) refreshResults(false);
    })
  );
  refreshResults(false);
}

function deactivate() {}

module.exports = { activate, deactivate };
