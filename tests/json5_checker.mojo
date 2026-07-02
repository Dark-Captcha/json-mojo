# tests/json5_checker.mojo — json5-tests harness: read one file, attempt a
# Dialect.JSON5 parse, print the verdict. Driven by tests/run_json5_suite.sh
# over the suite's categories (*.json5 and *.json must ACCEPT; *.js and
# *.txt must REJECT — the suite's own convention).

from std.sys import argv

from json.document import parse
from json.options import Dialect, ParseOptions


def main():
    var args = argv()
    if len(args) < 2:
        print("usage: json5_checker <file>")
        return
    var text: String
    try:
        with open(String(args[1]), "r") as f:
            var data = f.read_bytes()
            text = String(unsafe_from_utf8=data)
    except _:
        print("READ-ERROR")
        return
    try:
        comptime J5 = ParseOptions(dialect=Dialect.JSON5)
        var doc = parse[J5](text^)
        _ = doc.kind()
        print("ACCEPT")
    except _:
        print("REJECT")
