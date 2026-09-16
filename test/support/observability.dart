import 'package:mssql_native/mssql_native.dart';

/// Records the public observer contract without depending on driver internals.
final class RecordingMssqlObserver extends MssqlObserver {
  RecordingMssqlObserver({
    this.queryStartState,
    this.bulkStartState,
    this.transactionStartState,
    Set<String>? throwCallbacks,
    this.throwObserverError = false,
  }) : throwCallbacks = throwCallbacks ?? <String>{};

  Object? queryStartState;
  Object? bulkStartState;
  Object? transactionStartState;
  final Set<String> throwCallbacks;
  bool throwObserverError;

  final List<MssqlQueryStartEvent> queryStarts = <MssqlQueryStartEvent>[];
  final List<MssqlQueryCompleteEvent> queryCompletes =
      <MssqlQueryCompleteEvent>[];
  final List<MssqlQueryErrorEvent> queryErrors = <MssqlQueryErrorEvent>[];
  final List<Object?> queryCompleteStates = <Object?>[];
  final List<Object?> queryErrorStates = <Object?>[];

  final List<MssqlBulkStartEvent> bulkStarts = <MssqlBulkStartEvent>[];
  final List<MssqlBulkCompleteEvent> bulkCompletes = <MssqlBulkCompleteEvent>[];
  final List<MssqlBulkErrorEvent> bulkErrors = <MssqlBulkErrorEvent>[];
  final List<Object?> bulkCompleteStates = <Object?>[];
  final List<Object?> bulkErrorStates = <Object?>[];

  final List<MssqlTransactionStartEvent> transactionStarts =
      <MssqlTransactionStartEvent>[];
  final List<MssqlTransactionCompleteEvent> transactionCompletes =
      <MssqlTransactionCompleteEvent>[];
  final List<MssqlTransactionErrorEvent> transactionErrors =
      <MssqlTransactionErrorEvent>[];
  final List<Object?> transactionCompleteStates = <Object?>[];
  final List<Object?> transactionErrorStates = <Object?>[];

  final List<MssqlConnectionOpenEvent> connectionOpens =
      <MssqlConnectionOpenEvent>[];
  final List<MssqlConnectionCloseEvent> connectionCloses =
      <MssqlConnectionCloseEvent>[];
  final List<MssqlPoolWaitEvent> poolWaits = <MssqlPoolWaitEvent>[];
  final List<String> observerErrors = <String>[];

  void clearOperations() {
    queryStarts.clear();
    queryCompletes.clear();
    queryErrors.clear();
    queryCompleteStates.clear();
    queryErrorStates.clear();
    bulkStarts.clear();
    bulkCompletes.clear();
    bulkErrors.clear();
    bulkCompleteStates.clear();
    bulkErrorStates.clear();
    transactionStarts.clear();
    transactionCompletes.clear();
    transactionErrors.clear();
    transactionCompleteStates.clear();
    transactionErrorStates.clear();
    poolWaits.clear();
    observerErrors.clear();
  }

  void clearAll() {
    clearOperations();
    connectionOpens.clear();
    connectionCloses.clear();
  }

  void _failIfRequested(String callback) {
    if (throwCallbacks.contains(callback)) {
      throw StateError('$callback failed');
    }
  }

  @override
  Object? onQueryStart(MssqlQueryStartEvent event) {
    queryStarts.add(event);
    _failIfRequested('onQueryStart');
    return queryStartState;
  }

  @override
  void onQueryComplete(MssqlQueryCompleteEvent event, Object? state) {
    queryCompletes.add(event);
    queryCompleteStates.add(state);
    _failIfRequested('onQueryComplete');
  }

  @override
  void onQueryError(MssqlQueryErrorEvent event, Object? state) {
    queryErrors.add(event);
    queryErrorStates.add(state);
    _failIfRequested('onQueryError');
  }

  @override
  Object? onBulkStart(MssqlBulkStartEvent event) {
    bulkStarts.add(event);
    _failIfRequested('onBulkStart');
    return bulkStartState;
  }

  @override
  void onBulkComplete(MssqlBulkCompleteEvent event, Object? state) {
    bulkCompletes.add(event);
    bulkCompleteStates.add(state);
    _failIfRequested('onBulkComplete');
  }

  @override
  void onBulkError(MssqlBulkErrorEvent event, Object? state) {
    bulkErrors.add(event);
    bulkErrorStates.add(state);
    _failIfRequested('onBulkError');
  }

  @override
  Object? onTransactionStart(MssqlTransactionStartEvent event) {
    transactionStarts.add(event);
    _failIfRequested('onTransactionStart');
    return transactionStartState;
  }

  @override
  void onTransactionComplete(
    MssqlTransactionCompleteEvent event,
    Object? state,
  ) {
    transactionCompletes.add(event);
    transactionCompleteStates.add(state);
    _failIfRequested('onTransactionComplete');
  }

  @override
  void onTransactionError(MssqlTransactionErrorEvent event, Object? state) {
    transactionErrors.add(event);
    transactionErrorStates.add(state);
    _failIfRequested('onTransactionError');
  }

  @override
  void onConnectionOpen(MssqlConnectionOpenEvent event) {
    connectionOpens.add(event);
    _failIfRequested('onConnectionOpen');
  }

  @override
  void onConnectionClose(MssqlConnectionCloseEvent event) {
    connectionCloses.add(event);
    _failIfRequested('onConnectionClose');
  }

  @override
  void onPoolWait(MssqlPoolWaitEvent event) {
    poolWaits.add(event);
    _failIfRequested('onPoolWait');
  }

  @override
  void onObserverError(String callback, Object error, StackTrace stackTrace) {
    observerErrors.add(callback);
    if (throwObserverError) throw StateError('onObserverError failed');
  }
}
