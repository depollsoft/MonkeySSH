const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {rpc} = require('../../assets/scripts/agent_usage_probe.cjs');

for (const framed of [false, true]) {
  test(`Windows npm launcher forwards ${framed ? 'Content-Length' : 'JSONL'} RPC`, {skip: process.platform !== 'win32'}, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "usage quote ' é "));
    try {
      const source = path.join(dir, 'fake-agent.cjs');
      fs.writeFileSync(source, `
        const body = JSON.stringify({id:2,result:{ok:true}});
        const response = ${framed} ? 'Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body : body+'\\n';
        process.stdin.once('data', () => {
          process.stdout.write(response.slice(0, 7));
          setTimeout(() => process.stdout.write(response.slice(7)), 20);
        });
      `);
      const launcher = path.join(dir, 'agent.cmd');
      fs.copyFileSync(process.execPath, path.join(dir, 'node.exe'));
      fs.writeFileSync(launcher, '@echo off\r\n"%~dp0node.exe" "%~dp0fake-agent.cjs" %*\r\n');
      assert.deepEqual(await rpc(launcher, [], 'account/get', framed, false), {ok:true});
    } finally {
      // Windows keeps executables locked until asynchronous process-tree cleanup finishes.
      await fs.promises.rm(dir, {recursive:true,force:true,maxRetries:10,retryDelay:100});
    }
  });
}
