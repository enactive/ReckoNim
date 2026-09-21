## Build the labelled corpus. Run this only to regenerate it - `dev.json` and
## `test.json` are committed, and `corpus.nim` needs nothing else.
##
##   nim c -d:ssl --path:../../src -r fetch.nim
##
## Source: NHTSA Office of Defects Investigation consumer complaints, via
## https://api.nhtsa.gov/complaints/complaintsByVehicle. US government work, so
## public domain; NHTSA redacts personal information before publishing. Each
## record carries a free-text `summary` written by the complainant and several
## structured fields filled in separately - which is what makes it ground truth
## rather than a self-labelled example.
##
## The partition exists for one reason: criteria strings get tuned against
## `dev.json`, and every number reported comes from `test.json`. Using the same
## rows for both is the only way to cheat at this, and it is easy to do by
## accident.

import std/[algorithm, httpclient, json, os, random, sequtils, strutils, tables, uri]

const
  Endpoint = "https://api.nhtsa.gov/complaints/complaintsByVehicle"
  MinChars = 250      ## shorter narratives are usually one unusable sentence
  MaxChars = 6000     ## p99 of the pool is ~2000; this only clips outliers

  ## Rows read by a human while the question wording was being settled. They are
  ## burned: a row someone has looked at is a dev row forever, and letting one
  ## back into the test split is the quiet way to report a number that is too
  ## good. Add to this list rather than deleting from test.json.
  Burned = [10937278, 10938700, 11019438, 11030469,
            10782147, 10863882, 10871691, 10875349]

  TestRows = 200
  DevRows = 60
  Seed = 20260920

  Vehicles = [
    ("ford", "escape", 2020), ("honda", "civic", 2018),
    ("toyota", "camry", 2019), ("chevrolet", "silverado 1500", 2019),
    ("nissan", "rogue", 2018), ("hyundai", "sonata", 2019),
    ("subaru", "outback", 2020), ("ram", "1500", 2019),
    ("tesla", "model 3", 2019), ("kia", "optima", 2017),
    ("gmc", "acadia", 2018), ("dodge", "charger", 2018),
    ("volkswagen", "jetta", 2019), ("bmw", "x5", 2018),
    ("toyota", "rav4", 2019), ("honda", "accord", 2018),
    ("chevrolet", "equinox", 2018), ("nissan", "altima", 2019),
    ("chevrolet", "malibu", 2016), ("toyota", "highlander", 2020)]

  ## NHTSA's own component names, mapped to the option keys `corpus.nim` asks
  ## about. Anything outside this map is dropped: "UNKNOWN OR OTHER" is not a
  ## system, and a complaint listing two systems has no single right answer.
  Components = {
    "AIR BAGS": "air bags",
    "SERVICE BRAKES": "service brakes",
    "STEERING": "steering",
    "POWER TRAIN": "power train",
    "ELECTRICAL SYSTEM": "electrical system",
    "ENGINE": "engine",
    "VEHICLE SPEED CONTROL": "vehicle speed control",
    "FORWARD COLLISION AVOIDANCE": "forward collision avoidance"}.toTable

proc sanitize(s: string): string =
  ## Some narratives arrive with raw control bytes inside the JSON strings,
  ## which is not legal JSON and which std/json rejects. Space them out before
  ## parsing; nothing downstream cares about the difference.
  result = newStringOfCap(s.len)
  for c in s:
    result.add (if c.ord < 0x20 and c notin {'\t', '\n', '\r'}: ' ' else: c)

proc fetch(http: HttpClient, make, model: string, year: int): JsonNode =
  let url = Endpoint & "?make=" & encodeUrl(make) & "&model=" & encodeUrl(model) &
            "&modelYear=" & $year
  for attempt in 1 .. 3:
    try: return parseJson(sanitize(http.getContent(url)))
    except CatchableError as e:
      if attempt == 3:
        echo "  ", make, " ", model, " ", year, ": giving up (", e.msg, ")"
        return nil
      sleep(2000 * attempt)

proc rowOf(hit: JsonNode, vehicle: string): JsonNode =
  let
    narrative = hit{"summary"}.getStr
    comp = hit{"components"}.getStr
  if narrative.len < MinChars or narrative.len > MaxChars: return nil
  if comp notin Components: return nil        # multi-component rows land here too
  if hit{"odiNumber"}.getInt in Burned: return nil
  %*{"odi": hit{"odiNumber"}.getInt,
     "vehicle": vehicle,
     "narrative": narrative,
     "crash": hit{"crash"}.getBool,
     "fire": hit{"fire"}.getBool,
     "injured": hit{"numberOfInjuries"}.getInt > 0,
     "killed": hit{"numberOfDeaths"}.getInt > 0,
     "component": Components[comp]}

# ---------------------------------------------------------------- collect

var http = newHttpClient(timeout = 180_000)

var pool: Table[int, JsonNode]                # by ODI number, so reruns dedup
for (make, model, year) in Vehicles:
  let body = fetch(http, make, model, year)
  if body.isNil: continue
  var kept = 0
  for hit in body{"results"}:
    let row = rowOf(hit, $year & " " & make.toUpperAscii & " " & model.toUpperAscii)
    if not row.isNil:
      pool[row["odi"].getInt] = row
      inc kept
  echo make, " ", model, " ", year, ": ", body{"count"}.getInt, " complaints, ",
       kept, " usable"

http.close()
echo "pool: ", pool.len, " rows"

# ---------------------------------------------------------------- partition

# Two strata on `crash`, because a 4% base rate cannot show the difference
# between a 0.5 and a 0.95 threshold. Within each stratum the components are
# filled round-robin, so the classes are as even as the data allows. Both
# distortions are deliberate and both are reported by corpus.nim.
var bins: Table[string, seq[JsonNode]]
for _, row in pool:
  let key = (if row["crash"].getBool: "crash." else: "nocrash.") & row["component"].getStr
  bins.mgetOrPut(key, @[]).add row

var rng = initRand(Seed)
for key in bins.keys.toSeq:
  rng.shuffle(bins[key])

let classes = block:
  var c: seq[string]
  for _, name in Components: c.add name
  sort(c)
  c

proc take(bins: var Table[string, seq[JsonNode]], stratum: string, n: int): seq[JsonNode] =
  ## Round-robin over the classes, one row each per sweep, until n or dry.
  while result.len < n:
    var progressed = false
    for cls in classes:
      if result.len >= n: break
      let key = stratum & "." & cls
      if key in bins and bins[key].len > 0:
        result.add bins[key].pop()
        progressed = true
    if not progressed: break

proc split(bins: var Table[string, seq[JsonNode]], n: int): JsonNode =
  result = newJArray()
  for row in take(bins, "crash", n div 2): result.add row
  for row in take(bins, "nocrash", n - result.len): result.add row

# Test first, so a short pool starves dev rather than the reported numbers.
let test = split(bins, TestRows)
let dev = split(bins, DevRows)

proc report(name: string, rows: JsonNode) =
  var byClass: CountTable[string]
  var crash, fire, injured = 0
  for r in rows:
    byClass.inc r["component"].getStr
    if r["crash"].getBool: inc crash
    if r["fire"].getBool: inc fire
    if r["injured"].getBool: inc injured
  echo name, ": ", rows.len, " rows  crash=", crash, " fire=", fire,
       " injured=", injured
  for cls in classes:
    echo "  ", cls.alignLeft(28), byClass[cls]

writeFile(currentSourcePath().parentDir / "test.json", pretty(test))
writeFile(currentSourcePath().parentDir / "dev.json", pretty(dev))
echo()
report("test", test)
report("dev", dev)
