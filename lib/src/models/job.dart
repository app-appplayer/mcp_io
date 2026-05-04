import 'package:mcp_bundle/mcp_bundle.dart';

/// Lifecycle status of a long-running job.
enum JobStatus {
  /// Created but not yet running.
  pending,

  /// Currently executing.
  running,

  /// Completed successfully.
  completed,

  /// Failed with an error.
  failed,

  /// Cancelled cooperatively.
  cancelled;

  static JobStatus fromString(String value) {
    return JobStatus.values.firstWhere(
      (e) => e.name == value,
      orElse: () => JobStatus.pending,
    );
  }

  bool get isTerminal =>
      this == JobStatus.completed ||
      this == JobStatus.failed ||
      this == JobStatus.cancelled;
}

/// Progress reporting for a job.
class JobProgress {
  const JobProgress({
    required this.current,
    required this.total,
    this.message,
  });

  factory JobProgress.fromJson(Map<String, dynamic> json) => JobProgress(
        current: json['current'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        message: json['message'] as String?,
      );

  /// Steps completed so far.
  final int current;

  /// Total step count (0 means indeterminate).
  final int total;

  /// Optional human-readable status message.
  final String? message;

  /// Percentage complete in 0–100. Returns -1 when [total] is 0
  /// (indeterminate progress).
  double get percent {
    if (total <= 0) return -1.0;
    return (current * 100.0) / total;
  }

  Map<String, dynamic> toJson() => {
        'current': current,
        'total': total,
        if (message != null) 'message': message,
        'percent': percent,
      };
}

/// Snapshot of a long-running job.
class Job {
  Job({
    required this.jobId,
    required this.capability,
    required this.status,
    required this.progress,
    required this.startedAt,
    this.finishedAt,
    this.result,
    this.error,
    this.cancelledBy,
  });

  /// Unique identifier (UUID v4).
  final String jobId;

  /// The capability action that started this job (e.g. `scope.run_recipe`).
  final String capability;

  /// Current status.
  final JobStatus status;

  /// Latest progress snapshot.
  final JobProgress progress;

  /// When the job entered `running`.
  final DateTime startedAt;

  /// When the job entered a terminal status.
  final DateTime? finishedAt;

  /// Result envelope when [status] is [JobStatus.completed].
  final PayloadEnvelope? result;

  /// Error when [status] is [JobStatus.failed].
  final IoError? error;

  /// Actor that cancelled the job when [status] is [JobStatus.cancelled].
  final String? cancelledBy;

  Job copyWith({
    JobStatus? status,
    JobProgress? progress,
    DateTime? finishedAt,
    PayloadEnvelope? result,
    IoError? error,
    String? cancelledBy,
  }) =>
      Job(
        jobId: jobId,
        capability: capability,
        status: status ?? this.status,
        progress: progress ?? this.progress,
        startedAt: startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        result: result ?? this.result,
        error: error ?? this.error,
        cancelledBy: cancelledBy ?? this.cancelledBy,
      );

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'capability': capability,
        'status': status.name,
        'progress': progress.toJson(),
        'startedAt': startedAt.toIso8601String(),
        if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
        if (result != null) 'result': result!.toJson(),
        if (error != null) 'error': error!.toJson(),
        if (cancelledBy != null) 'cancelledBy': cancelledBy,
      };
}
