#!/usr/bin/env node
/**
 * Laptop wrangler deploy is forbidden.
 * Workers Builds injects WORKERS_CI=1. That is the only uploader.
 * Dev and types stay allowed. Push origin/main via Make MCP ship.
 */
import { spawnSync } from 'node:child_process';

const cmd = String(process.env.WRANGLER_COMMAND || '').trim();
const ci = process.env.WORKERS_CI === '1' || Boolean(process.env.WORKERS_CI_BUILD_UUID);
const npmDeploy = process.argv.includes('--npm-deploy');
const isUpload = cmd === 'deploy' || cmd === 'versions upload';

function refuse() {
  process.stderr.write(`
watch does not deploy from a laptop.
Push origin/main with Make MCP: ship worker=watch.
Workers Builds (WORKERS_CI=1) is the only wrangler upload.
workers.dev and preview URLs are off.
`);
  process.exit(1);
}

if (ci) {
  if (npmDeploy) {
    const mig = spawnSync(
      'npx',
      ['wrangler', 'd1', 'migrations', 'apply', 'watch', '--remote'],
      { stdio: 'inherit', shell: false },
    );
    if (mig.status !== 0) process.exit(mig.status || 1);
    const r = spawnSync(
      'npx',
      ['wrangler', 'deploy', '-c', 'wrangler.jsonc'],
      { stdio: 'inherit', shell: false },
    );
    process.exit(r.status === 0 ? 0 : r.status || 1);
  }
  process.exit(0);
}

if (npmDeploy || isUpload) refuse();
process.exit(0);
