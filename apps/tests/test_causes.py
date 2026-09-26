import pytest

from crosshire_apps.classic.causes import CAUSES, classify, exception_from_line


@pytest.mark.parametrize("level,cls,msg,cause", [
    ("driver", "java.lang.OutOfMemoryError", "Java heap space", "OUT_OF_MEMORY_DRIVER"),
    ("task", "java.lang.OutOfMemoryError", "Java heap space", "OUT_OF_MEMORY_EXECUTOR"),
    ("task", "ExecutorLostFailure", "Container killed: exceeding memory limits", "OUT_OF_MEMORY_EXECUTOR"),
    ("executor", "ExecutorRemoved", "worker lost: spot instance preempted", "EXECUTOR_LOST_SPOT"),
    ("executor", "ExecutorRemoved", "Remote RPC client disassociated", "EXECUTOR_LOST_OTHER"),
    ("task", "FetchFailed", "Failed to connect to host", "SHUFFLE_FETCH_FAILED"),
    ("task", "java.io.IOException", "No space left on device", "DISK_FULL"),
    ("driver", "java.io.FileNotFoundException", "x", "FILE_NOT_FOUND"),
    ("driver", "com.amazonaws.AmazonS3Exception", "Access Denied (Status Code: 403)", "PERMISSION_DENIED"),
    ("statement", "AnalysisException", "A schema mismatch detected when writing", "SCHEMA_MISMATCH"),
    ("driver", "java.util.concurrent.TimeoutException", "Futures timed out", "TIMEOUT"),
    ("job", None, "Job 3 cancelled because SparkContext was shut down", "CANCELLED"),
    ("driver", "ModuleNotFoundError", "No module named 'foo'", "LIBRARY_OR_IMPORT"),
    ("task", "org.apache.spark.api.python.PythonException", "ValueError: bad", "USER_CODE_ERROR"),
    ("task", "Weird", "something", "UNKNOWN"),
])
def test_classify(level, cls, msg, cause):
    assert cause in CAUSES
    assert classify(level, cls, msg) == cause


def test_exception_lines():
    assert exception_from_line("ValueError: bad value") == ("ValueError", "bad value")
    assert exception_from_line(": org.apache.spark.SparkException: Job aborted") == (
        "org.apache.spark.SparkException", "Job aborted")
    assert exception_from_line("java.lang.OutOfMemoryError: Java heap space") == (
        "java.lang.OutOfMemoryError", "Java heap space")
    assert exception_from_line("Caused by: java.io.IOException: disk") == ("java.io.IOException", "disk")
    assert exception_from_line("\tat java.util.Arrays.copyOf(Arrays.java:3236)") is None
    assert exception_from_line("hello world 123") is None
    assert exception_from_line('  File "nb.py", line 3') is None
