"""Compile the real Windows utility with API shims to test failure handling.

The shim controls Win32 return values; this does not replace Windows Unicode
integration coverage.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class WindowsUtf8Test(unittest.TestCase):
    def test_failed_size_query_does_not_allocate_or_attempt_conversion(self):
        compiler = shutil.which('clang++') or shutil.which('g++')
        assert compiler is not None, 'A C++ compiler is required'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'flutter_windows.h').write_text(
                'inline void FlutterDesktopResyncOutputStreams() {}\n')
            (root / 'io.h').write_text('''#include <cstdio>
inline int freopen_s(FILE**, const char*, const char*, FILE*) { return 0; }
inline int _dup2(int, int) { return 0; }
inline int _fileno(FILE*) { return 0; }
''')
            (root / 'windows.h').write_text('''#include <cwchar>
constexpr int CP_UTF8 = 65001;
constexpr int WC_ERR_INVALID_CHARS = 128;
inline bool AllocConsole() { return false; }
inline const wchar_t* GetCommandLineW() { return L""; }
inline wchar_t** CommandLineToArgvW(const wchar_t*, int*) { return nullptr; }
inline void LocalFree(void*) {}
extern int calls;
extern int query_result;
extern int conversion_result;
inline int WideCharToMultiByte(int, int, const wchar_t*, int,
                               char* output, int, void*, void*) {
  ++calls;
  if (!output) return query_result;
  if (conversion_result > 0) output[0] = 'x';
  return conversion_result;
}
''')
            test = root / 'main.cpp'
            test.write_text('''#include <cassert>
#include <cstdlib>
#include <iostream>
#include <new>
#include "utils.h"
int calls = 0;
int query_result = 0;
int conversion_result = 0;
// Fail fast rather than letting the original underflow allocate four GiB.
void* operator new(std::size_t size) {
  if (size > 1024 * 1024) throw std::bad_alloc();
  if (void* p = std::malloc(size)) return p;
  throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
int main() {
  try {
    assert(Utf8FromUtf16(nullptr).empty());
    assert(calls == 0);
    assert(Utf8FromUtf16(L"invalid").empty());
    assert(calls == 1);
    query_result = 1; // empty UTF-16 input, including its NUL
    assert(Utf8FromUtf16(L"").empty());
    assert(calls == 2);
    query_result = 2;
    conversion_result = 1;
    assert(Utf8FromUtf16(L"x") == "x");
    assert(calls == 4);
    conversion_result = 0;
    assert(Utf8FromUtf16(L"x").empty());
    assert(calls == 6);
  } catch (const std::bad_alloc&) {
    std::cerr << "Failed size query attempted a huge allocation\\n";
    return 1;
  }
}
''')
            executable = root / 'utf8-test'
            result = subprocess.run([
                compiler, '-std=c++17', '-I', str(root),
                '-I', str(ROOT / 'windows/runner'),
                str(ROOT / 'windows/runner/utils.cpp'), str(test), '-o', str(executable),
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
