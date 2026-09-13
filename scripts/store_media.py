"""Shared OCR and duration probes for store media."""

import re
import shutil
import subprocess
import tempfile
from pathlib import Path


# Shared by capture preflight and media validation. These are actual CLI panes,
# not labels attached to shell placeholders.
AGENT_EXECUTABLES = {
    'copilot': ('copilot',),
    'claude': ('claude',),
    'codex': ('codex', 'codex-cli'),
    'opencode': ('opencode',),
    'antigravity': ('agy', 'antigravity', 'antigravity-cli'),
    'cursor-agent': ('cursor-agent',),
    'pi': ('pi',),
    'hermes': ('hermes', 'hermes-agent'),
    'openclaw': ('openclaw',),
}
AGENT_LABELS = (
    'Copilot CLI', 'Claude Code', 'Codex', 'OpenCode', 'Antigravity',
    'Cursor Agent', 'Pi', 'Hermes', 'OpenClaw',
)


def require_agent_executables() -> dict[str, str]:
    resolved = {}
    missing = []
    for name, aliases in AGENT_EXECUTABLES.items():
        executable = next((path for alias in aliases if (path := shutil.which(alias))), None)
        if executable is None:
            missing.append('/'.join(aliases))
        else:
            resolved[name] = executable
    if missing:
        raise RuntimeError(
            'Store capture requires real agent CLIs on PATH. Missing: '
            + ', '.join(missing)
            + '. Configure a capture host with these tools before retrying; '
            'no placeholder panes will be created.'
        )
    return resolved


def require_agent_family(text: str, source: str) -> None:
    compact = re.sub(r'[^a-z0-9]+', '', text.casefold())
    missing = []
    for label in AGENT_LABELS:
        # Pi must be a whole word: Copilot also contains the letters "pi".
        found = (re.search(r'\bpi\b', text, re.IGNORECASE) is not None
                 if label == 'Pi' else
                 re.sub(r'[^a-z0-9]+', '', label.casefold()) in compact)
        if not found:
            missing.append(label)
    if missing:
        raise ValueError(f'{source} is missing agent-family content: {", ".join(missing)}')


def _ocr_texts(paths: list[Path]) -> dict[Path, str]:
    swift_source = r'''
import Foundation
import Vision
import AppKit

let listPath = CommandLine.arguments[1]
let contents = try String(contentsOfFile: listPath, encoding: .utf8)
let urls = contents.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]

for url in urls {
    guard let image = NSImage(contentsOf: url),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let cgImage = bitmap.cgImage else {
        print("FILE\t\(url.path)\tERROR\tCould not load image")
        continue
    }
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])
    let text = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: " ")
        .replacingOccurrences(of: "\n", with: " ")
    print("FILE\t\(url.path)")
    print(text)
    print("END_FILE")
}
'''
    with tempfile.NamedTemporaryFile('w', suffix='.swift') as script:
        with tempfile.NamedTemporaryFile('w') as file_list:
            script.write(swift_source)
            script.flush()
            file_list.write('\n'.join(str(path) for path in paths))
            file_list.flush()
            result = subprocess.run(
                ['swift', script.name, file_list.name],
                stdout=subprocess.PIPE,
                text=True,
                check=True,
            )

    for line in result.stdout.splitlines():
        if line.startswith('FILE\t') and '\tERROR\t' in line:
            path, error = line[5:].split('\tERROR\t', 1)
            raise ValueError(f'OCR failed for {path}: {error}')
    texts: dict[Path, str] = {}
    for block in result.stdout.split('END_FILE')[:-1]:
        lines = [line for line in block.strip().splitlines() if line]
        if not lines or not lines[0].startswith('FILE\t'):
            continue
        path = Path(lines[0].split('\t', 1)[1])
        texts[path] = ' '.join(lines[1:])
    missing = [str(path) for path in paths if path not in texts]
    if missing:
        raise ValueError(f'OCR did not return text for {", ".join(missing)}.')
    return texts


def _video_duration(path: Path) -> float:
    ffprobe = shutil.which('ffprobe')
    if ffprobe is None:
        raise RuntimeError('ffprobe is required to read demo video duration.')
    result = subprocess.run(
        [
            ffprobe,
            '-v',
            'error',
            '-show_entries',
            'format=duration',
            '-of',
            'default=noprint_wrappers=1:nokey=1',
            str(path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )
    return float(result.stdout.strip())
