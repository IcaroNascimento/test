// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:boolean_selector/boolean_selector.dart';
import 'package:collection/collection.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:source_span/source_span.dart';

import 'package:test_api/src/backend/platform_selector.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/runtime.dart'; // ignore: implementation_imports
import 'package:test_api/src/frontend/timeout.dart'; // ignore: implementation_imports
import 'package:test_api/src/utils.dart'; // ignore: implementation_imports

import '../util/io.dart';
import 'suite.dart';
import 'runtime_selection.dart';
import 'configuration/args.dart' as args;
import 'configuration/custom_runtime.dart';
import 'configuration/load.dart';
import 'configuration/reporters.dart';
import 'configuration/runtime_settings.dart';
import 'configuration/values.dart';

/// The key used to look up [Configuration.current] in a zone.
final _currentKey = Object();

/// A class that encapsulates the command-line configuration of the test runner.
class Configuration {
  /// An empty configuration with only default values.
  ///
  /// Using this is slightly more efficient than manually constructing a new
  /// configuration with no arguments.
  static final empty = Configuration._();

  /// The usage string for the command-line arguments.
  static String get usage => args.usage;

  /// Whether `--help` was passed.
  bool get help => _help ?? false;
  final bool _help;

  /// Whether `--version` was passed.
  bool get version => _version ?? false;
  final bool _version;

  /// Whether to pause for debugging after loading each test suite.
  bool get pauseAfterLoad => _pauseAfterLoad ?? false;
  final bool _pauseAfterLoad;

  /// Whether to run browsers in their respective debug modes
  bool get debug => pauseAfterLoad || (_debug ?? false) || _coverage != null;
  final bool _debug;

  /// The output folder for coverage gathering
  String get coverage => _coverage;
  final String _coverage;

  /// The path to the file from which to load more configuration information.
  ///
  /// This is *not* resolved automatically.
  String get configurationPath => _configurationPath ?? "dart_test.yaml";
  final String _configurationPath;

  /// The path to dart2js.
  String get dart2jsPath => _dart2jsPath ?? p.join(sdkDir, 'bin', 'dart2js');
  final String _dart2jsPath;

  /// The name of the reporter to use to display results.
  String get reporter => _reporter ?? defaultReporter;
  final String _reporter;

  /// Whether to disable retries of tests.
  bool get noRetry => _noRetry ?? false;
  final bool _noRetry;

  /// The URL for the `pub serve` instance from which to load tests, or `null`
  /// if tests should be loaded from the filesystem.
  final Uri pubServeUrl;

  /// Whether to use command-line color escapes.
  bool get color => _color ?? canUseSpecialChars;
  final bool _color;

  /// How many tests to run concurrently.
  int get concurrency =>
      pauseAfterLoad ? 1 : (_concurrency ?? defaultConcurrency);
  final int _concurrency;

  /// The index of the current shard, if sharding is in use, or `null` if it's
  /// not.
  ///
  /// Sharding is a technique that allows the Google internal test framework to
  /// easily split a test run across multiple workers without requiring the
  /// tests to be modified by the user. When sharding is in use, the runner gets
  /// a shard index (this field) and a total number of shards, and is expected
  /// to provide the following guarantees:
  ///
  /// * Running the same invocation of the runner, with the same shard index and
  ///   total shards, will run the same set of tests.
  /// * Across all shards, each test must be run exactly once.
  ///
  /// In addition, tests should be balanced across shards as much as possible.
  final int shardIndex;

  /// The total number of shards, if sharding is in use, or `null` if it's not.
  ///
  /// See [shardIndex] for details.
  final int totalShards;

  /// The list of packages to fold when producing [StackTrace]s.
  Set<String> get foldTraceExcept => _foldTraceExcept ?? Set();
  final Set<String> _foldTraceExcept;

  /// If non-empty, all packages not in this list will be folded when producing
  /// [StackTrace]s.
  Set<String> get foldTraceOnly => _foldTraceOnly ?? Set();
  final Set<String> _foldTraceOnly;

  /// The paths from which to load tests.
  List<String> get paths => _paths ?? ["test"];
  final List<String> _paths;

  /// Whether the load paths were passed explicitly or the default was used.
  bool get explicitPaths => _paths != null;

  /// The glob matching the basename of tests to run.
  ///
  /// This is used to find tests within a directory.
  Glob get filename => _filename ?? defaultFilename;
  final Glob _filename;

  /// The set of presets to use.
  ///
  /// Any chosen presets for the parent configuration are added to the chosen
  /// preset sets for child configurations as well.
  ///
  /// Note that the order of this set matters.
  final Set<String> chosenPresets;

  /// The set of tags that have been declared in any way in this configuration.
  Set<String> get knownTags {
    if (_knownTags != null) return _knownTags;

    var known = suiteDefaults.knownTags.toSet();
    for (var configuration in presets.values) {
      known.addAll(configuration.knownTags);
    }

    _knownTags = UnmodifiableSetView(known);
    return _knownTags;
  }

  Set<String> _knownTags;

  /// Configuration presets.
  ///
  /// These are configurations that can be explicitly selected by the user via
  /// the command line. Preset configuration takes precedence over the base
  /// configuration.
  ///
  /// This is guaranteed not to have any keys that match [chosenPresets]; those
  /// are resolved when the configuration is constructed.
  final Map<String, Configuration> presets;

  /// All preset names that are known to be valid.
  ///
  /// This includes presets that have already been resolved.
  Set<String> get knownPresets {
    if (_knownPresets != null) return _knownPresets;

    var known = presets.keys.toSet();
    for (var configuration in presets.values) {
      known.addAll(configuration.knownPresets);
    }

    _knownPresets = UnmodifiableSetView(known);
    return _knownPresets;
  }

  Set<String> _knownPresets;

  /// Built-in runtimes whose settings are overridden by the user.
  final Map<String, RuntimeSettings> overrideRuntimes;

  /// Runtimes defined by the user in terms of existing runtimes.
  final Map<String, CustomRuntime> defineRuntimes;

  /// The default suite-level configuration.
  final SuiteConfiguration suiteDefaults;

  /// Returns the current configuration, or a default configuration if no
  /// current configuration is set.
  ///
  /// The current configuration is set using [asCurrent].
  static Configuration get current =>
      Zone.current[_currentKey] as Configuration ?? Configuration();

  /// Parses the configuration from [args].
  ///
  /// Throws a [FormatException] if [args] are invalid.
  factory Configuration.parse(List<String> arguments) => args.parse(arguments);

  /// Loads the configuration from [path].
  ///
  /// If [global] is `true`, this restricts the configuration file to only rules
  /// that are supported globally.
  ///
  /// Throws an [IOException] if [path] does not exist or cannot be read. Throws
  /// a [FormatException] if its contents are invalid.
  factory Configuration.load(String path, {bool global = false}) =>
      load(path, global: global);

  factory Configuration(
      {bool help,
      bool version,
      bool pauseAfterLoad,
      bool debug,
      bool color,
      String configurationPath,
      String dart2jsPath,
      String reporter,
      String coverage,
      int pubServePort,
      int concurrency,
      int shardIndex,
      int totalShards,
      Iterable<String> paths,
      Iterable<String> foldTraceExcept,
      Iterable<String> foldTraceOnly,
      Glob filename,
      Iterable<String> chosenPresets,
      Map<String, Configuration> presets,
      Map<String, RuntimeSettings> overrideRuntimes,
      Map<String, CustomRuntime> defineRuntimes,
      bool noRetry,

      // Suite-level configuration
      bool jsTrace,
      bool runSkipped,
      Iterable<String> dart2jsArgs,
      String precompiledPath,
      Iterable<Pattern> patterns,
      Iterable<RuntimeSelection> runtimes,
      BooleanSelector includeTags,
      BooleanSelector excludeTags,
      Map<BooleanSelector, SuiteConfiguration> tags,
      Map<PlatformSelector, SuiteConfiguration> onPlatform,
      int testRandomizeOrderingSeed,

      // Test-level configuration
      Timeout timeout,
      bool verboseTrace,
      bool chainStackTraces,
      bool skip,
      int retry,
      String skipReason,
      PlatformSelector testOn,
      Iterable<String> addTags}) {
    var chosenPresetSet = chosenPresets?.toSet();
    var configuration = Configuration._(
        help: help,
        version: version,
        pauseAfterLoad: pauseAfterLoad,
        debug: debug,
        color: color,
        configurationPath: configurationPath,
        dart2jsPath: dart2jsPath,
        reporter: reporter,
        coverage: coverage,
        pubServePort: pubServePort,
        concurrency: concurrency,
        shardIndex: shardIndex,
        totalShards: totalShards,
        paths: paths,
        foldTraceExcept: foldTraceExcept,
        foldTraceOnly: foldTraceOnly,
        filename: filename,
        chosenPresets: chosenPresetSet,
        presets: _withChosenPresets(presets, chosenPresetSet),
        overrideRuntimes: overrideRuntimes,
        defineRuntimes: defineRuntimes,
        noRetry: noRetry,
        suiteDefaults: SuiteConfiguration(
            jsTrace: jsTrace,
            runSkipped: runSkipped,
            dart2jsArgs: dart2jsArgs,
            precompiledPath: precompiledPath,
            patterns: patterns,
            runtimes: runtimes,
            includeTags: includeTags,
            excludeTags: excludeTags,
            tags: tags,
            onPlatform: onPlatform,
            testRandomizeOrderingSeed: testRandomizeOrderingSeed,

            // Test-level configuration
            timeout: timeout,
            verboseTrace: verboseTrace,
            chainStackTraces: chainStackTraces,
            skip: skip,
            retry: retry,
            skipReason: skipReason,
            testOn: testOn,
            addTags: addTags));
    return configuration._resolvePresets();
  }

  static Map<String, Configuration> _withChosenPresets(
      Map<String, Configuration> map, Set<String> chosenPresets) {
    if (map == null || chosenPresets == null) return map;
    return map.map((key, config) => MapEntry(
        key,
        config.change(
            chosenPresets: config.chosenPresets.union(chosenPresets))));
  }

  /// Creates new Configuration.
  ///
  /// Unlike [new Configuration], this assumes [presets] is already resolved.
  Configuration._(
      {bool help,
      bool version,
      bool pauseAfterLoad,
      bool debug,
      bool color,
      String configurationPath,
      String dart2jsPath,
      String reporter,
      String coverage,
      int pubServePort,
      int concurrency,
      this.shardIndex,
      this.totalShards,
      Iterable<String> paths,
      Iterable<String> foldTraceExcept,
      Iterable<String> foldTraceOnly,
      Glob filename,
      Iterable<String> chosenPresets,
      Map<String, Configuration> presets,
      Map<String, RuntimeSettings> overrideRuntimes,
      Map<String, CustomRuntime> defineRuntimes,
      bool noRetry,
      SuiteConfiguration suiteDefaults})
      : _help = help,
        _version = version,
        _pauseAfterLoad = pauseAfterLoad,
        _debug = debug,
        _color = color,
        _configurationPath = configurationPath,
        _dart2jsPath = dart2jsPath,
        _reporter = reporter,
        _coverage = coverage,
        pubServeUrl = pubServePort == null
            ? null
            : Uri.parse("http://localhost:$pubServePort"),
        _concurrency = concurrency,
        _paths = _list(paths),
        _foldTraceExcept = _set(foldTraceExcept),
        _foldTraceOnly = _set(foldTraceOnly),
        _filename = filename,
        chosenPresets = UnmodifiableSetView(chosenPresets?.toSet() ?? Set()),
        presets = _map(presets),
        overrideRuntimes = _map(overrideRuntimes),
        defineRuntimes = _map(defineRuntimes),
        _noRetry = noRetry,
        suiteDefaults = pauseAfterLoad == true
            ? suiteDefaults?.change(timeout: Timeout.none) ??
                SuiteConfiguration(timeout: Timeout.none)
            : suiteDefaults ?? SuiteConfiguration.empty {
    if (_filename != null && _filename.context.style != p.style) {
      throw ArgumentError(
          "filename's context must match the current operating system, was "
          "${_filename.context.style}.");
    }

    if ((shardIndex == null) != (totalShards == null)) {
      throw ArgumentError(
          "shardIndex and totalShards may only be passed together.");
    } else if (shardIndex != null) {
      RangeError.checkValueInInterval(
          shardIndex, 0, totalShards - 1, "shardIndex");
    }
  }

  /// Creates a new [Configuration] that takes its configuration from
  /// [SuiteConfiguration].
  factory Configuration.fromSuiteConfiguration(
          SuiteConfiguration suiteConfig) =>
      Configuration._(suiteDefaults: suiteConfig);

  /// Returns an unmodifiable copy of [input].
  ///
  /// If [input] is `null` or empty, this returns `null`.
  static List<T> _list<T>(Iterable<T> input) {
    if (input == null) return null;
    var list = List<T>.unmodifiable(input);
    if (list.isEmpty) return null;
    return list;
  }

  /// Returns a set from [input].
  static Set<T> _set<T>(Iterable<T> input) {
    if (input == null) return null;
    var set = Set<T>.from(input);
    if (set.isEmpty) return null;
    return set;
  }

  /// Returns an unmodifiable copy of [input] or an empty unmodifiable map.
  static Map<K, V> _map<K, V>(Map<K, V> input) {
    input ??= {};
    return Map.unmodifiable(input);
  }

  /// Runs [body] with [this] as [Configuration.current].
  ///
  /// This is zone-scoped, so [this] will be the current configuration in any
  /// asynchronous callbacks transitively created by [body].
  T asCurrent<T>(T body()) => runZoned(body, zoneValues: {_currentKey: this});

  /// Throws a [FormatException] if [this] refers to any undefined runtimes.
  void validateRuntimes(List<Runtime> allRuntimes) {
    // We don't need to verify [customRuntimes] here because those runtimes
    // already need to be verified and resolved to create [allRuntimes].

    for (var settings in overrideRuntimes.values) {
      if (!allRuntimes
          .any((runtime) => runtime.identifier == settings.identifier)) {
        throw SourceSpanFormatException(
            'Unknown platform "${settings.identifier}".',
            settings.identifierSpan);
      }
    }

    suiteDefaults.validateRuntimes(allRuntimes);
    for (var config in presets.values) {
      config.validateRuntimes(allRuntimes);
    }
  }

  /// Merges this with [other].
  ///
  /// For most fields, if both configurations have values set, [other]'s value
  /// takes precedence. However, certain fields are merged together instead.
  /// This is indicated in those fields' documentation.
  Configuration merge(Configuration other) {
    if (this == Configuration.empty) return other;
    if (other == Configuration.empty) return this;

    var foldTraceOnly = other._foldTraceOnly ?? _foldTraceOnly;
    var foldTraceExcept = other._foldTraceExcept ?? _foldTraceExcept;
    if (_foldTraceOnly != null) {
      if (other._foldTraceExcept != null) {
        foldTraceOnly = _foldTraceOnly.difference(other._foldTraceExcept);
      } else if (other._foldTraceOnly != null) {
        foldTraceOnly = other._foldTraceOnly.intersection(_foldTraceOnly);
      }
    } else if (_foldTraceExcept != null) {
      if (other._foldTraceOnly != null) {
        foldTraceOnly = other._foldTraceOnly.difference(_foldTraceExcept);
      } else if (other._foldTraceExcept != null) {
        foldTraceExcept = other._foldTraceExcept.union(_foldTraceExcept);
      }
    }

    var result = Configuration._(
        help: other._help ?? _help,
        version: other._version ?? _version,
        pauseAfterLoad: other._pauseAfterLoad ?? _pauseAfterLoad,
        color: other._color ?? _color,
        configurationPath: other._configurationPath ?? _configurationPath,
        dart2jsPath: other._dart2jsPath ?? _dart2jsPath,
        reporter: other._reporter ?? _reporter,
        coverage: other._coverage ?? _coverage,
        pubServePort: (other.pubServeUrl ?? pubServeUrl)?.port,
        concurrency: other._concurrency ?? _concurrency,
        shardIndex: other.shardIndex ?? shardIndex,
        totalShards: other.totalShards ?? totalShards,
        paths: other._paths ?? _paths,
        foldTraceExcept: foldTraceExcept,
        foldTraceOnly: foldTraceOnly,
        filename: other._filename ?? _filename,
        chosenPresets: chosenPresets.union(other.chosenPresets),
        presets: _mergeConfigMaps(presets, other.presets),
        overrideRuntimes: mergeUnmodifiableMaps(
            overrideRuntimes, other.overrideRuntimes,
            value: (settings1, settings2) => RuntimeSettings(
                settings1.identifier,
                settings1.identifierSpan,
                settings1.settings.toList()..addAll(settings2.settings))),
        defineRuntimes:
            mergeUnmodifiableMaps(defineRuntimes, other.defineRuntimes),
        noRetry: other._noRetry ?? _noRetry,
        suiteDefaults: suiteDefaults.merge(other.suiteDefaults));
    result = result._resolvePresets();

    // Make sure the merged config preserves any presets that were chosen and
    // discarded.
    result._knownPresets = knownPresets.union(other.knownPresets);
    return result;
  }

  /// Returns a copy of this configuration with the given fields updated.
  ///
  /// Note that unlike [merge], this has no merging behavior—the old value is
  /// always replaced by the new one.
  Configuration change(
      {bool help,
      bool version,
      bool pauseAfterLoad,
      bool color,
      String configurationPath,
      String dart2jsPath,
      String reporter,
      int pubServePort,
      int concurrency,
      int shardIndex,
      int totalShards,
      Iterable<String> paths,
      Iterable<String> exceptPackages,
      Iterable<String> onlyPackages,
      Glob filename,
      Iterable<String> chosenPresets,
      Map<String, Configuration> presets,
      Map<String, RuntimeSettings> overrideRuntimes,
      Map<String, CustomRuntime> defineRuntimes,
      bool noRetry,

      // Suite-level configuration
      bool jsTrace,
      bool runSkipped,
      Iterable<String> dart2jsArgs,
      String precompiledPath,
      Iterable<Pattern> patterns,
      Iterable<RuntimeSelection> runtimes,
      BooleanSelector includeTags,
      BooleanSelector excludeTags,
      Map<BooleanSelector, SuiteConfiguration> tags,
      Map<PlatformSelector, SuiteConfiguration> onPlatform,
      int testRandomizeOrderingSeed,

      // Test-level configuration
      Timeout timeout,
      bool verboseTrace,
      bool chainStackTraces,
      bool skip,
      String skipReason,
      PlatformSelector testOn,
      Iterable<String> addTags}) {
    var config = Configuration._(
        help: help ?? _help,
        version: version ?? _version,
        pauseAfterLoad: pauseAfterLoad ?? _pauseAfterLoad,
        color: color ?? _color,
        configurationPath: configurationPath ?? _configurationPath,
        dart2jsPath: dart2jsPath ?? _dart2jsPath,
        reporter: reporter ?? _reporter,
        pubServePort: pubServePort ?? pubServeUrl?.port,
        concurrency: concurrency ?? _concurrency,
        shardIndex: shardIndex ?? this.shardIndex,
        totalShards: totalShards ?? this.totalShards,
        paths: paths ?? _paths,
        foldTraceExcept: exceptPackages ?? _foldTraceExcept,
        foldTraceOnly: onlyPackages ?? _foldTraceOnly,
        filename: filename ?? _filename,
        chosenPresets: chosenPresets ?? this.chosenPresets,
        presets: presets ?? this.presets,
        overrideRuntimes: overrideRuntimes ?? this.overrideRuntimes,
        defineRuntimes: defineRuntimes ?? this.defineRuntimes,
        noRetry: noRetry ?? _noRetry,
        suiteDefaults: suiteDefaults.change(
            jsTrace: jsTrace,
            runSkipped: runSkipped,
            dart2jsArgs: dart2jsArgs,
            precompiledPath: precompiledPath,
            patterns: patterns,
            runtimes: runtimes,
            includeTags: includeTags,
            excludeTags: excludeTags,
            tags: tags,
            onPlatform: onPlatform,
            testRandomizeOrderingSeed: testRandomizeOrderingSeed,
            timeout: timeout,
            verboseTrace: verboseTrace,
            chainStackTraces: chainStackTraces,
            skip: skip,
            skipReason: skipReason,
            testOn: testOn,
            addTags: addTags));
    return config._resolvePresets();
  }

  /// Merges two maps whose values are [Configuration]s.
  ///
  /// Any overlapping keys in the maps have their configurations merged in the
  /// returned map.
  Map<String, Configuration> _mergeConfigMaps(
          Map<String, Configuration> map1, Map<String, Configuration> map2) =>
      mergeMaps(map1, map2,
          value: (config1, config2) => config1.merge(config2));

  /// Returns a copy of this [Configuration] with all [chosenPresets] resolved
  /// against [presets].
  Configuration _resolvePresets() {
    if (chosenPresets.isEmpty || presets.isEmpty) return this;

    var newPresets = Map<String, Configuration>.from(presets);
    var merged = chosenPresets.fold(
        empty,
        (Configuration merged, preset) =>
            merged.merge(newPresets.remove(preset) ?? Configuration.empty));

    if (merged == empty) return this;
    var result = this.change(presets: newPresets).merge(merged);

    // Make sure the configuration knows about presets that were selected and
    // thus removed from [newPresets].
    result._knownPresets = UnmodifiableSetView(
        result.knownPresets.toSet()..addAll(this.presets.keys));

    return result;
  }
}
