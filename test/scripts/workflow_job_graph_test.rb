# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'open3'

# Every job named in `needs:` must exist, and every `needs.<job>` expression a
# job evaluates must name one of its own declared dependencies. A dangling
# reference makes GitHub reject the workflow at trigger time, after merge.
class WorkflowJobGraphTest < Minitest::Test
  WORKFLOWS = Dir[File.expand_path('../../.github/workflows/*.yml', __dir__)].sort

  def test_workflows_are_present
    refute_empty(WORKFLOWS)
  end

  def test_every_needs_entry_names_an_existing_job
    each_job do |path, name, job, jobs|
      missing = declared_needs(job) - jobs.keys
      assert_empty(missing, "#{path}: job #{name} needs unknown jobs")
    end
  end

  def test_every_needs_expression_uses_a_declared_dependency
    each_job do |path, name, job, _jobs|
      referenced = YAML.dump(job).scan(/needs\.([A-Za-z0-9_-]+)\./).flatten.uniq
      undeclared = referenced - declared_needs(job)
      assert_empty(undeclared, "#{path}: job #{name} references undeclared needs")
    end
  end

  def test_vendored_terminal_dependency_changes_trigger_tests
    workflow = YAML.safe_load(
      File.read(File.join(File.dirname(WORKFLOWS.first), 'ci.yml')), aliases: true
    )
    filter = workflow.fetch('jobs').fetch('changes').fetch('steps').find { |step| step['id'] == 'filter' }
    assert_equal('python3 scripts/ci_changes.py', filter.fetch('run'))
    %w[pubspec.yaml pubspec.lock].each do |file|
      output, error, status = Open3.capture3(
        'python3', '-c',
        'import sys,json; sys.path.insert(0,"scripts"); from ci_changes import classify; print(json.dumps(classify([sys.argv[1]])))',
        "third_party/xterm/#{file}",
        chdir: File.expand_path('../..', __dir__),
      )
      assert(status.success?, error)
      assert(JSON.parse(output).fetch('run_check'))
    end
  end

  def test_terminal_goldens_run_on_macos_and_gate_ci
    jobs = YAML.safe_load(
      File.read(File.join(File.dirname(WORKFLOWS.first), 'ci.yml')), aliases: true
    ).fetch('jobs')
    terminal = jobs.fetch('terminal-test')
    assert_match(/^macos-/, terminal.fetch('runs-on'))
    assert_equal("needs.changes.outputs.run_check == 'true'", terminal.fetch('if'))
    step = terminal.fetch('steps').find { |entry| entry['working-directory'] == 'third_party/xterm' }
    assert_includes(step.fetch('run'), 'flutter pub get')
    assert_includes(step.fetch('run'), 'flutter test --no-pub')
    assert_includes(declared_needs(jobs.fetch('ci')), 'terminal-test')
    gate = jobs.fetch('ci').fetch('steps').find { |entry| entry['name'] == 'Evaluate results' }
    assert_equal('${{ needs.terminal-test.result }}', gate.fetch('env').fetch('TERMINAL_TEST_RESULT'))
    assert_includes(gate.fetch('run'), '"terminal-test:$TERMINAL_TEST_RESULT"')
  end

  private

  def each_job
    WORKFLOWS.each do |path|
      jobs = YAML.safe_load(File.read(path), aliases: true).fetch('jobs')
      jobs.each { |name, job| yield File.basename(path), name, job, jobs }
    end
  end

  def declared_needs(job)
    Array(job['needs'])
  end
end
