// ignore_for_file: avoid_print
import 'dart:io';

void main(List<String> args) async {
  final isWindows = Platform.isWindows;
  final buildScript = isWindows ? 'native\\build.ps1' : 'native/build.sh';
  final shell = isWindows ? 'powershell' : 'bash';
  final platform = isWindows ? 'windows' : 'linux';

  // Step 1: Build Rust native library
  print('=== Building Rust native library ===');
  final build = await Process.run(shell, [buildScript, ...args],
      runInShell: true);
  stdout.write(build.stdout);
  stderr.write(build.stderr);
  if (build.exitCode != 0) {
    stderr.writeln('Rust build failed');
    exit(1);
  }

  // Step 2: Run Flutter
  print('=== Starting Flutter ($platform) ===');

  final packageConfig = File('.dart_tool/package_config.json');
  if (await packageConfig.exists()) {
    final content = await packageConfig.readAsString();
    final needsClean = (Platform.isLinux && content.contains('C:/')) ||
                       (Platform.isWindows && content.contains('/home/'));
    if (needsClean) {
      print('  Platform switch detected, reconfiguring...');
      final f = await _resolveFlutter();
      await Process.run(f.cmd, [...f.baseArgs, 'clean'], runInShell: true);
      await Process.run(f.cmd, [...f.baseArgs, 'pub', 'get'], runInShell: true);
    }
  }

  final f = await _resolveFlutter();
  final flutter = await Process.start(f.cmd, [...f.baseArgs, 'run', '-d', platform],
      runInShell: true,
      mode: ProcessStartMode.inheritStdio);
  exit(await flutter.exitCode);
}

Future<({String cmd, List<String> baseArgs})> _resolveFlutter() async {
  if (Platform.isLinux) {
    final hasFvm = await Process.run('which', ['fvm']).then((r) => r.exitCode == 0);
    if (hasFvm) return (cmd: 'fvm', baseArgs: ['flutter']);
  }
  return (cmd: 'flutter', baseArgs: <String>[]);
}
