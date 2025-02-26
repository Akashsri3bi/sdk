// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// A representation of the contents of an instrumentation log.
import 'dart:convert';
import 'dart:math' as math;

import 'package:analyzer/instrumentation/instrumentation.dart';
import 'package:path/path.dart' as path;

/// A boolean-valued function of one argument.
typedef Predicate<T> = bool Function(T value);

/// A description of a group of log entries.
class EntryGroup {
  /// A list of all of the instances of this class.
  static final List<EntryGroup> groups = <EntryGroup>[
    EntryGroup._(
        'nonTask', 'Non-task', (LogEntry entry) => entry is! TaskEntry),
    EntryGroup._(
        'errors',
        'Errors',
        (LogEntry entry) =>
            entry is ErrorEntry ||
            entry is ExceptionEntry ||
            (entry is NotificationEntry && entry.isServerError)),
    EntryGroup._('malformed', 'Malformed',
        (LogEntry entry) => entry is MalformedLogEntry),
    EntryGroup._('all', 'All', (LogEntry entry) => true),
  ];

  /// The unique id of the group.
  final String id;

  /// The human-readable name of the group.
  final String name;

  /// The filter used to determine which entries belong to the group. The filter
  /// should return `true` for members and `false` for non-members.
  final Predicate<LogEntry> filter;

  /// Initialize a newly created entry group with the given state.
  EntryGroup._(this.id, this.name, this.filter);

  /// Given a list of [entries], return all of the entries in the list that are
  /// members of this group.
  List<LogEntry> computeMembers(List<LogEntry> entries) {
    return entries.where(filter).toList();
  }

  /// Return the entry group with the given [id], or `null` if there is no group
  /// with the given id.
  static EntryGroup? withId(String id) {
    for (var group in groups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }
}

/// A range of log entries, represented by the index of the first and last
/// entries in the range.
class EntryRange {
  /// The index of the first entry in the range.
  int firstIndex;

  /// The index of the first entry in the range.
  int lastIndex;

  /// Initialize a newly created range to represent the entries between the
  /// [firstIndex] and the [lastIndex], inclusive.
  EntryRange(this.firstIndex, this.lastIndex);
}

/// A log entry representing an Err entry.
class ErrorEntry extends GenericEntry {
  /// Initialize a newly created log entry.
  ErrorEntry(
      super.index, super.timeStamp, super.entryKind, super.components);
}

/// A log entry representing an Ex entry.
class ExceptionEntry extends GenericEntry {
  /// Initialize a newly created log entry.
  ExceptionEntry(
      super.index, super.timeStamp, super.entryKind, super.components);
}

/// A representation of a generic log entry.
class GenericEntry extends LogEntry {
  /// The kind of the log entry.
  String entryKind;

  /// The components in the entry that follow the time stamp and entry kind.
  List<String> components;

  /// Initialize a newly created generic log entry to have the given
  /// [timeStamp], [entryKind] and list of [components]
  GenericEntry(super.index, super.timeStamp, this.entryKind, this.components);

  @override
  String get kind => entryKind;

  @override
  void _appendDetails(StringBuffer buffer) {
    super._appendDetails(buffer);
    for (var component in components) {
      buffer.write(component);
      buffer.write('<br>');
    }
  }
}

/// A log entry representing an PluginErr entry.
class GenericPluginEntry extends GenericEntry with PluginEntryMixin {
  /// The components describing the plugin associated with this entry.
  @override
  final List<String> pluginData;

  /// Initialize a newly created log entry.
  GenericPluginEntry(super.index, super.timeStamp, super.entryKind,
      super.components, this.pluginData);
}

/// A representation of an instrumentation log.
class InstrumentationLog {
  /// The paths of the log files containing the entries.
  List<String> logFilePaths;

  /// The entries in the instrumentation log.
  late List<LogEntry> logEntries;

  /// A table mapping the entry groups that have been computed to the list of
  /// entries in that group.
  Map<EntryGroup, List<LogEntry>> entryGroups = <EntryGroup, List<LogEntry>>{};

  /// A table mapping entries that are paired with another entry to the entry
  /// with which they are paired.
  final Map<LogEntry, LogEntry> _pairedEntries = <LogEntry, LogEntry>{};

  /// A table mapping the id's of requests to the entry representing the
  /// request.
  final Map<String, RequestEntry> _requestMap = <String, RequestEntry>{};

  /// A table mapping the id's of plugin requests to the entry representing the
  /// request.
  final Map<String, PluginRequestEntry> _pluginRequestMap =
      <String, PluginRequestEntry>{};

  /// A table mapping the id's of responses to the entry representing the
  /// response.
  final Map<String, ResponseEntry> _responseMap = <String, ResponseEntry>{};

  /// A table mapping the id's of plugin responses to the entry representing the
  /// response.
  final Map<String, PluginResponseEntry> _pluginResponseMap =
      <String, PluginResponseEntry>{};

  /// A table mapping the ids of completion events to the events with those ids.
  final Map<String, List<NotificationEntry>> _completionMap =
      <String, List<NotificationEntry>>{};

  /// The ranges of entries that are between analysis start and analysis end
  /// notifications.
  late List<EntryRange> analysisRanges;

  /// Initialize a newly created instrumentation log by parsing each of the
  /// lines in the [logContent] into a separate entry. The log contents should
  /// be the contents of the files whose paths are in the given list of
  /// [logFilePaths].
  InstrumentationLog(this.logFilePaths, List<String> logContent) {
    _parseLogContent(logContent);
  }

  /// Return a list of the completion events associated with the given [id].
  List<NotificationEntry>? completionEventsWithId(String id) =>
      _completionMap[id];

  /// Return the log entries that are contained in the given [group].
  List<LogEntry>? entriesInGroup(EntryGroup group) =>
      entryGroups.putIfAbsent(group, () => group.computeMembers(logEntries));

  /// Return the entry that is paired with the given [entry], or `null` if there
  /// is no entry paired with it.
  LogEntry? pairedEntry(LogEntry entry) => _pairedEntries[entry];

  /// Return the response that corresponds to the given plugin request.
  PluginRequestEntry? pluginRequestFor(PluginResponseEntry entry) =>
      _pluginRequestMap[entry.id];

  /// Return the response that corresponds to the given request.
  PluginResponseEntry? pluginResponseFor(PluginRequestEntry entry) =>
      _pluginResponseMap[entry.id];

  /// Return the response that corresponds to the given request.
  RequestEntry? requestFor(ResponseEntry entry) => _requestMap[entry.id];

  /// Return the response that corresponds to the given request.
  ResponseEntry? responseFor(RequestEntry entry) => _responseMap[entry.id];

  /// Return a list containing all of the task entries between the start of
  /// analysis notification at the given [startIndex] and the matching end of
  /// analysis notification (or the end of the log if the log does not contain a
  /// corresponding end notification.
  List<TaskEntry> taskEntriesFor(int startIndex) {
    var taskEntries = <TaskEntry>[];
    var startEntry = logEntries[startIndex] as NotificationEntry;
    var endEntry = pairedEntry(startEntry);
    var lastIndex = endEntry == null ? logEntries.length : endEntry.index;
    for (var i = startEntry.index + 1; i < lastIndex; i++) {
      var entry = logEntries[i];
      if (entry is TaskEntry) {
        taskEntries.add(entry);
      }
    }
    return taskEntries;
  }

  /// Return `true` if the given [logContent] appears to be from session data.
  bool _isSessionData(List<String> logContent) {
    if (logContent.length < 2) {
      return false;
    }
    var firstLine = logContent[0];
    return firstLine.startsWith('-----') && logContent[1].startsWith('~') ||
        firstLine.startsWith('~');
  }

  /// Merge any multi-line entries into a single line so that every element in
  /// the given [logContent] is a single entry.
  void _mergeEntries(List<String> logContent) {
    bool isStartOfEntry(String line) {
      return line.startsWith(LogEntry.entryRegExp);
    }

    String merge(String line, List<String> extraLines) {
      var buffer = StringBuffer();
      buffer.writeln(line);
      for (var extraLine in extraLines) {
        buffer.writeln(extraLine);
      }
      return buffer.toString();
    }

    var extraLines = <String>[];
    for (var i = logContent.length - 1; i >= 0; i--) {
      var line = logContent[i];
      if (isStartOfEntry(line)) {
        if (extraLines.isNotEmpty) {
          logContent[i] = merge(line, extraLines);
        }
        extraLines.clear();
      } else {
        logContent.removeAt(i);
        extraLines.insert(0, line);
      }
    }
    if (extraLines.isNotEmpty) {
      var count = math.min(extraLines.length, 10);
      var buffer = StringBuffer();
      buffer.writeln('${extraLines.length} non-entry lines before any entry');
      buffer.writeln('First $count lines:');
      for (var i = 0; i < count; i++) {
        buffer.writeln(extraLines[i]);
      }
      throw StateError(buffer.toString());
    }
  }

  /// Parse the given [logContent] into a list of log entries.
  void _parseLogContent(List<String> logContent) {
    if (_isSessionData(logContent)) {
      if (logContent[0].startsWith('-----')) {
        logContent.removeAt(0);
      }
      var lastIndex = logContent.length - 1;
      if (logContent[lastIndex].startsWith('extraction complete')) {
        logContent.removeAt(lastIndex);
      }
    } else {
      _mergeEntries(logContent);
    }
    logEntries = <LogEntry>[];
    analysisRanges = <EntryRange>[];
    NotificationEntry? analysisStartEntry;
    var analysisStartIndex = -1;
    NotificationEntry? pubStartEntry;
    for (var line in logContent) {
      var entry = LogEntry.from(logEntries.length, line);
      if (entry != null) {
        logEntries.add(entry);
        if (entry is RequestEntry) {
          _requestMap[entry.id] = entry;
        } else if (entry is ResponseEntry) {
          _responseMap[entry.id] = entry;
          var request = _requestMap[entry.id]!;
          _pairedEntries[entry] = request;
          _pairedEntries[request] = entry;
        } else if (entry is NotificationEntry) {
          if (entry.isServerStatus) {
            var analysisStatus = entry.param('analysis');
            if (analysisStatus is Map) {
              if (analysisStatus['isAnalyzing'] as bool) {
                if (analysisStartEntry != null) {
                  analysisStartEntry.recordProblem(
                      'Analysis started without being terminated.');
                }
                analysisStartEntry = entry;
                analysisStartIndex = logEntries.length - 1;
              } else {
                if (analysisStartEntry == null) {
                  entry.recordProblem(
                      'Analysis terminated without being started.');
                } else {
                  var analysisEnd = logEntries.length - 1;
                  analysisRanges
                      .add(EntryRange(analysisStartIndex, analysisEnd));
                  _pairedEntries[entry] = analysisStartEntry;
                  _pairedEntries[analysisStartEntry] = entry;
                  analysisStartEntry = null;
                  analysisStartIndex = -1;
                }
              }
            }
            var pubStatus = entry.param('pub');
            if (pubStatus is Map) {
              if (pubStatus['isListingPackageDirs'] as bool) {
                if (pubStartEntry != null) {
                  pubStartEntry.recordProblem(
                      'Pub started without previous being terminated.');
                }
                pubStartEntry = entry;
              } else {
                if (pubStartEntry == null) {
                  entry.recordProblem('Pub terminated without being started.');
                } else {
                  _pairedEntries[entry] = pubStartEntry;
                  _pairedEntries[pubStartEntry] = entry;
                  pubStartEntry = null;
                }
              }
            }
          } else if (entry.event == 'completion.results') {
            var id = entry.param('id');
            if (id is String) {
              _completionMap
                  .putIfAbsent(id, () => <NotificationEntry>[])
                  .add(entry);
            }
          }
        } else if (entry is PluginRequestEntry) {
          _pluginRequestMap[entry.id] = entry;
        } else if (entry is PluginResponseEntry) {
          _pluginResponseMap[entry.id] = entry;
          var request = _pluginRequestMap[entry.id]!;
          _pairedEntries[entry] = request;
          _pairedEntries[request] = entry;
        }
      }
    }
    if (analysisStartEntry != null) {
      analysisStartEntry
          .recordProblem('Analysis started without being terminated.');
    }
    if (pubStartEntry != null) {
      pubStartEntry
          .recordProblem('Pub started without previous being terminated.');
    }
  }
}

/// A log entry that has a single JSON encoded component following the time
/// stamp and entry kind.
abstract class JsonBasedEntry extends LogEntry {
  /// The HTML string used to indent text when formatting the JSON [data].
  static const String singleIndent = '&nbsp;&nbsp;&nbsp;';

  /// The decoded form of the JSON encoded component.
  final Map data;

  /// Initialize a newly created log entry to have the given [timeStamp] and
  /// [data].
  JsonBasedEntry(super.index, super.timeStamp, this.data);

  @override
  void _appendDetails(StringBuffer buffer) {
    super._appendDetails(buffer);
    _format(buffer, '', data);
  }

  /// Encode any character in the given [string] that would prevent source code
  /// from being displayed correctly: end of line markers and spaces.
  String _encodeSourceCode(String string) {
    // TODO(brianwilkerson) This method isn't working completely. Some source
    // code produces an error of
    // "log?start=3175:261 Uncaught SyntaxError: missing ) after argument list"
    // in the sample log I was using.
    var buffer = StringBuffer();
    var length = string.length;
    var index = 0;
    while (index < length) {
      var char = string.codeUnitAt(index);
      index++;
      // TODO(brianwilkerson) Handle tabs and other special characters.
      if (char == '\r'.codeUnitAt(0)) {
        if (index < length && string.codeUnitAt(index) == '\n'.codeUnitAt(0)) {
          index++;
        }
        buffer.write('<br>');
      } else if (char == '\n'.codeUnitAt(0)) {
        buffer.write('<br>');
      } else if (char == ' '.codeUnitAt(0)) {
        // Encode all spaces in order to accurately reproduce the original
        // source code when displaying it.
        buffer.write('&nbsp;');
      } else {
        buffer.writeCharCode(char);
      }
    }
    return buffer.toString();
  }

  /// Write an HTML representation the given JSON [object] to the given
  /// [buffer], using the given [indent] to make the output more readable.
  void _format(StringBuffer buffer, String indent, Object object) {
    if (object is String) {
      buffer.write('"');
      buffer.write(_encodeSourceCode(object));
      buffer.write('"');
    } else if (object is int || object is bool) {
      buffer.write(object);
    } else if (object is Map) {
      buffer.write('{<br>');
      object.forEach((key, value) {
        var newIndent = indent + singleIndent;
        buffer.write(newIndent);
        _format(buffer, newIndent, key as Object);
        buffer.write(' : ');
        _format(buffer, newIndent, value as Object);
        buffer.write('<br>');
      });
      buffer.write(indent);
      buffer.write('}');
    } else if (object is List) {
      buffer.write('[<br>');
      for (var element in object) {
        var newIndent = indent + singleIndent;
        buffer.write(newIndent);
        _format(buffer, newIndent, element as Object);
        buffer.write('<br>');
      }
      buffer.write(indent);
      buffer.write(']');
    }
  }
}

/// A log entry representing a communication between the server and a plugin.
abstract class JsonBasedPluginEntry extends JsonBasedEntry
    with PluginEntryMixin {
  /// The components describing the plugin associated with this entry.
  @override
  final List<String> pluginData;

  /// Initialize a newly created entry to have the given [timeStamp] and
  /// [notificationData] and to be associated with the plugin with the given
  /// [pluginData].
  JsonBasedPluginEntry(
      super.index, super.timeStamp, super.notificationData, this.pluginData);
}

/// A single entry in an instrumentation log.
abstract class LogEntry {
  /// The character used to separate fields within an entry.
  static final int fieldSeparator = ':'.codeUnitAt(0);

  /// A regular expression that will match the beginning of a valid log entry.
  static final RegExp entryRegExp = RegExp('[0-9]+\\:');

  /// A table mapping kinds to the names of those kinds.
  static final Map<String, String> kindMap = {
    'Err': 'Error',
    'Ex': 'Exception',
    'Log': 'Log message',
    'Mal': 'Malformed entry',
    'Noti': 'Notification',
    'Read': 'Read file',
    'Req': 'Request',
    'Res': 'Response',
    'Perf': 'Performance data',
    'SPResult': 'Subprocess result',
    'SPStart': 'Subprocess start',
    'Task': 'Task',
    'Ver': 'Version information',
    'Watch': 'Watch event',
  };

  /// The index of this entry in the log file.
  final int index;

  /// The time at which the entry occurred.
  final int timeStamp;

  /// A list containing the descriptions of problems that were found while
  /// processing the log file, or `null` if no problems were found.
  List<String>? _problems;

  /// Initialize a newly created log entry with the given [timeStamp].
  LogEntry(this.index, this.timeStamp);

  /// Return `true` if any problems were found while processing the log file.
  bool get hasProblems => _problems != null;

  /// Return the value of the component used to indicate the kind of the entry.
  /// This is the abbreviation recorded in the entry.
  String get kind;

  /// Return a human-readable representation of the kind of this entry.
  String get kindName => kindMap[kind] ?? kind;

  /// Return a list containing the descriptions of problems that were found
  /// while processing the log file, or `null` if no problems were found.
  List<String>? get problems => _problems;

  /// Return a date that is equivalent to the [timeStamp].
  DateTime get toTime => DateTime.fromMillisecondsSinceEpoch(timeStamp);

  /// Return an HTML representation of the details of the entry.
  String details() {
    var buffer = StringBuffer();
    _appendDetails(buffer);
    return buffer.toString();
  }

  /// Record that the given [problem] was found while processing the log file.
  void recordProblem(String problem) {
    var problems = _problems ??= <String>[];
    problems.add(problem);
  }

  /// Append details related to this entry to the given [buffer].
  void _appendDetails(StringBuffer buffer) {
    var problems = _problems;
    if (problems != null) {
      for (var problem in problems) {
        buffer.write('<p><span class="error">$problem</span></p>');
      }
    }
  }

  /// Create a log entry from the given encoded form of the [entry].
  static LogEntry? from(int index, String entry) {
    if (entry.isEmpty) {
      return null;
    }
    try {
      var components = _parseComponents(entry);
      int timeStamp;
      var component = components[0];
      if (component.startsWith('~')) {
        component = component.substring(1);
      }
      timeStamp = int.parse(component);
      var entryKind = components[1];
      if (entryKind == InstrumentationLogAdapter.TAG_ERROR) {
        return ErrorEntry(index, timeStamp, entryKind, components.sublist(2));
      } else if (entryKind == InstrumentationLogAdapter.TAG_EXCEPTION) {
        return ExceptionEntry(
            index, timeStamp, entryKind, components.sublist(2));
      } else if (entryKind == InstrumentationLogAdapter.TAG_LOG_ENTRY) {
        // Fall through
      } else if (entryKind == InstrumentationLogAdapter.TAG_NOTIFICATION) {
        var requestData = json.decode(components[2]) as Map<Object?, Object?>;
        return NotificationEntry(index, timeStamp, requestData);
      } else if (entryKind == InstrumentationLogAdapter.TAG_PLUGIN_ERROR) {
        return PluginErrorEntry(index, timeStamp, entryKind,
            components.sublist(2, 4), components.sublist(4));
      } else if (entryKind == InstrumentationLogAdapter.TAG_PLUGIN_EXCEPTION) {
        return PluginExceptionEntry(index, timeStamp, entryKind,
            components.sublist(2, 5), components.sublist(5));
      } else if (entryKind ==
          InstrumentationLogAdapter.TAG_PLUGIN_NOTIFICATION) {
        var requestData = json.decode(components[2]) as Map<Object?, Object?>;
        return PluginNotificationEntry(
            index, timeStamp, requestData, components.sublist(3));
      } else if (entryKind == InstrumentationLogAdapter.TAG_PLUGIN_REQUEST) {
        var requestData = json.decode(components[2]) as Map<Object?, Object?>;
        return PluginRequestEntry(
            index, timeStamp, requestData, components.sublist(3));
      } else if (entryKind == InstrumentationLogAdapter.TAG_PLUGIN_RESPONSE) {
        var responseData = json.decode(components[2]) as Map<Object?, Object?>;
        return PluginResponseEntry(
            index, timeStamp, responseData, components.sublist(3));
      } else if (entryKind == InstrumentationLogAdapter.TAG_PLUGIN_TIMEOUT) {
        return PluginErrorEntry(index, timeStamp, entryKind,
            components.sublist(2, 3), components.sublist(3));
      } else if (entryKind == InstrumentationLogAdapter.TAG_REQUEST) {
        var requestData = json.decode(components[2]) as Map<Object?, Object?>;
        return RequestEntry(index, timeStamp, requestData);
      } else if (entryKind == InstrumentationLogAdapter.TAG_RESPONSE) {
        var responseData = json.decode(components[2]) as Map<Object?, Object?>;
        return ResponseEntry(index, timeStamp, responseData);
      } else if (entryKind == InstrumentationLogAdapter.TAG_VERSION) {
        // Fall through
      } else if (entryKind == InstrumentationLogAdapter.TAG_WATCH_EVENT) {
        // Fall through
      }
      return GenericEntry(index, timeStamp, entryKind, components.sublist(2));
    } catch (exception) {
      LogEntry logEntry = MalformedLogEntry(index, entry);
      logEntry.recordProblem(exception.toString());
      return logEntry;
    }
  }

  /// Parse the given encoded form of the [entry] into a list of components. The
  /// first component is always the time stamp for when the entry was generated.
  /// The second component is always the kind of the entry. The remaining
  /// components depend on the kind of the entry. Return the components that
  /// were parsed.
  static List<String> _parseComponents(String entry) {
    var components = <String>[];
    var component = StringBuffer();
    var length = entry.length;
    for (var i = 0; i < length; i++) {
      var char = entry.codeUnitAt(i);
      if (char == fieldSeparator) {
        if (entry.codeUnitAt(i + 1) == fieldSeparator) {
          component.write(':');
          i++;
        } else {
          components.add(component.toString());
          component.clear();
        }
      } else {
        component.writeCharCode(char);
      }
    }
    components.add(component.toString());
    return components;
  }
}

/// A representation of a malformed log entry.
class MalformedLogEntry extends LogEntry {
  final String entry;

  MalformedLogEntry(int index, this.entry) : super(index, -1);

  @override
  String get kind => 'Mal';

  @override
  void _appendDetails(StringBuffer buffer) {
    super._appendDetails(buffer);
    buffer.write(entry);
    buffer.write('<br>');
  }
}

/// A log entry representing a notification that was sent from the server to the
/// client.
class NotificationEntry extends JsonBasedEntry {
  /// Initialize a newly created response to have the given [timeStamp] and
  /// [notificationData].
  NotificationEntry(super.index, super.timeStamp, super.notificationData);

  /// Return the event field of the request.
  String get event => data['event'] as String;

  /// Return `true` if this is a server error notification.
  bool get isServerError => event == 'server.error';

  /// Return `true` if this is a server status notification.
  bool get isServerStatus => event == 'server.status';

  @override
  String get kind => 'Noti';

  /// Return the value of the parameter with the given [parameterName], or
  /// `null` if there is no such parameter.
  Object? param(String parameterName) {
    var parameters = data['params'];
    if (parameters is Map) {
      return parameters[parameterName];
    }
    return null;
  }
}

/// A log entry representing a communication between the server and a plugin.
mixin PluginEntryMixin {
  /// The components describing the plugin associated with this entry.
  List<String> get pluginData;

  /// The id of the plugin associated with this entry.
  String get pluginId => pluginData[0];

  /// The name of the plugin associated with this entry.
  String get pluginName => pluginData[1];

  /// The version of the plugin associated with this entry.
  String get pluginVersion => pluginData[2];

  /// Return a shortened version of the plugin id.
  String get shortPluginId {
    var index = pluginId.lastIndexOf(path.separator);
    if (index > 0) {
      return pluginId.substring(index + 1);
    }
    return pluginId;
  }
}

/// A log entry representing an PluginErr entry.
class PluginErrorEntry extends GenericPluginEntry {
  /// Initialize a newly created log entry.
  PluginErrorEntry(super.index, super.timeStamp, super.entryKind,
      super.components, super.pluginData);
}

/// A log entry representing an PluginEx entry.
class PluginExceptionEntry extends GenericPluginEntry {
  /// Initialize a newly created log entry.
  PluginExceptionEntry(super.index, super.timeStamp, super.entryKind,
      super.components, super.pluginData);
}

/// A log entry representing a notification that was sent from a plugin to the
/// server.
class PluginNotificationEntry extends JsonBasedPluginEntry {
  /// Initialize a newly created notification to have the given [timeStamp] and
  /// [notificationData].
  PluginNotificationEntry(
      super.index, super.timeStamp, super.notificationData, super.pluginData);

  /// Return the event field of the notification.
  String get event => data['event'] as String;

  @override
  String get kind => 'PluginNoti';

  /// Return the value of the parameter with the given [parameterName], or
  /// `null` if there is no such parameter.
  dynamic param(String parameterName) {
    var parameters = data['params'];
    if (parameters is Map) {
      return parameters[parameterName];
    }
    return null;
  }
}

/// A log entry representing a request that was sent from the server to a
/// plugin.
class PluginRequestEntry extends JsonBasedPluginEntry {
  /// Initialize a newly created response to have the given [timeStamp] and
  /// [requestData].
  PluginRequestEntry(
      super.index, super.timeStamp, super.requestData, super.pluginData);

  /// Return the id field of the request.
  String get id => data['id'] as String;

  @override
  String get kind => 'PluginReq';

  /// Return the method field of the request.
  String get method => data['method'] as String;

  /// Return the value of the parameter with the given [parameterName], or
  /// `null` if there is no such parameter.
  dynamic param(String parameterName) {
    var parameters = data['params'];
    if (parameters is Map) {
      return parameters[parameterName];
    }
    return null;
  }
}

/// A log entry representing a response that was sent from a plugin to the
/// server.
class PluginResponseEntry extends JsonBasedPluginEntry {
  /// Initialize a newly created response to have the given [timeStamp] and
  /// [responseData].
  PluginResponseEntry(
      super.index, super.timeStamp, super.responseData, super.pluginData);

  /// Return the id field of the response.
  String get id => data['id'] as String;

  @override
  String get kind => 'PluginRes';

  /// Return the value of the result with the given [resultName], or `null` if
  /// there is no such result.
  dynamic result(String resultName) {
    var results = data['result'];
    if (results is Map) {
      return results[resultName];
    }
    return null;
  }
}

/// A log entry representing a request that was sent from the client to the
/// server.
class RequestEntry extends JsonBasedEntry {
  /// Initialize a newly created response to have the given [timeStamp] and
  /// [requestData].
  RequestEntry(super.index, super.timeStamp, super.requestData);

  /// Return the clientRequestTime field of the request.
  int get clientRequestTime => data['clientRequestTime'] as int;

  /// Return the id field of the request.
  String get id => data['id'] as String;

  @override
  String get kind => 'Req';

  /// Return the method field of the request.
  String get method => data['method'] as String;

  /// Return the value of the parameter with the given [parameterName], or
  /// `null` if there is no such parameter.
  dynamic param(String parameterName) {
    var parameters = data['params'];
    if (parameters is Map) {
      return parameters[parameterName];
    }
    return null;
  }
}

/// A log entry representing a response that was sent from the server to the
/// client.
class ResponseEntry extends JsonBasedEntry {
  /// Initialize a newly created response to have the given [timeStamp] and
  /// [responseData].
  ResponseEntry(super.index, super.timeStamp, super.responseData);

  /// Return the id field of the response.
  String get id => data['id'] as String;

  @override
  String get kind => 'Res';

  /// Return the value of the result with the given [resultName], or `null` if
  /// there is no such result.
  dynamic result(String resultName) {
    var results = data['result'];
    if (results is Map) {
      return results[resultName];
    }
    return null;
  }
}

class TaskEntry extends LogEntry {
  /// The path to the directory at the root of the context in which analysis was
  /// being performed.
  final String context;

  /// A description of the task that was performed.
  final String description;

  /// The name of the class implementing the task.
  String? _taskName;

  /// The description of the target of the task.
  String? _target;

  /// Initialize a newly created entry with the given [index] and [timeStamp] to
  /// represent the execution of an analysis task in the given [context] that is
  /// described by the given [description].
  TaskEntry(super.index, super.timeStamp, this.context, this.description);

  @override
  String get kind => 'Task';

  /// Return the description of the target of the task.
  String get target {
    if (_target == null) {
      _splitDescription();
    }
    return _target!;
  }

  /// Return the name of the class implementing the task.
  String get taskName {
    if (_taskName == null) {
      _splitDescription();
    }
    return _taskName!;
  }

  @override
  void _appendDetails(StringBuffer buffer) {
    super._appendDetails(buffer);
    buffer.write('<span class="label">Context:</span> ');
    buffer.write(context);
    buffer.write('<br><span class="label">Description: </span> ');
    buffer.write(description);
  }

  /// Split the description to get the task name and target description.
  void _splitDescription() {
    var index = description.indexOf(' ');
    if (index < 0) {
      _taskName = '';
    } else {
      _taskName = description.substring(0, index);
    }
    index = description.lastIndexOf(' ');
    var target = description.substring(index + 1);
    var slash = context.lastIndexOf('/');
    if (slash < 0) {
      slash = context.lastIndexOf('\\');
    }
    if (slash >= 0) {
      var prefix = context.substring(0, slash);
      target = target.replaceAll(prefix, '...');
    }
    _target = target;
  }
}
