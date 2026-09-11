const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {rpc} = require('../../assets/scripts/agent_usage_probe.cjs');

for (const extension of ['cmd', 'ps1']) for (const framed of [false, true]) {
  test(`Windows npm .${extension} launcher forwards ${framed ? 'Content-Length' : 'JSONL'} RPC`, {skip: process.platform !== 'win32'}, async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "usage quote ' \u2018 \u2019 \u201a \u201b é "));
    try {
      const source = path.join(dir, 'fake-agent.cjs');
      fs.writeFileSync(source, `
        function reply(id, result) {
          const body = JSON.stringify({id,result});
          const response = ${framed} ? 'Content-Length: '+Buffer.byteLength(body)+'\\r\\n\\r\\n'+body : body+'\\n';
          process.stdout.write(response.slice(0, 7));
          setTimeout(() => process.stdout.write(response.slice(7)), 20);
        }
        if (${framed}) process.stdin.once('data', () => reply(2, {ok:true}));
        else {
          let initialized = false;
          require('readline').createInterface({input:process.stdin}).on('line', line => {
            const message = JSON.parse(line);
            if (message.method === 'initialize') reply(1, {});
            else if (message.method === 'initialized') initialized = true;
            else if (message.method === 'account/get' && initialized) reply(2, {ok:true});
            else process.exit(1);
          });
        }
      `);
      const launcher = path.join(dir, 'agent.' + extension);
      fs.copyFileSync(process.execPath, path.join(dir, 'node.exe'));
      fs.writeFileSync(launcher, extension === 'cmd'
        ? '@echo off\r\n"%~dp0node.exe" "%~dp0fake-agent.cjs" %*\r\n'
        : '& "$PSScriptRoot/node.exe" "$PSScriptRoot/fake-agent.cjs" @args; exit $LASTEXITCODE');
      assert.deepEqual(await rpc(launcher, [], 'account/get', framed, !framed), {ok:true});
    } finally {
      // Windows keeps executables locked until asynchronous process-tree cleanup finishes.
      await fs.promises.rm(dir, {recursive:true,force:true,maxRetries:10,retryDelay:100});
    }
  });
}
