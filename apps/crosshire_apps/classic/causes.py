"""Map a failure (level, exception class, message) to one cause from a fixed list."""
import re

from crosshire_apps.common.fingerprint import fingerprint, template

CAUSES = (
    "OUT_OF_MEMORY_DRIVER",
    "OUT_OF_MEMORY_EXECUTOR",
    "EXECUTOR_LOST_SPOT",
    "EXECUTOR_LOST_OTHER",
    "SHUFFLE_FETCH_FAILED",
    "DISK_FULL",
    "FILE_NOT_FOUND",
    "PERMISSION_DENIED",
    "SCHEMA_MISMATCH",
    "TIMEOUT",
    "CANCELLED",
    "LIBRARY_OR_IMPORT",
    "USER_CODE_ERROR",
    "UNKNOWN",
)

_OOM = re.compile(r"OutOfMemory|out of memory|exceeding memory limits|GC overhead limit|Java heap space", re.I)
_SPOT = re.compile(r"\bspot\b|preempt", re.I)
_LOST = re.compile(r"ExecutorLost|executor lost|Executor heartbeat timed out|worker lost|decommission", re.I)
# First match wins; OOM and executor loss are handled before this list.
_RULES = [
    ("SHUFFLE_FETCH_FAILED", re.compile(r"FetchFailed|MetadataFetchFailed|shuffle fetch", re.I)),
    ("DISK_FULL", re.compile(r"No space left on device|disk (is )?full", re.I)),
    ("PERMISSION_DENIED", re.compile(
        r"AccessDenied|PERMISSION_DENIED|Permission denied|Forbidden|\b403\b|UNAUTHORIZED|Insufficient privileges", re.I)),
    ("FILE_NOT_FOUND", re.compile(r"FileNotFound|PATH_NOT_FOUND|No such file|NoSuchKey", re.I)),
    ("SCHEMA_MISMATCH", re.compile(
        r"schema mismatch|SCHEMA_MISMATCH|FAILED_TO_MERGE_FIELDS|DELTA_METADATA_MISMATCH|incompatible schema", re.I)),
    ("TIMEOUT", re.compile(r"Timeout|timed out", re.I)),
    ("CANCELLED", re.compile(r"cancel|TaskKilled|InterruptedException", re.I)),
    ("LIBRARY_OR_IMPORT", re.compile(
        r"ModuleNotFoundError|ImportError|ClassNotFoundException|NoClassDefFoundError|NoSuchMethodError|"
        r"Library installation failed", re.I)),
    ("USER_CODE_ERROR", re.compile(
        r"PythonException|AnalysisException|ValueError|TypeError|KeyError|IndexError|NameError|AttributeError|"
        r"ZeroDivisionError|AssertionError|ArithmeticException|NumberFormatException|DIVIDE_BY_ZERO|"
        r"CAST_INVALID_INPUT|UNRESOLVED_COLUMN|TABLE_OR_VIEW_NOT_FOUND|ParseException", re.I)),
]


def classify(level, exception_class, message):
    text = f"{exception_class or ''} {message or ''}"
    if _OOM.search(text):
        return "OUT_OF_MEMORY_DRIVER" if level == "driver" else "OUT_OF_MEMORY_EXECUTOR"
    if _LOST.search(text) or level == "executor" and exception_class == "ExecutorRemoved":
        return "EXECUTOR_LOST_SPOT" if _SPOT.search(text) else "EXECUTOR_LOST_OTHER"
    for cause, pattern in _RULES:
        if pattern.search(text):
            return cause
    return "UNKNOWN"


def describe(level, exception_class, message):
    """(cause, fingerprint, template) for one failure; the raw message is not returned."""
    return classify(level, exception_class, message), fingerprint(message), template(message)


# An exception line in a text log: "java.lang.OutOfMemoryError: Java heap space",
# "ValueError: bad", ": org.apache.spark.SparkException: ...", "Caused by: ...".
_EXCEPTION_LINE = re.compile(
    r"^(?::\s|Caused by:\s)?(?P<cls>(?:[a-zA-Z_$][\w$]*\.)*[A-Z][\w$]*(?:Error|Exception|Exit))(?::\s?(?P<msg>.*))?$"
)


def exception_from_line(line):
    """(exception_class, message) if the log line starts an exception, else None."""
    m = _EXCEPTION_LINE.match(line.rstrip())
    if not m:
        return None
    return m.group("cls"), m.group("msg")
