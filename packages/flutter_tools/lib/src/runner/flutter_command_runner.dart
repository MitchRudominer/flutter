// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as path;

import '../android/android_sdk.dart';
import '../base/context.dart';
import '../base/logger.dart';
import '../base/process.dart';
import '../cache.dart';
import '../globals.dart';
import '../package_map.dart';
import '../toolchain.dart';
import '../version.dart';

const String kFlutterRootEnvironmentVariableName = 'FLUTTER_ROOT'; // should point to //flutter/ (root of flutter/flutter repo)
const String kFlutterEngineEnvironmentVariableName = 'FLUTTER_ENGINE'; // should point to //engine/src/ (root of flutter/engine repo)
const String kSnapshotFileName = 'flutter_tools.snapshot'; // in //flutter/bin/cache/
const String kFlutterToolsScriptFileName = 'flutter_tools.dart'; // in //flutter/packages/flutter_tools/bin/
const String kFlutterEnginePackageName = 'sky_engine';

class FlutterCommandRunner extends CommandRunner {
  FlutterCommandRunner({ bool verboseHelp: false }) : super(
    'flutter',
    'Manage your Flutter app development.'
  ) {
    argParser.addFlag('verbose',
        abbr: 'v',
        negatable: false,
        help: 'Noisy logging, including all shell commands executed.');
    argParser.addOption('device-id',
        abbr: 'd',
        help: 'Target device id.');
    argParser.addFlag('version',
        negatable: false,
        help: 'Reports the version of this tool.');
    argParser.addFlag('color',
        negatable: true,
        hide: !verboseHelp,
        help: 'Whether to use terminal colors.');

    String packagesHelp;
    if (FileSystemEntity.isFileSync('.packages'))
      packagesHelp = '\n(defaults to ".packages")';
    else
      packagesHelp = '\n(required, since the current directory does not contain a ".packages" file)';
    argParser.addOption('packages',
        hide: !verboseHelp,
        help: 'Path to your ".packages" file.$packagesHelp');
    argParser.addOption('flutter-root',
        help: 'The root directory of the Flutter repository (uses \$$kFlutterRootEnvironmentVariableName if set).',
              defaultsTo: _defaultFlutterRoot);

    if (verboseHelp)
      argParser.addSeparator('Local build selection options (not normally required):');

    argParser.addOption('local-engine-src-path',
        hide: !verboseHelp,
        help:
            'Path to your engine src directory, if you are building Flutter locally.\n'
            'Defaults to \$$kFlutterEngineEnvironmentVariableName if set, otherwise defaults to the path given in your pubspec.yaml\n'
            'dependency_overrides for $kFlutterEnginePackageName, if any, or, failing that, tries to guess at the location\n'
            'based on the value of the --flutter-root option.');

    argParser.addOption('local-engine',
        hide: !verboseHelp,
        help:
            'Name of a build output within the engine out directory, if you are building Flutter locally.\n'
            'Use this to select a specific version of the engine if you have built multiple engine targets.\n'
            'This path is relative to --local-engine-src-path/out.');
  }

  @override
  String get usageFooter {
    return 'Run "flutter -h -v" for verbose help output, including less commonly used options.';
  }

  static String get _defaultFlutterRoot {
    if (Platform.environment.containsKey(kFlutterRootEnvironmentVariableName))
      return Platform.environment[kFlutterRootEnvironmentVariableName];
    try {
      if (Platform.script.scheme == 'data')
        return '../..'; // we're running as a test
      String script = Platform.script.toFilePath();
      if (path.basename(script) == kSnapshotFileName)
        return path.dirname(path.dirname(path.dirname(script)));
      if (path.basename(script) == kFlutterToolsScriptFileName)
        return path.dirname(path.dirname(path.dirname(path.dirname(script))));

      // If run from a bare script within the repo.
      if (script.contains('flutter/packages/'))
        return script.substring(0, script.indexOf('flutter/packages/') + 8);
      if (script.contains('flutter/examples/'))
        return script.substring(0, script.indexOf('flutter/examples/') + 8);
    } catch (error) {
      // we don't have a logger at the time this is run
      // (which is why we don't use printTrace here)
      print('Unable to locate flutter root: $error');
    }
    return '.';
  }

  @override
  Future<dynamic> run(Iterable<String> args) {
    // Have an invocation of 'build' print out it's sub-commands.
    if (args.length == 1 && args.first == 'build')
      args = <String>['build', '-h'];

    return super.run(args).then((dynamic result) {
      return result;
    }).whenComplete(() {
      logger.flush();
    });
  }

  @override
  Future<int> runCommand(ArgResults globalResults) {
    // Check for verbose.
    if (globalResults['verbose'])
      context[Logger] = new VerboseLogger();

    if (globalResults.wasParsed('color'))
      logger.supportsColor = globalResults['color'];

    // we must set Cache.flutterRoot early because other features use it
    // (e.g. enginePath's initialiser uses it)
    Cache.flutterRoot = path.normalize(path.absolute(globalResults['flutter-root']));

    _checkFlutterCopy();

    PackageMap.instance = new PackageMap(path.normalize(path.absolute(
      globalResults.wasParsed('packages') ? globalResults['packages'] : '.packages'
    )));

    // See if the user specified a specific device.
    deviceManager.specifiedDeviceId = globalResults['device-id'];

    // Set up the tooling configuration.
    String enginePath = _findEnginePath(globalResults);
    if (enginePath != null) {
      ToolConfiguration.instance.engineSrcPath = enginePath;
      ToolConfiguration.instance.engineBuildPath = _findEngineBuildPath(globalResults, enginePath);
    }

    // The Android SDK could already have been set by tests.
    if (!context.isSet(AndroidSdk)) {
      if (enginePath != null) {
        context[AndroidSdk] = new AndroidSdk('$enginePath/third_party/android_tools/sdk');
      } else {
        context[AndroidSdk] = AndroidSdk.locateAndroidSdk();
      }
    }

    if (globalResults['version']) {
      flutterUsage.sendCommand('version');
      printStatus(FlutterVersion.getVersion(Cache.flutterRoot).toString());
      return new Future<int>.value(0);
    }

    return super.runCommand(globalResults);
  }

  String _tryEnginePath(String enginePath) {
    if (FileSystemEntity.isDirectorySync(path.join(enginePath, 'out')))
      return enginePath;
    return null;
  }

  String _findEnginePath(ArgResults globalResults) {
    String engineSourcePath = globalResults['local-engine-src-path'] ?? Platform.environment[kFlutterEngineEnvironmentVariableName];

    if (engineSourcePath == null && globalResults['local-engine'] != null) {
      try {
        Uri engineUri = PackageMap.instance.map[kFlutterEnginePackageName];
        engineSourcePath = path.dirname(path.dirname(path.dirname(path.dirname(engineUri.path))));
        bool dirExists = FileSystemEntity.isDirectorySync(path.join(engineSourcePath, 'out'));
        if (engineSourcePath == '/' || engineSourcePath.isEmpty || !dirExists)
          engineSourcePath = null;
      } on FileSystemException { } on FormatException { }

      if (engineSourcePath == null)
        engineSourcePath = _tryEnginePath(path.join(Cache.flutterRoot, '../engine/src'));

      if (engineSourcePath == null) {
        printError('Unable to detect local Flutter engine build directory.\n'
            'Either specify a dependency_override for the $kFlutterEnginePackageName package in your pubspec.yaml and\n'
            'ensure --package-root is set if necessary, or set the \$$kFlutterEngineEnvironmentVariableName environment variable, or\n'
            'use --local-engine-src-path to specify the path to the root of your flutter/engine repository.');
        throw new ProcessExit(2);
      }
    }

    if (engineSourcePath != null && _tryEnginePath(engineSourcePath) == null) {
      printError('Unable to detect a Flutter engine build directory in $engineSourcePath.\n'
          'Please ensure that $engineSourcePath is a Flutter engine \'src\' directory and that\n'
          'you have compiled the engine in that directory, which should produce an \'out\' directory');
      throw new ProcessExit(2);
    }

    return engineSourcePath;
  }

  String _findEngineBuildPath(ArgResults globalResults, String enginePath) {
    String localEngine;
    if (globalResults['local-engine'] != null) {
      localEngine = globalResults['local-engine'];
    } else {
      printError('You must specify --local-engine if you are using a locally built engine.');
      throw new ProcessExit(2);
    }

    String engineBuildPath = path.join(enginePath, 'out', localEngine);
    if (!FileSystemEntity.isDirectorySync(engineBuildPath)) {
      printError('No Flutter engine build found at $engineBuildPath.');
      throw new ProcessExit(2);
    }

    return engineBuildPath;
  }

  static void initFlutterRoot() {
    if (Cache.flutterRoot == null)
      Cache.flutterRoot = _defaultFlutterRoot;
  }

  /// Get all pub packages in the Flutter repo.
  List<Directory> getRepoPackages() {
    return _gatherProjectPaths(path.absolute(Cache.flutterRoot))
      .map((String dir) => new Directory(dir))
      .toList();
  }

  static List<String> _gatherProjectPaths(String rootPath) {
    if (FileSystemEntity.isFileSync(path.join(rootPath, '.dartignore')))
      return <String>[];

    if (FileSystemEntity.isFileSync(path.join(rootPath, 'pubspec.yaml')))
      return <String>[rootPath];

    return new Directory(rootPath)
      .listSync(followLinks: false)
      .expand((FileSystemEntity entity) {
        return entity is Directory ? _gatherProjectPaths(entity.path) : <String>[];
      })
      .toList();
  }

  /// Check that the Flutter being run is the one we're expecting.
  void _checkFlutterCopy() {
    String directory = path.normalize(path.absolute(Directory.current.path));

    // Check if the cwd is a flutter dir.
    while (directory.isNotEmpty) {
      if (_isDirectoryFlutterRepo(directory)) {
        if (directory != Cache.flutterRoot) {
          printError(
            'Warning: the active Flutter is not the one from the current directory.\n'
            '  Active Flutter   : ${Cache.flutterRoot}\n'
            '  Current directory: $directory\n'
          );
        }

        break;
      }

      String parent = path.dirname(directory);
      if (parent == directory)
        break;
      directory = parent;
    }
  }

  // Check if `bin/flutter` and `bin/cache/engine.stamp` exist.
  bool _isDirectoryFlutterRepo(String directory) {
    return
      FileSystemEntity.isFileSync(path.join(directory, 'bin/flutter')) &&
      FileSystemEntity.isFileSync(path.join(directory, 'bin/cache/engine.stamp'));
  }
}
