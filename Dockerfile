# ponytail: the official Nim image already has the C toolchain and nimble.
# Only OpenSSL's development package is missing, and `-d:ssl` links against it.
FROM nimlang/nim:2.2.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /reckonim
COPY . .

# JEV_API_KEY is passed at run time, never baked in.
CMD ["nim", "c", "-d:ssl", "--hints:off", "--path:src", "-r", "examples/triage.nim"]
