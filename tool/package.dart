// ignore_for_file: avoid_print
import 'dart:io';

void main(List<String> args) async {
  final isWindows = Platform.isWindows;
  final isLinux = Platform.isLinux;
  if (!isWindows && !isLinux) {
    stderr.writeln('Unsupported platform: ${Platform.operatingSystem}');
    exit(1);
  }

  final platform = isWindows ? 'windows' : 'linux';
  final version = _readVersion();

  // Step 1: Build Flutter (release)
  print('=== Building Flutter ($platform) release ===');

  final packageConfig = File('.dart_tool/package_config.json');
  if (await packageConfig.exists()) {
    final content = await packageConfig.readAsString();
    final needsClean = (Platform.isLinux && content.contains('C:/')) ||
                       (Platform.isWindows && content.contains('/home/'));
    if (needsClean) {
      print('  Platform switch detected, reconfiguring...');
      final f = await _resolveFlutter();
      await _run(f.cmd, [...f.baseArgs, 'clean']);
      await _run(f.cmd, [...f.baseArgs, 'pub', 'get']);
    }
  }

  final f = await _resolveFlutter();
  final result = await _run(f.cmd, [...f.baseArgs, 'build', platform, '--release']);
  if (result != 0) {
    stderr.writeln('Flutter build failed');
    exit(1);
  }

  // Step 2: Package
  if (isWindows) {
    await _packageWindows(version);
  } else {
    await _packageLinux(version);
  }

  print('\n=== All done ===');
}

Future<void> _packageWindows(String version) async {
  Directory('dist').createSync(recursive: true);

  // Inno Setup installer
  final hasIscc = await _hasOnPath('iscc');
  if (hasIscc) {
    print('\n=== Creating Inno Setup installer ===');
    await _run('iscc', ['/DMyAppVersion=$version', 'windows\\installer\\setup.iss']);
  } else {
    print('\n=== Skipping Inno Setup (iscc not on PATH) ===');
    print('  Install: winget install JRSoftware.InnoSetup');
    print('  Then add to PATH:');
    print('    \$env:Path += ";\$env:LOCALAPPDATA\\Programs\\Inno Setup 6"');
  }

  // ZIP portable package
  print('\n=== Creating ZIP package ===');
  await _run('powershell', [
    'Compress-Archive',
    '-Path',
    'build\\windows\\x64\\runner\\Release\\*',
    '-DestinationPath',
    'dist\\MutsuRelay-$version.zip',
    '-CompressionLevel',
    'Optimal',
    '-Force',
  ]);

  final dir = Directory('dist');
  if (await dir.exists()) {
    print('\nOutputs:');
    await for (final f in dir.list()) {
      print('  ${f.path}');
    }
  }
}

Future<void> _packageLinux(String version) async {
  final hasAppimage = await _hasOnPath('appimagetool');
  if (!hasAppimage) {
    print('\n=== Skipping AppImage (appimagetool not on PATH) ===');
    print('  Install appimagetool from:');
    print('  https://github.com/AppImage/appimagetool/releases');
    exit(1);
  }

  print('\n=== Creating AppImage ===');
  final bundleDir = 'build/linux/x64/release/bundle';
  const binaryName = 'mutsurelay';
  const displayName = 'MutsuRelay';

  // Create AppRun entry point
  final appRun = File('$bundleDir/AppRun');
  await appRun.writeAsString(
    '#!/bin/bash\n'
    'HERE="\$(dirname "\$(readlink -f "\$0")")"\n'
    'cd "\$HERE"\n'
    'export LD_LIBRARY_PATH="\$HERE/lib:\$LD_LIBRARY_PATH"\n'
    'exec "./$binaryName" "\$@"\n',
  );
  await Process.run('chmod', ['+x', appRun.path]);

  // Create .desktop file
  final desktop = File('$bundleDir/$binaryName.desktop');
  await desktop.writeAsString(
    '[Desktop Entry]\n'
    'Name=$displayName\n'
    'Exec=$binaryName\n'
    'Icon=$binaryName\n'
    'Type=Application\n'
    'Categories=Audio;Utility;AudioVideo;\n'
    'StartupNotify=true\n',
  );

  // Copy icon
  final icon = File('assets/logo_tr.png');
  if (await icon.exists()) {
    await icon.copy('$bundleDir/$binaryName.png');
  }

  final outDir = Directory('dist')..createSync(recursive: true);
  final outPath = 'dist/MutsuRelay-$version.AppImage';
  final env = Map<String, String>.from(Platform.environment)
    ..['APPIMAGE_EXTRACT_AND_RUN'] = '1';
  await _run('appimagetool', [bundleDir, outPath], env: env);

  // tar.gz portable package
  print('\n=== Creating tar.gz package ===');
  final stageName = 'MutsuRelay-$version';
  final stageDir = 'build/linux/x64/release/targz/$stageName';
  if (Directory(stageDir).existsSync()) {
    Directory(stageDir).deleteSync(recursive: true);
  }
  Directory(stageDir).createSync(recursive: true);

  // Copy bundle contents
  await _run('cp', ['-r', '$bundleDir/.', stageDir]);

  // Create run script (same logic as AppRun but named for manual extraction)
  final runScript = File('$stageDir/run.sh');
  await runScript.writeAsString(
    '#!/bin/bash\n'
    'HERE="\$(dirname "\$(readlink -f "\$0")")"\n'
    'cd "\$HERE"\n'
    'export LD_LIBRARY_PATH="\$HERE/lib:\$LD_LIBRARY_PATH"\n'
    'exec "./$binaryName" "\$@"\n',
  );
  await Process.run('chmod', ['+x', runScript.path]);

  final targzPath = 'dist/MutsuRelay-$version.tar.gz';
  final result = await Process.run('tar', [
    '-czf', targzPath,
    '-C', 'build/linux/x64/release/targz',
    stageName,
  ]);
  Directory('build/linux/x64/release/targz').deleteSync(recursive: true);

  if (result.exitCode != 0) {
    stderr.writeln('tar.gz creation failed: ${result.stderr}');
    exit(1);
  }

  print('\nOutputs:');
  await for (final f in outDir.list()) {
    print('  ${f.path}');
  }
}

String _readVersion() {
  try {
    final pubspec = File('pubspec.yaml');
    for (final line in pubspec.readAsLinesSync()) {
      final m = RegExp(r'^version:\s*(\S+)').firstMatch(line);
      if (m != null) return m.group(1)!;
    }
  } catch (_) {}
  return '1.0.0';
}

Future<({String cmd, List<String> baseArgs})> _resolveFlutter() async {
  if (Platform.isLinux && await _hasOnPath('fvm')) {
    return (cmd: 'fvm', baseArgs: ['flutter']);
  }
  return (cmd: 'flutter', baseArgs: <String>[]);
}

Future<bool> _hasOnPath(String executable) async {
  if (Platform.isWindows) {
    final r = await Process.run('where', [executable],
        runInShell: true);
    return r.exitCode == 0;
  }
  final r = await Process.run('which', [executable]);
  return r.exitCode == 0;
}

Future<int> _run(String cmd, List<String> args,
    {Map<String, String>? env}) async {
  final p = await Process.start(cmd, args,
      runInShell: true,
      mode: ProcessStartMode.inheritStdio,
      environment: env);
  return p.exitCode;
}
