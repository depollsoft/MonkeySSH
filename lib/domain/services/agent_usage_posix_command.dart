import 'dart:convert';

import 'shell_quoting.dart';

/// Marker emitted on stdout when the remote cached usage probe is missing,
/// unreadable, symlinked, has unsafe permissions, or fails SHA-256 validation.
const posixAgentUsageCacheMissMarker = '__monkeyssh_usage_cache_miss__';

/// Runs the usage reader or reports its missing runtime for each selected agent.
String buildPosixAgentUsageCommand(
  String bootstrap,
  Map<String, String> agents,
) {
  final input = base64.encode(utf8.encode(jsonEncode(agents)));
  final missing = agents.keys.map(
    (id) => shellEscapePosix(
      '__monkeyssh_usage__=${jsonEncode({'id': id, 'status': 'runtimeUnavailable'})}',
    ),
  );
  return 'if command -v node >/dev/null 2>&1; then '
      'node -e ${shellEscapePosix(bootstrap)} ${shellEscapePosix(input)} 2>/dev/null; '
      "else printf '%s\\n' ${missing.join(' ')}; fi";
}

/// Runs a cached POSIX usage probe after verifying ownership, private
/// permissions, non-symlink status, and the full SHA-256 digest of the exact
/// bytes to be executed.
///
/// Emits [posixAgentUsageCacheMissMarker] on any mismatch or missing entry so
/// the caller can re-bootstrap and atomically repair the cache file.
String buildCachedPosixAgentUsageCommand({
  required String sha256Hex,
  required Map<String, String> agents,
}) {
  final fileTag = sha256Hex.substring(0, 16);
  final loader = <String>[
    "const __fs=require('fs'),__p=require('path'),__c=require('crypto'),",
    '__h=process.env.HOME;let __s;',
    'try{if(__h){',
    "const __cd=__p.join(__h,'.cache'),__d=__p.join(__cd,'monkeyssh');",
    'const __cds=__fs.lstatSync(__cd),__ds=__fs.lstatSync(__d);',
    "const __u=typeof process.getuid==='function'?process.getuid():null;",
    'if(!__cds.isSymbolicLink()&&__cds.isDirectory()&&',
    '!__ds.isSymbolicLink()&&__ds.isDirectory()&&',
    '(__u===null||__ds.uid===__u)&&(__ds.mode&0o022)===0){',
    "const __f=__p.join(__d,'usage-probe-$fileTag.cjs');",
    'const __fd=__fs.openSync(__f,',
    '__fs.constants.O_RDONLY|(__fs.constants.O_NOFOLLOW||0));',
    'try{const __st=__fs.fstatSync(__fd);',
    'if(__st.isFile()&&(__u===null||__st.uid===__u)&&(__st.mode&0o022)===0){',
    'const __b=__fs.readFileSync(__fd);',
    "if(__c.createHash('sha256').update(__b).digest('hex')==='$sha256Hex'){",
    "__s=__b.toString('utf8');}}",
    '}finally{__fs.closeSync(__fd);}}}}catch(_){}',
    "if(__s){process.env.MONKEYSSH_USAGE_PROBE='1';eval(__s);}",
    "else{process.stdout.write('$posixAgentUsageCacheMissMarker\\n');}",
  ].join();
  return buildPosixAgentUsageCommand(loader, agents);
}

/// Bootstraps the POSIX usage probe from inline base64 [source], atomically
/// populating or repairing the verified private cache entry before executing
/// the trusted in-memory bytes.
String buildBootstrapPosixAgentUsageCommand({
  required String source,
  required String sha256Hex,
  required Map<String, String> agents,
}) {
  final fileTag = sha256Hex.substring(0, 16);
  final bootstrap = <String>[
    "process.env.MONKEYSSH_USAGE_PROBE='1';",
    "const __b=Buffer.from('$source','base64'),__s=__b.toString('utf8');",
    'try{',
    "const __fs=require('fs'),__p=require('path'),__c=require('crypto'),",
    '__h=process.env.HOME;',
    'if(__h){',
    "const __cd=__p.join(__h,'.cache'),__d=__p.join(__cd,'monkeyssh');",
    'let __ok=false;',
    'try{const __cds=__fs.lstatSync(__cd);',
    'if(!__cds.isSymbolicLink()&&__cds.isDirectory())__ok=true;',
    "}catch(e){if(e&&e.code==='ENOENT'){",
    '__fs.mkdirSync(__cd,{recursive:true,mode:0o700});__ok=true;}}',
    'if(__ok){',
    'let __dok=false;',
    'try{const __ds=__fs.lstatSync(__d);',
    'if(!__ds.isSymbolicLink()&&__ds.isDirectory())__dok=true;',
    "}catch(e){if(e&&e.code==='ENOENT'){",
    '__fs.mkdirSync(__d,{mode:0o700});__dok=true;}}',
    'if(__dok){',
    '__fs.chmodSync(__d,0o700);',
    'const __ds=__fs.lstatSync(__d);',
    "const __u=typeof process.getuid==='function'?process.getuid():null;",
    'if(!__ds.isSymbolicLink()&&__ds.isDirectory()&&',
    '(__u===null||__ds.uid===__u)&&(__ds.mode&0o022)===0){',
    "const __f=__p.join(__d,'usage-probe-$fileTag.cjs');",
    'let __valid=false;',
    'try{const __fd=__fs.openSync(__f,',
    '__fs.constants.O_RDONLY|(__fs.constants.O_NOFOLLOW||0));',
    'try{const __st=__fs.fstatSync(__fd);',
    'if(__st.isFile()&&(__u===null||__st.uid===__u)&&(__st.mode&0o022)===0){',
    'const __eb=__fs.readFileSync(__fd);',
    "__valid=__c.createHash('sha256').update(__eb).digest('hex')==='$sha256Hex';",
    '}}finally{__fs.closeSync(__fd);}}catch(_){}',
    'if(!__valid){',
    "const __t=__f+'.'+process.pid+'.'+__c.randomBytes(6).toString('hex');",
    'let __wfd;',
    'try{',
    '__wfd=__fs.openSync(__t,',
    '__fs.constants.O_WRONLY|__fs.constants.O_CREAT|__fs.constants.O_EXCL|',
    '(__fs.constants.O_NOFOLLOW||0),0o600);',
    '__fs.writeFileSync(__wfd,__b);__fs.closeSync(__wfd);__wfd=null;',
    '__fs.renameSync(__t,__f);',
    '}finally{',
    'if(__wfd!=null){try{__fs.closeSync(__wfd);}catch(_){}}',
    'try{__fs.unlinkSync(__t);}catch(_){}}',
    '}}}}}}catch(_){}',
    'eval(__s)',
  ].join();
  return buildPosixAgentUsageCommand(bootstrap, agents);
}
