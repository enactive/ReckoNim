version       = "0.1.0"
author        = "greg@zuro.net"
description   = "ReckoNim - probabilistic judgment layer for Nim over TypeSafe Jev"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run the test suite":
  for t in ["tests/test_jev.nim", "tests/test_judge.nim", "tests/test_withstate.nim",
            "tests/test_focus.nim", "tests/test_eachstate.nim"]:
    exec "nim c -d:ssl --hints:off --path:src -r " & t

  # The macro rejects these with `error()`, which aborts compilation and so
  # cannot be caught by `compiles()`. Each file names its expected message.
  for (f, want) in [("foreign_root", "not rooted at state"),
                    ("bad_focus", "does not resolve in state"),
                    ("nonident_state", "plain identifier")]:
    let (output, code) = gorgeEx("nim c --hints:off --path:src -o:/dev/null " &
                                 "tests/fail/" & f & ".nim")
    if code == 0:
      echo "FAIL: tests/fail/" & f & ".nim compiled, but must not"
      quit 1
    if want notin output:
      echo "FAIL: tests/fail/" & f & ".nim rejected, but not for '" & want & "':"
      echo output
      quit 1
    echo "rejected as expected: " & f

  # Examples must keep compiling; they are documentation that can go stale.
  for e in ["triage", "hazard", "loop", "moderation", "review", "rfp"]:
    exec "nim c -d:ssl --hints:off --path:src -o:/dev/null examples/" & e & ".nim"
  echo "examples compile"

  # Dedup is decided while the batch is built, so this one asserts its counts
  # with no key and no request.
  exec "nim c -d:ssl --hints:off --path:src -r examples/dedup.nim"

  # These two replay committed recordings, so they run here with no API key and
  # fail loudly if a recording stops matching the requests the code builds.
  exec "nim c -d:ssl --hints:off --path:src -r examples/incident.nim"
  exec "nim c -d:ssl --hints:off --path:src examples/corpus/fetch.nim"
  exec "nim c -d:ssl --hints:off --path:src -r examples/corpus/corpus.nim"
