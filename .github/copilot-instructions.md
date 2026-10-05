# Copilot Instructions for Flutty

## Build, Test, and Lint

```bash
# Generate the ignored MonkeyMux application assets
./scripts/build_monkeymux_assets.sh

# Install dependencies
flutter pub get

# Run code generator (Drift, Freezed, Riverpod)
dart run build_runner build

# Analyze code (treats warnings as errors in CI)
flutter analyze --fatal-warnings

# Format code
dart format .

# Run all tests
flutter test

# Run a single test file
flutter test test/unit/database_test.dart

# Run tests matching a name pattern
flutter test --name "insert and retrieve host"

# Integration tests
flutter test integration_test
```

## Pre-Commit Checklist

**IMPORTANT**: Before committing code changes, run the checks that match the
scope of your change:

```bash
# 1. Analyze for ALL issues (not just warnings - CI fails on info too)
flutter analyze

# 2. Format all code
dart format .

# 3. Run tests relevant to the changed behavior
flutter test test/path/to/relevant_test.dart
```

Run the full `flutter test` suite locally when the touched area is broad,
high-risk, or lacks a narrower targeted test. Otherwise, CI runs the full suite
after the PR is opened. CI will fail if there are ANY analyzer issues
(including `info` level). Common issues to watch for:

- **`public_member_api_docs`**: Add `///` documentation to all public members
- **`prefer_const_constructors`**: Use `const` for widget constructors when possible
- **`deprecated_member_use`**: Replace deprecated APIs (e.g., `Color.value` → `Color.toARGB32()`)
- **`cascade_invocations`**: Use `..` cascade notation for chained method calls on same object
- **`sort_constructors_first`**: Place factory constructors before field declarations
- **`avoid_equals_and_hash_code_on_mutable_classes`**: Add `@immutable` annotation to immutable classes
- **`prefer_expression_function_bodies`**: Use `=>` for single-expression functions

## Architecture

This is a cross-platform SSH client using **Clean Architecture** with three layers:

### Data Layer (`lib/data/`)
- **database/**: Drift (SQLite) schemas and generated code. Tables are defined as classes extending `Table`. Run `build_runner` after modifying.
- **repositories/**: Database access patterns. Each repository wraps database operations and exposes a Riverpod provider.

### Domain Layer (`lib/domain/`)
- **models/**: Domain entities (terminal themes, etc.)
- **services/**: Business logic services (SSH, auth, key management). Services receive repositories via constructor injection.

### Presentation Layer (`lib/presentation/`)
- **screens/**: Full page widgets, one per feature
- **widgets/**: Reusable UI components

### App Layer (`lib/app/`)
- **router.dart**: GoRouter configuration with auth-based redirects
- **theme.dart**: Material theme configuration

### State Management
Uses **Riverpod** throughout:
- Providers defined at the bottom of service/repository files
- `StateNotifier` for mutable state (e.g., `ActiveSessionsNotifier`)
- Async data uses `AsyncValue` pattern

### Navigation
Uses **GoRouter** with named routes. Route names are constants in the `Routes` class.

## Code Conventions

### Generated Files
Files matching `*.g.dart`, `*.freezed.dart`, `*.mocks.dart` are generated. Never edit manually. Regenerate with:
```bash
dart run build_runner build
```

### Linting
Strict linting is enforced (see `analysis_options.yaml`):
- `prefer_single_quotes` - use single quotes for strings
- `require_trailing_commas` - add trailing commas
- `prefer_const_constructors` - use const where possible
- `public_member_api_docs` - document all public APIs with dartdoc

### Database Testing
Use in-memory database for tests:
```dart
db = AppDatabase.forTesting(NativeDatabase.memory());
```

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`

### Branching
- `main` - stable releases
- `develop` - PR target for new work
- `feature/*`, `fix/*` - working branches
